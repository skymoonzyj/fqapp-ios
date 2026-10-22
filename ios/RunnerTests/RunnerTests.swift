import Flutter
import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  @MainActor
  func testAwakeOwnersDoNotReleaseEachOther() {
    let coordinator = AwakeCoordinator.shared
    coordinator.set(ownerID: "reader-test", enabled: true)
    coordinator.set(ownerID: "player-test", enabled: true)
    coordinator.set(ownerID: "reader-test", enabled: false)
    XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    coordinator.set(ownerID: "player-test", enabled: false)
    XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
  }
}
