import Foundation
import XCTest
@testable import SpotifyLite

final class PlaybackReconcileTests: XCTestCase {
    private typealias Decision = PlaybackCoordinator.ReconcileDecision
    private typealias PendingTrack = PlaybackCoordinator.PendingTrack

    private let now = ContinuousClock.now
    private var later: ContinuousClock.Instant { now.advanced(by: .seconds(5)) }
    private var earlier: ContinuousClock.Instant { now.advanced(by: .seconds(-5)) }

    // MARK: Receiver restart

    func testRestartWaitHoldsAnyObservation() {
        let held = makeState(id: "held", playing: true)
        for observed in [nil, makeState(id: "other", playing: true)] {
            let decision = reconcile(observed: observed, held: held, restartDeadline: later,
                pending: PendingTrack(uri: "spotify:track:other", deadline: earlier), recovering: false)
            XCTAssertEqual(decision, Decision(outcome: .hold))
        }
    }

    func testExpiredRestartWaitIsClearedAndObservationApplied() {
        let observed = makeState(id: "other", playing: true)
        let decision = reconcile(observed: observed, held: makeState(id: "held", playing: true),
            restartDeadline: earlier)
        XCTAssertEqual(decision, Decision(outcome: .apply(observed), restartTimedOut: true))
    }

    func testRestartDeadlineReachedExactlyHasExpired() {
        let decision = reconcile(observed: nil, held: nil, restartDeadline: now)
        XCTAssertEqual(decision, Decision(outcome: .apply(nil), restartTimedOut: true))
    }

    func testExpiredRestartWaitStillDefersToPendingTrack() {
        let decision = reconcile(observed: makeState(id: "old", playing: true), held: nil,
            restartDeadline: earlier, pending: PendingTrack(uri: "spotify:track:new", deadline: later))
        XCTAssertEqual(decision, Decision(outcome: .hold, restartTimedOut: true))
    }

    // MARK: Pending selected track

    func testConfirmedPendingTrackIsClearedAndApplied() {
        let observed = makeState(id: "new", playing: true)
        let decision = reconcile(observed: observed, held: nil,
            pending: PendingTrack(uri: "spotify:track:new", deadline: later))
        XCTAssertEqual(decision, Decision(outcome: .apply(observed), clearsPendingTrack: true))
    }

    func testConfirmedPendingTrackIsAcceptedAfterDeadline() {
        let observed = makeState(id: "new", playing: true)
        let decision = reconcile(observed: observed, held: nil,
            pending: PendingTrack(uri: "spotify:track:new", deadline: earlier))
        XCTAssertEqual(decision, Decision(outcome: .apply(observed), clearsPendingTrack: true))
    }

    func testUnconfirmedPendingTrackHoldsUntilDeadline() {
        let pending = PendingTrack(uri: "spotify:track:new", deadline: later)
        for observed in [nil, makeState(id: "old", playing: true), makeState(id: "new", playing: false)] {
            let decision = reconcile(observed: observed, held: makeState(id: "new", playing: true),
                pending: pending)
            XCTAssertEqual(decision, Decision(outcome: .hold))
        }
    }

    func testExpiredPendingTrackIsClearedAndObservationApplied() {
        let observed = makeState(id: "old", playing: true)
        let decision = reconcile(observed: observed, held: makeState(id: "new", playing: true),
            pending: PendingTrack(uri: "spotify:track:new", deadline: earlier))
        XCTAssertEqual(decision, Decision(outcome: .apply(observed), clearsPendingTrack: true))
    }

    func testExpiredPendingTrackFallsThroughToEmptyResponseHandling() {
        let held = makeState(id: "new", playing: true)
        let decision = reconcile(observed: nil, held: held,
            pending: PendingTrack(uri: "spotify:track:new", deadline: earlier), recovering: true)
        XCTAssertEqual(decision, Decision(outcome: .holdPlaying, clearsPendingTrack: true))
    }

    // MARK: Empty responses

    func testEmptyResponseDuringRecoveryKeepsPlayingState() {
        let decision = reconcile(observed: nil, held: makeState(id: "held", playing: true),
            recovering: true)
        XCTAssertEqual(decision, Decision(outcome: .holdPlaying))
    }

    func testEmptyResponseDuringRecoveryMarksPausedStatePaused() {
        let held = makeState(id: "held", playing: false)
        let decision = reconcile(observed: nil, held: held, recovering: true)
        XCTAssertEqual(decision, Decision(outcome: .markPaused(paused(held))))
    }

    func testEmptyResponseMarksHeldTrackPausedOnInactiveDevice() {
        let held = makeState(id: "held", playing: true, progressMS: 42_000)
        let decision = reconcile(observed: nil, held: held)
        guard case .markPaused(let state) = decision.outcome else {
            return XCTFail("Expected markPaused, got \(decision.outcome)")
        }
        XCTAssertEqual(state.item, held.item)
        XCTAssertEqual(state.progressMS, 42_000)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.device?.id, held.device?.id)
        XCTAssertEqual(state.device?.isActive, false)
        XCTAssertFalse(decision.restartTimedOut)
        XCTAssertFalse(decision.clearsPendingTrack)
    }

    func testEmptyResponseKeepsDevicelessHeldTrackDeviceless() {
        var held = makeState(id: "held", playing: true)
        held.device = nil
        let decision = reconcile(observed: nil, held: held)
        XCTAssertEqual(decision, Decision(outcome: .markPaused(paused(held))))
    }

    func testEmptyResponseWithoutHeldTrackAppliesNothing() {
        var itemless = makeState(id: "held", playing: true)
        itemless.item = nil
        XCTAssertEqual(reconcile(observed: nil, held: itemless), Decision(outcome: .apply(nil)))
        // Recovery holds any playing state, even one without a track.
        XCTAssertEqual(reconcile(observed: nil, held: itemless, recovering: true),
            Decision(outcome: .holdPlaying))
        XCTAssertEqual(reconcile(observed: nil, held: nil), Decision(outcome: .apply(nil)))
    }

    func testObservedStateWinsDuringRecovery() {
        let observed = makeState(id: "other", playing: false)
        let decision = reconcile(observed: observed, held: makeState(id: "held", playing: true),
            recovering: true)
        XCTAssertEqual(decision, Decision(outcome: .apply(observed)))
    }

    // MARK: Helpers

    private func reconcile(
        observed: PlaybackState?,
        held: PlaybackState?,
        restartDeadline: ContinuousClock.Instant? = nil,
        pending: PendingTrack? = nil,
        recovering: Bool = false
    ) -> Decision {
        PlaybackCoordinator.reconcile(
            observed: observed,
            held: held,
            restartDeadline: restartDeadline,
            pending: pending,
            recovering: recovering,
            now: now
        )
    }

    private func paused(_ state: PlaybackState) -> PlaybackState {
        var paused = state
        paused.isPlaying = false
        paused.device?.isActive = false
        return paused
    }

    private func makeState(id: String, playing: Bool, progressMS: Int = 10_000) -> PlaybackState {
        PlaybackState(
            item: SpotifyTrack(
                id: id,
                name: id,
                uri: "spotify:track:\(id)",
                durationMS: 180_000,
                explicit: false,
                artists: [],
                album: nil
            ),
            progressMS: progressMS,
            isPlaying: playing,
            device: makeDevice(id: "local", active: true),
            shuffle: false,
            repeatMode: .off
        )
    }

    private func makeDevice(id: String, active: Bool) -> SpotifyDevice {
        SpotifyDevice(
            id: id,
            isActive: active,
            isPrivateSession: false,
            isRestricted: false,
            name: "Spotify Lite — Test Mac",
            type: "computer",
            volumePercent: 50,
            supportsVolume: true
        )
    }
}
