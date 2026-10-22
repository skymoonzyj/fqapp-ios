import Foundation

/// A native utterance has a unique token even when Dart reuses an ID. Delegate
/// callbacks are accepted only while that exact utterance owns the session.
final class SpeechSession {
    private struct Utterance { let token: UUID; let id: String; let text: NSString }
    private var current: Utterance?
    private let emit: ([String: Any]) -> Void

    init(emit: @escaping ([String: Any]) -> Void) { self.emit = emit }

    func begin(id: String, text: String) -> UUID {
        let token = UUID()
        current = Utterance(token: token, id: id, text: text as NSString)
        return token
    }

    func started(token: UUID) { send(token: token, type: "start") }

    func range(token: UUID, range: NSRange) {
        guard let value = current, value.token == token, range.location != NSNotFound,
              range.location >= 0, range.length > 0, range.location < value.text.length,
              range.length <= value.text.length - range.location else { return }
        var start = range.location
        var end = range.location + range.length
        // AVSpeech uses NSRange UTF-16 offsets. Protect both boundaries even
        // when a system voice reports a range inside a surrogate pair.
        if start > 0 && isLow(value.text.character(at: start)) { start -= 1 }
        if end < value.text.length && isLow(value.text.character(at: end)) { end += 1 }
        emit(["type": "range", "id": value.id, "start": start, "end": end])
    }

    func finished(token: UUID) { send(token: token, type: "done", terminal: true) }
    func failed(token: UUID) { send(token: token, type: "error", terminal: true) }
    func cancel() {
        guard let value = current else { return }
        send(token: value.token, type: "interrupted", terminal: true)
    }
    var isActive: Bool { current != nil }

    private func send(token: UUID, type: String, terminal: Bool = false) {
        guard let value = current, value.token == token else { return }
        if terminal { current = nil }
        emit(["type": type, "id": value.id])
    }
    private func isLow(_ unit: unichar) -> Bool { (0xDC00...0xDFFF).contains(unit) }
}
