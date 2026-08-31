import Foundation
@testable import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// Teardown must never wait on a `ghostty_surface_*` call that is parked
/// inside ghostty.
///
/// The failure this pins down: `ghostty_surface_write_buffer` backpressure-
/// blocks while a pane's renderer is paused (an occluded terminal fills the
/// input ring and nothing drains it). The feed sits inside that call holding
/// the surface-serialization lock. Meanwhile SwiftUI drops the last reference
/// to the terminal view — a hover hit-test is enough — so
/// `TerminalSurfaceCoordinator.deinit` runs `tearDownSurface` on the main
/// thread, which used to take that same lock. The write only unblocks when the
/// pane becomes visible, and the pane is being destroyed, so the main thread
/// waited forever: a permanent app hang with the terminal's own feed queue as
/// the lock holder.
struct InMemoryTerminalSessionTeardownTests {
    /// A pointer that is never dereferenced. Every assertion below stays on the
    /// deferred path, which stores the pointer instead of calling
    /// `ghostty_surface_free` on it.
    private static var fakeSurface: ghostty_surface_t {
        ghostty_surface_t(bitPattern: 0xDEAD_BEEF)!
    }

    /// How long teardown is allowed to take while a call is parked. Generous:
    /// the fixed path takes microseconds, the broken path never returns, so
    /// anything in between distinguishes them.
    private static let teardownBudget: TimeInterval = 2

    @Test
    func `retiring a surface does not block on a parked surface call`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        session.setSurface(Self.fakeSurface)

        // Stand in for the feed parked inside ghostty_surface_write_buffer:
        // claim a surface call on another thread and never give it back.
        let parked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            #expect(session.simulateSurfaceCallInFlight() != nil)
            parked.signal()
            // Deliberately never calls endSimulatedSurfaceCall() — the whole
            // point is that this call outlives teardown.
        }
        #expect(parked.wait(timeout: .now() + Self.teardownBudget) == .success)

        // Teardown, as it runs from the coordinator's deinit.
        let toreDown = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.retireSurface(Self.fakeSurface)
            toreDown.signal()
        }

        #expect(
            toreDown.wait(timeout: .now() + Self.teardownBudget) == .success,
            "retireSurface blocked behind a parked surface call — this is the hang"
        )
    }

    /// Teardown must still detach the pointer even though it defers the free,
    /// so a feed that arrives afterwards drops its bytes instead of writing
    /// into a surface that is going away.
    @Test
    func `a retired surface is detached immediately and freed later`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        session.setSurface(Self.fakeSurface)

        let parked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = session.simulateSurfaceCallInFlight()
            parked.signal()
        }
        #expect(parked.wait(timeout: .now() + Self.teardownBudget) == .success)

        // Bounded, so a regression fails this test instead of wedging the suite.
        let toreDown = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.retireSurface(Self.fakeSurface)
            toreDown.signal()
        }
        #expect(toreDown.wait(timeout: .now() + Self.teardownBudget) == .success)

        #expect(session.currentSurface == nil)
        #expect(session.pendingRetiredSurfaceCount == 1)
    }

    /// With nothing in flight, `clearSurface` and `retireSurface` agree that
    /// the pointer is gone.
    @Test
    func `clearing a surface detaches it`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        session.setSurface(Self.fakeSurface)
        #expect(session.currentSurface != nil)

        session.clearSurface(ifMatches: Self.fakeSurface)
        #expect(session.currentSurface == nil)
        #expect(session.pendingRetiredSurfaceCount == 0)
    }
}
