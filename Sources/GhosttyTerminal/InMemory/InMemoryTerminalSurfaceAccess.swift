import Foundation
import GhosttyKit

/// Serializes host output while keeping the raw surface alive for each C call.
final class InMemoryTerminalSurfaceAccess: @unchecked Sendable {
    typealias Write = @Sendable (ghostty_surface_t, Data) -> Void
    typealias ProcessExit = @Sendable (ghostty_surface_t, UInt32, UInt64) -> Void
    typealias Tick = @Sendable (ghostty_surface_t) -> Void
    typealias Free = @Sendable (ghostty_surface_t) -> Void

    private let condition = NSCondition()
    private let outputQueue = DispatchQueue(
        label: "com.lakr233.libghostty-spm.in-memory-output",
        qos: .userInitiated
    )
    private let write: Write
    private let processExit: ProcessExit
    private let tick: Tick
    private let free: Free

    private var surface: ghostty_surface_t?
    /// Invalidates work that was enqueued for a surface that has been replaced.
    private var generation: UInt64 = 0
    /// Prevents the caller from freeing a surface while a C operation uses it.
    ///
    /// Counted per surface, not in total: a retired surface can keep a write
    /// parked inside ghostty indefinitely, and that must not stall attaching
    /// or clearing a different surface.
    private var activeOperations: [ghostty_surface_t: Int] = [:]
    /// Surfaces handed over by `retireSurface`. A `.deferred` one is freed by
    /// whichever operation on it finishes last; a `.draining` one still
    /// belongs to the `retireSurface` call that is waiting on it.
    private var retiredSurfaces: [ghostty_surface_t: RetireState] = [:]
    private enum RetireState {
        case draining
        case deferred
    }

    /// How long a main-thread `retireSurface` ticks the app waiting for an
    /// in-flight operation before it gives up and defers the free. Long
    /// enough to drain a write that is only waiting on the mailbox; short
    /// enough that a write parked for good costs one brief stall instead of
    /// a hung app.
    private static let retireDrainBudget: TimeInterval = 0.1
    /// Bytes received while no surface is attached, replayed into the next
    /// one. The host's transport does not pause while a view (re)builds its
    /// surface — a reattach replay that lands in that gap used to be dropped
    /// wholesale, leaving the restored session showing only whatever the
    /// shell printed afterwards. Bounded: oldest bytes go first, matching
    /// what a terminal scrollback would have forgotten anyway.
    private var pendingWrites = Data()
    private static let pendingWriteByteLimit = 1 << 20
    /// A process exit received while no surface is attached, delivered to
    /// the next one after the pending bytes — the host's shell ends in the
    /// same gap its output lands in.
    private var pendingExit: (exitCode: UInt32, runtimeMilliseconds: UInt64)?
    /// Parsing on the output queue pushes titles, pwd and command marks into
    /// ghostty's 64-slot app mailbox, which only `ghostty_app_tick` drains,
    /// and this package ticks on the main thread alone. A main-thread caller
    /// that blocks on the queue outright therefore waits forever on a write
    /// that is itself waiting for the tick, so the main thread waits in
    /// slices and ticks between them.
    private static let mainThreadPollInterval: TimeInterval = 0.01

    init(
        write: @escaping Write,
        processExit: @escaping ProcessExit,
        tick: @escaping Tick,
        free: @escaping Free = { ghostty_surface_free($0) }
    ) {
        self.write = write
        self.processExit = processExit
        self.tick = tick
        self.free = free
    }

    func setSurface(_ surface: ghostty_surface_t?) {
        condition.lock()
        generation &+= 1
        let previous = self.surface
        self.surface = nil
        waitForActiveOperations(on: previous)
        self.surface = surface
        // Flush what arrived surfaceless, ahead of anything received after
        // this call: both ride the same serial queue, so enqueueing while the
        // lock still excludes `enqueueWrite` preserves stream order.
        if surface != nil {
            let flushGeneration = generation
            if !pendingWrites.isEmpty {
                let flush = pendingWrites
                pendingWrites = Data()
                outputQueue.async { [self] in
                    withSurface(generation: flushGeneration) { surface in
                        write(surface, flush)
                    }
                }
            }
            if let exit = pendingExit {
                pendingExit = nil
                outputQueue.async { [self] in
                    withSurface(generation: flushGeneration) { surface in
                        processExit(surface, exit.exitCode, exit.runtimeMilliseconds)
                    }
                }
            }
        }
        condition.unlock()
    }

    @discardableResult
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) -> Bool {
        condition.lock()
        guard surface == expectedSurface else {
            condition.unlock()
            return false
        }

        generation &+= 1
        surface = nil
        waitForActiveOperations(on: expectedSurface)
        condition.unlock()
        return true
    }

    /// Detach `retired` and take ownership of freeing it, without waiting
    /// for an operation that may never return.
    ///
    /// `clearSurface` waits for in-flight operations, and a write can park
    /// inside `ghostty_surface_write_buffer` for good: an occluded pane
    /// pauses its renderer, the input ring fills, and nothing drains it.
    /// Teardown runs on the main thread — SwiftUI can drop the last
    /// reference to the view from a hover hit-test — and the pane that
    /// would unblock the write is the one being destroyed, so waiting there
    /// hangs the app.
    ///
    /// Instead the pointer is detached at once, so queued and later work
    /// drops. On the main thread the app is ticked for up to
    /// ``retireDrainBudget`` in case the write only needs the mailbox
    /// drained. After that the surface is freed by whichever operation on it
    /// finishes last. Worst case is one leaked surface on a pane that was
    /// already wedged.
    func retireSurface(_ retired: ghostty_surface_t) {
        condition.lock()
        if surface == retired {
            generation &+= 1
            surface = nil
        }
        // A tick below can deliver a close whose handler retires this same
        // surface again; the outer call still owns it.
        guard retiredSurfaces[retired] == nil else {
            condition.unlock()
            return
        }
        retiredSurfaces[retired] = .draining
        if Thread.isMainThread {
            waitForActiveOperations(
                on: retired,
                until: Date(timeIntervalSinceNow: Self.retireDrainBudget)
            )
        }
        guard activeOperations[retired, default: 0] == 0 else {
            retiredSurfaces[retired] = .deferred
            condition.unlock()
            TerminalDebugLog.log(.lifecycle, "in-memory surface free deferred: operation in flight")
            return
        }
        retiredSurfaces[retired] = nil
        condition.unlock()
        free(retired)
    }

    /// Retired surfaces still waiting on an in-flight operation.
    var pendingRetiredSurfaceCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return retiredSurfaces.count
    }

    var currentSurface: ghostty_surface_t? {
        condition.lock()
        defer { condition.unlock() }
        return surface
    }

    func enqueueWrite(_ data: Data) {
        condition.lock()
        guard surface != nil else {
            pendingWrites.append(data)
            let excess = pendingWrites.count - Self.pendingWriteByteLimit
            if excess > 0 {
                pendingWrites.removeFirst(excess)
            }
            condition.unlock()
            return
        }
        let writeGeneration = generation
        condition.unlock()
        outputQueue.async { [self] in
            withSurface(generation: writeGeneration) { surface in
                write(surface, data)
            }
        }
    }

    func enqueueProcessExit(
        exitCode: UInt32,
        runtimeMilliseconds: UInt64
    ) {
        condition.lock()
        guard surface != nil else {
            pendingExit = (exitCode, runtimeMilliseconds)
            condition.unlock()
            return
        }
        let exitGeneration = generation
        condition.unlock()
        outputQueue.async { [self] in
            withSurface(generation: exitGeneration) { surface in
                processExit(surface, exitCode, runtimeMilliseconds)
            }
        }
    }

    func withCurrentSurface<Result>(
        _ operation: (ghostty_surface_t) -> Result
    ) -> Result? {
        condition.lock()
        guard let surface else {
            condition.unlock()
            return nil
        }
        activeOperations[surface, default: 0] += 1
        condition.unlock()

        defer { finishOperation(on: surface) }
        return operation(surface)
    }

    func waitForPendingOutput() {
        guard Thread.isMainThread else {
            outputQueue.sync {}
            return
        }
        let drained = DispatchSemaphore(value: 0)
        outputQueue.async { drained.signal() }
        while drained.wait(timeout: .now() + Self.mainThreadPollInterval) == .timedOut {
            tickCurrentSurface()
        }
    }

    /// Ticks outside the lock and without counting an operation: the tick can
    /// deliver a close, and a host that tears the surface down from that
    /// callback re-enters `clearSurface` on this thread. Teardown is
    /// main-actor work, so the pointer stays valid across a main-thread tick.
    private func tickCurrentSurface() {
        condition.lock()
        let current = surface
        condition.unlock()
        if let current {
            tick(current)
        }
    }

    private func withSurface(
        generation expectedGeneration: UInt64,
        _ operation: (ghostty_surface_t) -> Void
    ) {
        condition.lock()
        guard generation == expectedGeneration, let surface else {
            condition.unlock()
            return
        }
        activeOperations[surface, default: 0] += 1
        condition.unlock()

        defer { finishOperation(on: surface) }
        operation(surface)
    }

    private func finishOperation(on surface: ghostty_surface_t) {
        condition.lock()
        let remaining = activeOperations[surface, default: 1] - 1
        activeOperations[surface] = remaining == 0 ? nil : remaining
        var freeRetired = false
        if remaining == 0 {
            condition.broadcast()
            if retiredSurfaces[surface] == .deferred {
                retiredSurfaces[surface] = nil
                freeRetired = true
            }
        }
        condition.unlock()
        if freeRetired {
            TerminalDebugLog.log(.lifecycle, "in-memory deferred surface free")
            free(surface)
        }
    }

    /// Called with the lock held. `target` is the surface the in-flight
    /// operations use; the caller frees it only after this returns. On the
    /// main thread the app is ticked between waits. Returns early, with
    /// operations possibly still in flight, once `deadline` passes.
    private func waitForActiveOperations(
        on target: ghostty_surface_t?,
        until deadline: Date = .distantFuture
    ) {
        guard let target else { return }
        while activeOperations[target, default: 0] > 0, Date() < deadline {
            guard Thread.isMainThread else {
                _ = condition.wait(until: deadline)
                continue
            }
            let slice = Date(timeIntervalSinceNow: Self.mainThreadPollInterval)
            _ = condition.wait(until: min(slice, deadline))
            guard activeOperations[target, default: 0] > 0 else { return }
            condition.unlock()
            tick(target)
            condition.lock()
        }
    }
}
