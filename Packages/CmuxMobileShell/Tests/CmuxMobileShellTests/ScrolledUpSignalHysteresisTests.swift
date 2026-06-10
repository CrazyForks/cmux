import Foundation
import Testing
@testable import CmuxMobileShell

/// Hysteresis tests for the jump-to-bottom affordance's scrolled-up signal.
///
/// The Mac stamps `atBottom` on every render-grid frame from its live
/// scrollbar, so the raw per-frame signal can blip near the at-bottom boundary
/// (drags, streaming output). The displayed
/// ``MobileShellComposite/terminalScrolledUpBySurfaceID`` must flip only after
/// the raw signal holds a new value for the stability window
/// (``MobileShellComposite/scrolledUpStabilityWindow``), so the floating button
/// never flickers with frame noise. The explicit jump-to-bottom tap is the one
/// exception: it hides the button immediately.
@MainActor
@Suite struct ScrolledUpSignalHysteresisTests {
    private static let surfaceID = "surface-1"

    private static func makeComposite(clock: ManualTestClock) -> MobileShellComposite {
        MobileShellComposite(scrolledUpSignalClock: clock)
    }

    /// Drive the composite to a settled, visible scrolled-up state. Takes the
    /// stability-window path only when the flip is actually deferred, so a
    /// pre-hysteresis implementation (immediate flip, no sleeper) cannot hang
    /// the suite waiting for a sleeper that never parks.
    private static func settleScrolledUp(
        _ composite: MobileShellComposite,
        clock: ManualTestClock
    ) async {
        composite.ingestTerminalScrolledUpSignal(surfaceID: surfaceID, scrolledUp: true)
        if !composite.terminalScrolledUp(surfaceID: surfaceID) {
            await clock.waitUntilSleepers(count: 1)
            clock.advance(by: MobileShellComposite.scrolledUpStabilityWindow)
            await composite.drainScrolledUpSettleForTesting()
        }
    }

    @Test func showIsDeferredUntilSignalHoldsStable() async throws {
        let clock = ManualTestClock()
        let composite = Self.makeComposite(clock: clock)

        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: true)
        // A single frame must not show the button yet; the signal has to hold.
        try #require(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == false)

        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: MobileShellComposite.scrolledUpStabilityWindow)
        await composite.drainScrolledUpSettleForTesting()
        #expect(composite.terminalScrolledUp(surfaceID: Self.surfaceID))
    }

    @Test func transientScrolledUpBlipNeverShows() async throws {
        let clock = ManualTestClock()
        let composite = Self.makeComposite(clock: clock)

        // One frame reports scrolled-up (boundary noise), the next reports
        // at-bottom again, all inside the stability window.
        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: true)
        try #require(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == false)
        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: false)

        clock.advance(by: .seconds(10))
        await composite.drainScrolledUpSettleForTesting()
        // The blip never reaches the UI, even long after the window elapsed.
        #expect(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == false)
    }

    @Test func transientAtBottomBlipKeepsButtonShown() async throws {
        let clock = ManualTestClock()
        let composite = Self.makeComposite(clock: clock)
        await Self.settleScrolledUp(composite, clock: clock)

        // While scrolled up, one frame blips at-bottom and the next restores
        // scrolled-up inside the window: the button must never disappear.
        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: false)
        try #require(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == true)
        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: true)

        clock.advance(by: .seconds(10))
        await composite.drainScrolledUpSettleForTesting()
        #expect(composite.terminalScrolledUp(surfaceID: Self.surfaceID))
    }

    @Test func sustainedAtBottomHidesAfterStabilityWindow() async throws {
        let clock = ManualTestClock()
        let composite = Self.makeComposite(clock: clock)
        await Self.settleScrolledUp(composite, clock: clock)

        composite.ingestTerminalScrolledUpSignal(surfaceID: Self.surfaceID, scrolledUp: false)
        // Not hidden yet: the at-bottom report has to hold for the window.
        try #require(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == true)

        await clock.waitUntilSleepers(count: 1)
        clock.advance(by: MobileShellComposite.scrolledUpStabilityWindow)
        await composite.drainScrolledUpSettleForTesting()
        #expect(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == false)
    }

    @Test func jumpToBottomTapHidesImmediately() async throws {
        let clock = ManualTestClock()
        let composite = Self.makeComposite(clock: clock)
        await Self.settleScrolledUp(composite, clock: clock)
        try #require(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == true)

        // The tap's intent is "go to the bottom now": the button must vanish
        // with the tap, not a render round-trip plus stability window later.
        await composite.scrollTerminalToBottom(surfaceID: Self.surfaceID)
        #expect(composite.terminalScrolledUp(surfaceID: Self.surfaceID) == false)
    }
}
