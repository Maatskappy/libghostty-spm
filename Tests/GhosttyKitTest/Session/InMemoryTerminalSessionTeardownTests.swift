@testable import GhosttyTerminal
import Foundation
import GhosttyKit
import Testing

/// Teardown must never wait on a `ghostty_surface_*` call that is parked
/// inside ghostty.
///
/// The failure this pins down: `ghostty_surface_write_buffer` blocks while a
/// pane's renderer is paused (an occluded terminal fills the input ring and
/// nothing drains it). Meanwhile SwiftUI drops the last reference to the
/// terminal view — a hover hit-test is enough — so the coordinator's teardown
/// runs on the main thread. If teardown waits for that write, the main thread
/// waits forever: the write only unblocks when the pane becomes visible, and
/// the pane is being destroyed.
struct InMemoryTerminalSessionTeardownTests {
    /// The fixed path takes microseconds, the broken path never returns, so
    /// anything in between distinguishes them.
    private static let teardownBudget: TimeInterval = 2

    @Test
    func `retiring a surface does not block on a parked write`() {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let session = makeSession { _, _ in
            parked.signal()
            release.wait()
        }
        let surface = testSurface(0x10)
        session.setSurface(surface)
        session.receive("parks")
        #expect(parked.wait(timeout: .now() + Self.teardownBudget) == .success)

        let toreDown = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.retireSurface(surface)
            toreDown.signal()
        }

        #expect(
            toreDown.wait(timeout: .now() + Self.teardownBudget) == .success,
            "retireSurface blocked behind a parked write — this is the hang"
        )
        release.signal()
        session.waitForPendingOutput()
    }

    @Test
    func `a retired surface is detached at once and freed when its write drains`() {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let freed = LockedValues<Int>()
        let writes = LockedValues<String>()
        let session = makeSession(
            surfaceWrite: { _, data in
                writes.append(String(decoding: data, as: UTF8.self))
                parked.signal()
                release.wait()
            },
            surfaceFree: { freed.append(Int(bitPattern: $0)) }
        )
        let surface = testSurface(0x20)
        session.setSurface(surface)
        session.receive("parks")
        session.receive("stale")
        #expect(parked.wait(timeout: .now() + Self.teardownBudget) == .success)

        session.retireSurface(surface)
        #expect(session.currentSurface == nil)
        #expect(session.pendingRetiredSurfaceCount == 1)
        #expect(freed.values.isEmpty)

        release.signal()
        session.waitForPendingOutput()
        #expect(freed.values == [0x20])
        #expect(session.pendingRetiredSurfaceCount == 0)
        #expect(writes.values == ["parks"])
    }

    @Test
    func `an idle surface is freed immediately on retire`() {
        let freed = LockedValues<Int>()
        let session = makeSession(
            surfaceWrite: { _, _ in },
            surfaceFree: { freed.append(Int(bitPattern: $0)) }
        )
        let surface = testSurface(0x30)
        session.setSurface(surface)

        session.retireSurface(surface)
        #expect(session.currentSurface == nil)
        #expect(session.pendingRetiredSurfaceCount == 0)
        #expect(freed.values == [0x30])
    }

    /// A write parked on the retired surface must not stall attaching the
    /// next one — the in-flight count is per surface.
    @Test
    func `attaching a new surface does not wait on a retired surface's write`() {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let session = makeSession { _, _ in
            parked.signal()
            release.wait()
        }
        let retired = testSurface(0x40)
        session.setSurface(retired)
        session.receive("parks")
        #expect(parked.wait(timeout: .now() + Self.teardownBudget) == .success)
        session.retireSurface(retired)

        let attached = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.setSurface(testSurface(0x50))
            attached.signal()
        }
        #expect(attached.wait(timeout: .now() + Self.teardownBudget) == .success)
        #expect(session.currentSurface == testSurface(0x50))

        release.signal()
        session.waitForPendingOutput()
    }
}

private func makeSession(
    surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write,
    surfaceFree: @escaping InMemoryTerminalSurfaceAccess.Free = { _ in }
) -> InMemoryTerminalSession {
    InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in },
        surfaceWrite: surfaceWrite,
        surfaceFree: surfaceFree
    )
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
