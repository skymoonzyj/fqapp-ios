import AVFoundation
import Flutter
import UIKit

@MainActor
final class SystemTtsPlugin: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler, AVSpeechSynthesizerDelegate {
    // A delegate may arrive on an arbitrary queue. Transfer only stable object
    // identity to MainActor, retaining the object until delivery prevents address
    // reuse. No AVSpeechUtterance state crosses queues or is mutated here.
    private final class UtteranceIdentity: @unchecked Sendable {
        private let retained: AVSpeechUtterance
        let value: ObjectIdentifier
        init(_ utterance: AVSpeechUtterance) { retained = utterance; value = ObjectIdentifier(utterance) }
    }
    private let synthesizer = AVSpeechSynthesizer()
    private var sink: FlutterEventSink?
    private var observers: [NSObjectProtocol] = []
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var initialized = false
    private var active: (utterance: AVSpeechUtterance, token: UUID, owner: String)?
    private lazy var session = SpeechSession { [weak self] event in self?.sink?(event) }

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = SystemTtsPlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/system_tts", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "fqapp/system_tts_events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue { self?.stop() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.stop() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("fqapp.audioSessionOwnerChanged"), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let active = self.active else { return }
                if note.userInfo?["ownerID"] as? String != active.owner { self.stop() }
            }
        })
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "engines":
            let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
                if $0.language.hasPrefix("zh") != $1.language.hasPrefix("zh") { return $0.language.hasPrefix("zh") }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let fallback = defaultVoice()
            result(["engines": voices.map { ["package": "ios:\($0.identifier)", "label": "\($0.name) · \($0.language)"] },
                    "defaultEngine": fallback.map { "ios:\($0.identifier)" } as Any? ?? NSNull()])
        case "initialize":
            stop()
            initialized = false
            let requested = args["engine"] as? String
            voice = requested.flatMap { $0.hasPrefix("ios:") ? AVSpeechSynthesisVoice(identifier: String($0.dropFirst(4))) : nil } ?? defaultVoice()
            guard voice != nil else { result(error("VOICE_UNAVAILABLE", "系统中文语音不可用，请在系统设置中下载语音")); return }
            let multiplier = args["rate"] as? Double ?? 1
            guard multiplier.isFinite else { result(error("INVALID_ARGUMENT", "朗读语速无效")); return }
            rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(min(2, max(0.5, multiplier)))))
            initialized = true
            result(300)
        case "speak":
            guard initialized, let text = args["text"] as? String, !text.isEmpty, text.utf16.count <= 300,
                  let id = args["id"] as? String, !id.isEmpty else { result(error("INVALID_ARGUMENT", "朗读内容或会话无效")); return }
            stop()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = rate
            let token = session.begin(id: id, text: text)
            let owner = "speech:\(UUID().uuidString)"
            active = (utterance, token, owner)
            do {
                try AudioSessionCoordinator.shared.claim(ownerID: owner, kind: .speech)
                synthesizer.speak(utterance)
                result(nil)
            } catch {
                active = nil
                session.failed(token: token)
                AudioSessionCoordinator.shared.release(ownerID: owner)
                result(self.error("AUDIO_SESSION_FAILED", "无法启动系统朗读音频会话"))
            }
        case "stop": stop(); result(nil)
        case "shutdown": stop(); initialized = false; voice = nil; result(nil)
        case "settings":
            guard let url = URL(string: UIApplication.openSettingsURLString) else { result(error("SETTINGS_UNAVAILABLE", "请手动打开系统设置")); return }
            UIApplication.shared.open(url, options: [:]) { opened in
                result(opened ? nil : self.error("SETTINGS_UNAVAILABLE", "请手动打开系统设置"))
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func defaultVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "zh-CN") ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("zh") }
    }
    private func error(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
    private func stop() {
        let owner = active?.owner
        active = nil
        session.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        if let owner { AudioSessionCoordinator.shared.release(ownerID: owner) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { self.started(identity) }
    }
    private func started(_ identity: UtteranceIdentity) {
        guard let active, ObjectIdentifier(active.utterance) == identity.value else { return }
        session.started(token: active.token)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { self.range(characterRange, identity: identity) }
    }
    private func range(_ characterRange: NSRange, identity: UtteranceIdentity) {
        guard let active, ObjectIdentifier(active.utterance) == identity.value else { return }
        session.range(token: active.token, range: characterRange)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { self.finished(identity) }
    }
    private func finished(_ identity: UtteranceIdentity) {
        guard let active, ObjectIdentifier(active.utterance) == identity.value else { return }
        self.active = nil
        session.finished(token: active.token)
        AudioSessionCoordinator.shared.release(ownerID: active.owner)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = UtteranceIdentity(utterance)
        DispatchQueue.main.async { self.cancelled(identity) }
    }
    private func cancelled(_ identity: UtteranceIdentity) {
        guard let active, ObjectIdentifier(active.utterance) == identity.value else { return }
        self.active = nil
        session.cancel()
        AudioSessionCoordinator.shared.release(ownerID: active.owner)
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        synthesizer.delegate = nil
        sink = nil
    }
}
