import Foundation

/// A memory warning requests only reconstructible image eviction. It is never
/// a promise of an impending termination callback or a trigger to erase disk.
final class MemoryPressureRelay {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private let notify: (String) -> Void
    private var active = true

    init(center: NotificationCenter, warningName: Notification.Name, notify: @escaping (String) -> Void) {
        self.center = center
        self.notify = notify
        token = center.addObserver(forName: warningName, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.active else { return }
            self.notify("trim")
        }
    }

    func close() {
        active = false
        if let token { center.removeObserver(token) }
        token = nil
    }
    deinit { close() }
}

#if canImport(UIKit) && canImport(Flutter)
import UIKit
import Flutter

final class MemoryPressurePlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private let io = DispatchQueue(label: "fqapp.storage-protection", qos: .utility)
    private var relay: MemoryPressureRelay?
    private var active = true
    private var pending: [UUID: FlutterResult] = [:]

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "fqapp/fair_memory", binaryMessenger: registrar.messenger())
        let plugin = MemoryPressurePlugin(channel: channel)
        registrar.addMethodCallDelegate(plugin, channel: channel)
        registrar.publish(plugin)
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        relay = MemoryPressureRelay(center: .default, warningName: UIApplication.didReceiveMemoryWarningNotification) { [weak self] kind in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.channel.invokeMethod("onMemoryWarning", arguments: ["kind": kind])
            }
        }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard active else {
            result(FlutterError(code: "engine_detached", message: "引擎已关闭", details: nil)); return
        }
        let boxName: String?
        switch call.method {
        case "configureStorage":
            guard call.arguments == nil || call.arguments is NSNull else {
                result(FlutterError(code: "invalid_arguments", message: "不接受外部存储路径", details: nil)); return
            }
            boxName = nil
        case "configureBox":
            guard let args = call.arguments as? [String: String], args.count == 1,
                  let name = args["name"], ["history", "read_time", "watched_episodes", "audio_download_v1", "drama_download_v1", "chapter_cache_v1"].contains(name) else {
                result(FlutterError(code: "invalid_arguments", message: "不支持的本机存储类型", details: nil)); return
            }
            boxName = name
        default: result(FlutterMethodNotImplemented); return
        }
        let id = UUID()
        pending[id] = result
        io.async { [weak self] in
            let response: Any
            do {
                try StorageProtectionPolicy.application().apply(boxName: boxName)
                response = true
            } catch {
                // Never include filesystem paths or key material in diagnostics.
                response = FlutterError(code: "storage_unavailable", message: "无法配置本机存储保护，请解锁后重试", details: nil)
            }
            DispatchQueue.main.async { [weak self] in
                self?.pending.removeValue(forKey: id)?(response)
            }
        }
    }

    func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        active = false
        relay?.close()
        relay = nil
        let replies = pending.values
        pending.removeAll()
        for reply in replies { reply(FlutterError(code: "engine_detached", message: "引擎已关闭", details: nil)) }
    }
}
#endif
