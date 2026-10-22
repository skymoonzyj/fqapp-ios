import Foundation

/// Main-thread reader state. Device writes are injected so session ownership is
/// independently testable without changing global screen or idle-timer state.
final class ReaderSession {
    private let readBrightness: () -> Double
    private let writeBrightness: (Double) -> Void
    private let setAwake: (String, Bool) -> Void
    private(set) var id: String?
    private var originalBrightness: Double?

    init(readBrightness: @escaping () -> Double, writeBrightness: @escaping (Double) -> Void,
         setAwake: @escaping (String, Bool) -> Void) {
        self.readBrightness = readBrightness
        self.writeBrightness = writeBrightness
        self.setAwake = setAwake
    }

    func start(id: String, brightness: Double) {
        if self.id != id {
            if let old = self.id { stop(id: old) }
            self.id = id
        }
        _ = setBrightness(id: id, brightness: brightness)
    }

    @discardableResult
    func setBrightness(id: String, brightness: Double) -> Bool {
        guard self.id == id, brightness.isFinite else { return false }
        if brightness < 0 {
            restoreBrightness()
        } else {
            if originalBrightness == nil { originalBrightness = readBrightness() }
            writeBrightness(min(1, max(0.02, brightness)))
        }
        return true
    }

    func keepScreenOn(id: String, enabled: Bool) {
        guard self.id == id else { return }
        setAwake("reader:\(id)", enabled)
    }

    func suspend(id: String) {
        guard self.id == id else { return }
        restoreBrightness()
        setAwake("reader:\(id)", false)
    }

    func stop(id: String) {
        guard self.id == id else { return }
        suspend(id: id)
        self.id = nil
    }

    private func restoreBrightness() {
        if let original = originalBrightness {
            originalBrightness = nil
            writeBrightness(original)
        }
    }
}
