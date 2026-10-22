import XCTest
#if canImport(Runner)
@testable import Runner
#endif

final class SpeechSessionTests: XCTestCase {
    func testUTF16RangeNeverSplitsSurrogatePair() {
        var events: [[String: Any]] = []
        let speech = SpeechSession(emit: { events.append($0) })
        let token = speech.begin(id: "one", text: "A😀中文")
        speech.range(token: token, range: NSRange(location: 2, length: 1))
        XCTAssertEqual(events.last?["start"] as? Int, 1)
        XCTAssertEqual(events.last?["end"] as? Int, 3)
        speech.range(token: token, range: NSRange(location: 50, length: 1))
        XCTAssertEqual(events.count, 1)
    }

    func testLateCallbacksAfterReplacementAndStopAreIgnored() {
        var events: [[String: Any]] = []
        let speech = SpeechSession(emit: { events.append($0) })
        let old = speech.begin(id: "old", text: "旧")
        let current = speech.begin(id: "new", text: "新")
        speech.finished(token: old)
        speech.started(token: old)
        speech.range(token: old, range: NSRange(location: 0, length: 1))
        XCTAssertTrue(events.isEmpty)
        speech.started(token: current)
        speech.cancel()
        speech.finished(token: current)
        speech.cancel()
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["start", "interrupted"])
        XCTAssertEqual(events.last?["id"] as? String, "new")
    }

    func testCompletionAndInterruptionAreExactlyOnce() {
        var events: [[String: Any]] = []
        let speech = SpeechSession(emit: { events.append($0) })
        let token = speech.begin(id: "done", text: "文")
        speech.finished(token: token)
        speech.finished(token: token)
        speech.cancel()
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["done"])
    }
}
