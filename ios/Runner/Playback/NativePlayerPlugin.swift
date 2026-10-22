import Flutter
import UIKit

/// Implemented by the app's PiP/audio owner without moving route ownership
/// into PlayerHost. False from release retains the native player and lease.
@MainActor
protocol NativePlayerIntegration: AnyObject {
    func willPlay(playerID: Int) throws
    func release(playerID: Int) -> Bool
    func handle(method: String, arguments: [String: Any], completion: @escaping FlutterResult) -> Bool
    func didEmit(event: [String: Any])
}

@MainActor
final class NativePlayerPlugin: NSObject, @preconcurrency FlutterPlugin, @preconcurrency FlutterStreamHandler {
    static var configure: ((NativePlayerPlugin) -> Void)?
    var integration: NativePlayerIntegration?
    private var methodChannel: FlutterMethodChannel?
    private var hosts = [Int: PlayerHost]()
    // Scope Dart page IDs to this engine, including hot restarts/replacements.
    private let awakeNamespace = "playback:\(UUID().uuidString):"
    private var awakeOwners = Set<String>()
    private var nextID = 1
    private var eventSink: FlutterEventSink?
    private var pending = [[String: Any]]()

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NativePlayerPlugin()
        let channel = FlutterMethodChannel(name: "fqapp/native_player", binaryMessenger: registrar.messenger())
        plugin.methodChannel = channel
        registrar.addMethodCallDelegate(plugin, channel: channel)
        FlutterEventChannel(name: "fqapp/native_player/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(plugin)
        registrar.register(PlayerPlatformViewFactory { [weak plugin] in plugin?.host(for: $0) },
                           withId: "fqapp/player")
        registrar.publish(plugin)
        configure?(plugin)
    }

    func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        for owner in awakeOwners { AwakeCoordinator.shared.set(ownerID: awakeNamespace + owner, enabled: false) }
        awakeOwners.removeAll()
        for id in Array(hosts.keys) { releaseRetainedPlayer(id) }
        integration = nil
        methodChannel = nil
        eventSink = nil
        pending.removeAll()
    }

    func emitRemoteAction(_ action: String, completion: FlutterResult? = nil) {
        guard let methodChannel else { completion?(false); return }
        methodChannel.invokeMethod("onNotificationAction", arguments: ["action": action], result: completion)
    }

    func emitBecomingNoisy() {
        methodChannel?.invokeMethod("onAudioBecomingNoisy", arguments: nil)
    }

    func host(for id: Int) -> PlayerHost? { hosts[id] }

    func releaseRetainedPlayer(_ id: Int) {
        hosts.removeValue(forKey: id)?.release()
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        if integration?.handle(method: call.method, arguments: args, completion: result) == true { return }
        switch call.method {
        case "create":
            // Only Rust's capability-scoped loopback source reaches AVFoundation.
            guard let source = args["cdnUrl"] as? String, let url = URL(string: source),
                  url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                  url.user == nil, url.password == nil,
                  args["keyHex"] as? String == "",
                  let mediaID = args["mediaId"] as? String, !mediaID.isEmpty,
                  let generation = args["mediaGeneration"] as? String,
                  UInt64(generation) != nil else {
                result(FlutterError(code: "invalid_source", message: "Invalid media source", details: nil))
                return
            }
            let id = nextID
            nextID += 1
            let host = PlayerHost(id: id, url: url) { [weak self] event in self?.emit(event) }
            hosts[id] = host
            host.startObserving()
            result(["playerId": id])
        case "dispose":
            guard let id = args["id"] as? Int else { result(nil); return }
            if integration?.release(playerID: id) != false { releaseRetainedPlayer(id) }
            result(nil)
        case "setKeepScreenOn":
            guard let owner = args["ownerID"] as? String, !owner.isEmpty,
                  let enabled = args["on"] as? Bool else {
                result(FlutterError(code: "invalid_awake_owner", message: "Page owner required", details: nil))
                return
            }
            if enabled {
                awakeOwners.insert(owner)
                AwakeCoordinator.shared.set(ownerID: awakeNamespace + owner, enabled: true)
            } else if awakeOwners.remove(owner) != nil {
                AwakeCoordinator.shared.set(ownerID: awakeNamespace + owner, enabled: false)
            }
            result(nil)
        case "play", "pause", "seek", "setVolume", "setRate":
            guard let id = args["id"] as? Int, let host = hosts[id] else {
                result(FlutterError(code: "missing_player", message: "Player unavailable", details: nil))
                return
            }
            switch call.method {
            case "play":
                do { try integration?.willPlay(playerID: id); host.play(); result(nil) }
                catch { result(FlutterError(code: "audio_unavailable", message: "Audio unavailable", details: nil)) }
            case "pause": host.pause(); result(nil)
            case "seek":
                host.seek(milliseconds: args["positionMs"] as? Int ?? 0) { completed in
                    result(completed ? nil : FlutterError(code: "seek_failed", message: "Seek interrupted", details: nil))
                }
            case "setVolume": host.setVolume(args["volume"] as? Double ?? 1); result(nil)
            default: host.setRate(args["rate"] as? Double ?? 1); result(nil)
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func emit(_ event: [String: Any]) {
        integration?.didEmit(event: event)
        if let sink = eventSink { sink(event) }
        else if pending.count < 64 { pending.append(event) }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        let buffered = pending
        pending.removeAll()
        buffered.forEach(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
