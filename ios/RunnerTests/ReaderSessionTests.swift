import XCTest
#if canImport(Runner)
@testable import Runner
#endif

final class ReaderSessionTests: XCTestCase {
    func testOldSessionCannotRestoreNewSessionBrightness() {
        var brightness = 0.7
        let reader = ReaderSession(readBrightness: { brightness }, writeBrightness: { brightness = $0 }, setAwake: { _, _ in })
        reader.start(id: "old", brightness: 0.2)
        reader.start(id: "new", brightness: 0.4)
        reader.stop(id: "old")
        XCTAssertEqual(brightness, 0.4)
        reader.stop(id: "new")
        XCTAssertEqual(brightness, 0.7)
    }

    func testBackgroundRestoresBrightnessAndFollowSystemDoesNotOverwrite() {
        var brightness = 0.6
        let reader = ReaderSession(readBrightness: { brightness }, writeBrightness: { brightness = $0 }, setAwake: { _, _ in })
        reader.start(id: "reader", brightness: 0.2)
        reader.suspend(id: "reader")
        XCTAssertEqual(brightness, 0.6)
        brightness = 0.8
        reader.start(id: "reader", brightness: -1)
        reader.stop(id: "reader")
        XCTAssertEqual(brightness, 0.8)
    }

    func testReaderReleasesOnlyItsAwakeOwner() {
        var owners: Set<String> = ["player"]
        let reader = ReaderSession(readBrightness: { 0.5 }, writeBrightness: { _ in }, setAwake: { owner, enabled in
            if enabled { owners.insert(owner) } else { owners.remove(owner) }
        })
        reader.start(id: "one", brightness: -1)
        reader.keepScreenOn(id: "one", enabled: true)
        reader.start(id: "two", brightness: -1)
        reader.keepScreenOn(id: "two", enabled: true)
        reader.stop(id: "one")
        XCTAssertEqual(owners, ["player", "reader:two"])
        reader.suspend(id: "two")
        XCTAssertEqual(owners, ["player"])
    }
}
