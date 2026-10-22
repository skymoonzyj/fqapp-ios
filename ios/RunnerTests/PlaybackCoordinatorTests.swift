import Foundation
import XCTest
#if canImport(Runner)
@testable import Runner
#endif

final class PlaybackCoordinatorTests: XCTestCase {
    func testOldOwnerCannotReleaseNewOwner() throws {
        let center = NotificationCenter()
        var activations = 0
        var deactivations = 0
        var claims: [String?] = []
        let token = center.addObserver(forName: AudioSessionCoordinator.ownerChanged, object: nil, queue: nil) {
            claims.append($0.userInfo?["ownerID"] as? String)
        }
        defer { center.removeObserver(token) }
        let coordinator = AudioSessionCoordinator(notifications: center,
            activate: { activations += 1 }, deactivate: { deactivations += 1 })
        XCTAssertEqual(activations, 0)
        try coordinator.claim(ownerID: "speech:1", kind: .speech)
        try coordinator.claim(ownerID: "video:2", kind: .video)
        coordinator.release(ownerID: "speech:1")
        XCTAssertEqual(coordinator.ownerID, "video:2")
        XCTAssertEqual(deactivations, 0)
        XCTAssertEqual(claims.compactMap { $0 }, ["speech:1", "video:2"])
        coordinator.release(ownerID: "video:2")
        coordinator.release(ownerID: "video:2")
        XCTAssertNil(coordinator.ownerID)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(claims.count, 3)
        XCTAssertNil(claims.last ?? nil)
    }

    func testFailedActivationPreservesCurrentOwner() throws {
        enum Failure: Error { case unavailable }
        var fail = false
        let coordinator = AudioSessionCoordinator(activate: {
            if fail { throw Failure.unavailable }
        }, deactivate: {})
        try coordinator.claim(ownerID: "audio:1", kind: .audio)
        fail = true
        XCTAssertThrowsError(try coordinator.claim(ownerID: "video:2", kind: .video))
        XCTAssertEqual(coordinator.ownerID, "audio:1")
    }
    func testPiPDoesNotSucceedBeforeDidStart() {
        let state = PictureInPictureStart()
        var replies = 0
        state.begin(playerID: 42) { result in
            if case .success = result { replies += 1 }
        }
        XCTAssertEqual(replies, 0)
        XCTAssertNil(state.activePlayerID)
        state.didStart()
        state.didStart()
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(state.activePlayerID, 42)
        state.didStop()
        XCTAssertNil(state.activePlayerID)
    }

    func testPiPFailureCompletesOnlyOnce() {
        let state = PictureInPictureStart()
        var failures = 0
        state.begin(playerID: 1) { result in
            if case .failure = result { failures += 1 }
        }
        state.didFail(NSError(domain: "fixture", code: 1))
        state.didFail(NSError(domain: "fixture", code: 2))
        state.didStart()
        XCTAssertEqual(failures, 1)
        XCTAssertNil(state.activePlayerID)
    }
    func testPiPWaitsForDelayedPossibilityAndActualStart() {
        let state = PictureInPictureStart()
        var starts = 0
        var replies = 0
        state.begin(playerID: 7, requestStart: { starts += 1 }) { _ in replies += 1 }
        state.possibilityChanged(false)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(replies, 0)
        state.possibilityChanged(true)
        state.possibilityChanged(true)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(replies, 0)
        state.didStart()
        XCTAssertEqual(replies, 1)
    }

    func testPiPWaitingCancellationCompletesOnceAndIgnoresLateReadiness() {
        let state = PictureInPictureStart()
        var starts = 0
        var failures = 0
        state.begin(playerID: 7, requestStart: { starts += 1 }) { result in
            if case .failure = result { failures += 1 }
        }
        state.didStop()
        state.didStop()
        state.possibilityChanged(true)
        state.didStart()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(failures, 1)
        XCTAssertNil(state.activePlayerID)
    }

    func testPiPReadyStartFailureCannotRetryOrSucceedLate() {
        let state = PictureInPictureStart()
        var starts = 0
        var failures = 0
        state.begin(playerID: 7, requestStart: { starts += 1 }) { result in
            if case .failure = result { failures += 1 }
        }
        state.possibilityChanged(true)
        XCTAssertEqual(starts, 1)
        state.didFail(NSError(domain: "fixture", code: 1))
        state.possibilityChanged(true)
        state.didStart()
        state.didStop()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertNil(state.activePlayerID)
    }

    func testInterruptionsAndHeadphoneRemovalAlwaysPause() {
        let policy = PlaybackPolicy(backgroundAudio: true, pictureInPicture: true)
        XCTAssertTrue(policy.mustPause(for: .interruption))
        XCTAssertTrue(policy.mustPause(for: .routeDisconnected))
    }
    func testBackgroundNeedsExplicitContinuation() {
        XCTAssertTrue(PlaybackPolicy().mustPause(for: .background))
        XCTAssertFalse(PlaybackPolicy(backgroundAudio: true).mustPause(for: .background))
        XCTAssertFalse(PlaybackPolicy(pictureInPicture: true).mustPause(for: .background))
        XCTAssertTrue(PlaybackPolicy(backgroundAudio: true).mustPause(for: .backgroundDisabled))
    }
}
