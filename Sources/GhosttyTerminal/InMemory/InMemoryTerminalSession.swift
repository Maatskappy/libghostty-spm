//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    /// Guards the bookkeeping below — the `surface` pointer, the in-flight
    /// count, and the retirement list. **Never held across a `ghostty_surface_*`
    /// call**, so acquiring it is always bounded. That property is what makes
    /// teardown safe: `retireSurface` runs on the main thread out of a `deinit`,
    /// and it must never be able to wait on a wedged terminal.
    private let stateLock = NSLock()
    /// Serializes the `ghostty_surface_*` calls against each other — ghostty's
    /// surface is not safe for concurrent access, so write (receive) and the
    /// viewport/scrollback/selection reads must never run at the same time.
    /// Held ACROSS the ghostty call, and therefore held for an unbounded time:
    /// `ghostty_surface_write_buffer` backpressure-blocks while the surface's
    /// renderer is paused (an occluded pane), and only unblocks when the pane
    /// becomes visible again. Nothing on the main thread may ever wait on this.
    private let callLock = NSLock()
    /// Separate lock for resize bookkeeping (`lastResize`) only — never held
    /// across a ghostty call, never contends with the two above. Keeps the
    /// resize callback off the surface-serialization lock: ghostty fires that
    /// callback while holding its own internal surface lock, so taking
    /// `callLock` here would deadlock (ABBA) against an in-flight write that
    /// holds `callLock` and is waiting on ghostty's internal lock.
    private let resizeLock = NSLock()
    private var surface: ghostty_surface_t?
    /// Number of `ghostty_surface_*` calls currently holding a raw pointer
    /// handed out by ``withSurface(_:_:)``. Guarded by `stateLock`.
    private var inFlightCalls = 0
    /// Surfaces detached by ``retireSurface(_:)`` while a call was still in
    /// flight on them. Freed by the last call to drain. Guarded by `stateLock`.
    private var retiredSurfaces: [ghostty_surface_t] = []
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.surface = surface
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    /// Detach the surface pointer without freeing it.
    ///
    /// Takes `stateLock` only, so it CANNOT block behind an in-flight
    /// `ghostty_surface_write_buffer`. See ``retireSurface(_:)`` for the
    /// teardown path that also disposes of the surface.
    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            return
        }

        surface = nil
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return surface
    }

    /// Take ownership of `raw` away from the caller and free it as soon as it
    /// is safe to do so — immediately if no `ghostty_surface_*` call is in
    /// flight, otherwise from whichever call drains last.
    ///
    /// This exists because teardown runs on the main thread (out of
    /// `TerminalSurfaceCoordinator.deinit`, which SwiftUI can trigger from
    /// something as ordinary as a hover hit-test releasing the terminal view)
    /// while a feed may be parked inside `ghostty_surface_write_buffer` on an
    /// occluded pane, holding `callLock`. Waiting for that write — which only
    /// unblocks when the pane becomes visible, and the pane is being destroyed
    /// — hung the whole app until the user force-quit it.
    ///
    /// The worst case here is that a genuinely wedged surface is never freed:
    /// one leaked surface on a pane that was already stuck, instead of a dead
    /// application.
    func retireSurface(_ raw: ghostty_surface_t) {
        stateLock.lock()
        if surface == raw { surface = nil }
        guard inFlightCalls == 0 else {
            retiredSurfaces.append(raw)
            stateLock.unlock()
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session surface retired (deferred: call in flight)"
            )
            return
        }
        stateLock.unlock()
        TerminalDebugLog.log(.lifecycle, "in-memory session surface retired (freed)")
        ghostty_surface_free(raw)
    }

    /// Claim the live surface for a `ghostty_surface_*` call: snapshots the
    /// pointer, counts the call in flight (so ``retireSurface(_:)`` can't free
    /// it underneath us), then takes `callLock` to serialize against the other
    /// surface calls. Returns `nil` when no surface is attached — in which case
    /// the caller must NOT pair it with ``endSurfaceCall()``.
    ///
    /// Always used as `guard let surface = beginSurfaceCall() else { … }` /
    /// `defer { endSurfaceCall() }`.
    private func beginSurfaceCall() -> ghostty_surface_t? {
        stateLock.lock()
        guard let surface else {
            stateLock.unlock()
            return nil
        }
        inFlightCalls += 1
        stateLock.unlock()

        callLock.lock()
        return surface
    }

    #if DEBUG
        /// Test seam. There is no way to park a real `ghostty_surface_*` call
        /// from a unit test (it needs a live surface and a paused renderer), so
        /// tests stand in for one by claiming and holding a call directly. This
        /// is the only supported way to exercise the teardown-while-parked path
        /// that hung the app.
        func simulateSurfaceCallInFlight() -> ghostty_surface_t? { beginSurfaceCall() }
        func endSimulatedSurfaceCall() { endSurfaceCall() }
        /// Surfaces detached by ``retireSurface(_:)`` that are still waiting on
        /// an in-flight call before they can be freed.
        var pendingRetiredSurfaceCount: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return retiredSurfaces.count
        }
    #endif

    /// Release `callLock` and, if this was the last call in flight, free any
    /// surface ``retireSurface(_:)`` detached while we were inside ghostty.
    private func endSurfaceCall() {
        callLock.unlock()

        stateLock.lock()
        inFlightCalls -= 1
        let drained = inFlightCalls == 0 ? retiredSurfaces : []
        if inFlightCalls == 0 { retiredSurfaces.removeAll() }
        stateLock.unlock()

        // Free outside both locks — `ghostty_surface_free` re-enters ghostty.
        for retired in drained {
            TerminalDebugLog.log(.lifecycle, "in-memory session retired surface freed")
            ghostty_surface_free(retired)
        }
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe: acquires the same `NSLock` as `receive(_:)` and
    /// `setSurface(_:)`, preventing reads against a surface mid-replacement.
    public func readViewportText() -> String? {
        // Holds `callLock` across the ghostty call to serialize surface access
        // against receive() and the other reads. Safe from ABBA because the
        // resize callback uses `resizeLock`, not this one. See `callLock`.
        guard let surface = beginSurfaceCall() else { return nil }
        defer { endSurfaceCall() }

        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Scrollback Read (Inby fork addition)

    /// Returns the full screen including scrollback history as a UTF-8 string,
    /// or `nil` if no surface is attached. Lines are separated by `\n`. Same
    /// `ghostty_text_s` lifecycle and locking as ``readViewportText()`` — the C
    /// buffer is fully encapsulated.
    ///
    /// Selection grammar: `(SCREEN, TOP_LEFT)` to `(SCREEN, BOTTOM_RIGHT)` with
    /// `rectangle: false` (linear flow). Unlike ``readViewportText()`` (which is
    /// pinned to `VIEWPORT`), this reads the entire screen buffer — what callers
    /// like Inby's `inby server logs` need for full scrollback fidelity.
    public func readScrollbackText() -> String? {
        // See readViewportText(): holds `callLock` across the ghostty call.
        guard let surface = beginSurfaceCall() else { return nil }
        defer { endSurfaceCall() }

        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Selection Read (Inby fork addition)

    /// Whether the surface currently has a non-empty text selection.
    /// Non-destructive — does not touch the pasteboard.
    public func hasSelection() -> Bool {
        // See readViewportText(): holds `callLock` across the ghostty call.
        guard let surface = beginSurfaceCall() else { return false }
        defer { endSurfaceCall() }
        return ghostty_surface_has_selection(surface)
    }

    /// The current selection as a UTF-8 string, or `nil` if there is no surface
    /// or no selection. Non-destructive — unlike
    /// `AppTerminalView.copySelectedTextToPasteboard()`, this does not mutate
    /// the pasteboard. Same `ghostty_text_s` lifecycle as ``readViewportText()``.
    public func readSelectionText() -> String? {
        // See readViewportText(): holds `callLock` across the ghostty call.
        guard let surface = beginSurfaceCall() else { return nil }
        defer { endSurfaceCall() }

        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        // Holds `callLock` across ghostty_surface_write_buffer to serialize
        // surface access against the reads (snapshot/scrollback/selection) —
        // ghostty's surface is not concurrency-safe. The resize callback uses
        // `resizeLock`, NOT this lock, so this can't ABBA-deadlock against a
        // window resize. See `callLock`.
        //
        // This is the call that parks: `ghostty_surface_write_buffer` blocks
        // while the surface's renderer is paused (occluded pane, full input
        // ring). `callLock` is therefore held for an unbounded time — which is
        // exactly why teardown goes through `retireSurface`, which never waits
        // on it.
        guard let surface = beginSurfaceCall() else {
            TerminalDebugLog.log(
                .output,
                "terminal <- host dropped \(TerminalDebugLog.describe(data))"
            )
            return
        }
        defer { endSurfaceCall() }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        guard let surface = beginSurfaceCall() else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }
        defer { endSurfaceCall() }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        // Use `resizeLock`, NOT `lock`. ghostty fires this callback while holding
        // its own internal surface lock; taking `lock` here would deadlock (ABBA)
        // against an in-flight receive()/read that holds `lock` and is waiting on
        // ghostty's internal lock. This body only touches `lastResize` (no surface
        // / no ghostty call), so a separate lock is sufficient.
        resizeLock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        lastResize = mergedResize
        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
