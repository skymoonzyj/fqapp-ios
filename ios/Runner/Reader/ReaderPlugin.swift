import Flutter
import UIKit

/// Engineering installs this Flutter host so reader bars use public UIKit
/// appearance APIs while Flutter continues to own safe-area layout.
class ReaderHostViewController: FlutterViewController {
    var readerImmersive = false {
        didSet {
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }
    override var prefersStatusBarHidden: Bool { readerImmersive || super.prefersStatusBarHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { readerImmersive || super.prefersHomeIndicatorAutoHidden }
}

final class ReaderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var fontResult: FlutterResult?
    private let previousBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
    private lazy var session = ReaderSession(
        readBrightness: { Double(UIScreen.main.brightness) },
        writeBrightness: { UIScreen.main.brightness = CGFloat($0) },
        setAwake: { AwakeCoordinator.shared.set(ownerID: $0, enabled: $1) }
    )

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = ReaderPlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/reader", binaryMessenger: registrar.messenger()))
        FlutterEventChannel(name: "fqapp/reader/events", binaryMessenger: registrar.messenger()).setStreamHandler(plugin)
    }

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     UIScreen.brightnessDidChangeNotification, UIApplication.significantTimeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.publish() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let id = self.session.id else { return }
            self.session.suspend(id: id)
            self.setImmersive(false)
        })
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "pickFont" {
            guard fontResult == nil else { result(FlutterError(code: "FONT_PICKER_BUSY", message: "字体选择器正在使用", details: nil)); return }
            fontResult = result
            FontImporter.pick { [weak self] outcome in
                guard let self, let completion = self.fontResult else { return }
                self.fontResult = nil
                switch outcome {
                case .success(let value): completion(value)
                case .failure(let error):
                    completion(FlutterError(code: error == .busy ? "FONT_PICKER_BUSY" : "FONT_IMPORT_FAILED", message: "无法导入所选字体，请重试", details: nil))
                }
            }
            return
        }
        guard let id = args["session"] as? String, !id.isEmpty else {
            result(FlutterError(code: "INVALID_READER_SESSION", message: "阅读会话不可用", details: nil)); return
        }
        switch call.method {
        case "start":
            guard let brightness = args["brightness"] as? Double, brightness.isFinite else { invalid(result); return }
            if session.id != id { setImmersive(false) }
            session.start(id: id, brightness: brightness)
            result(status())
        case "setBrightness":
            guard let brightness = args["brightness"] as? Double else { invalid(result); return }
            result(session.setBrightness(id: id, brightness: brightness))
        case "keepScreenOn": session.keepScreenOn(id: id, enabled: args["on"] as? Bool == true); result(nil)
        case "suspend", "stop":
            if session.id == id { setImmersive(false) }
            if call.method == "stop" { session.stop(id: id) } else { session.suspend(id: id) }
            result(nil)
        case "setImmersive":
            guard session.id == id else { result(nil); return }
            guard setImmersive(args["enabled"] as? Bool == true) else {
                result(FlutterError(code: "READER_HOST_UNAVAILABLE", message: "阅读全屏暂不可用", details: nil)); return
            }
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func invalid(_ result: FlutterResult) { result(FlutterError(code: "INVALID_ARGUMENT", message: "阅读参数无效", details: nil)) }
    private func status() -> [String: Any] {
        let device = UIDevice.current
        let level = device.batteryLevel
        return ["session": session.id ?? "", "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "battery": level < 0 ? NSNull() : NSNumber(value: Int((level * 100).rounded())),
                "charging": device.batteryState == .charging || device.batteryState == .full,
                "systemBrightness": Double(UIScreen.main.brightness)]
    }
    private func publish() { if session.id != nil { sink?(status()) } }
    @discardableResult
    private func setImmersive(_ enabled: Bool) -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let host = windows.first(where: \.isKeyWindow)?.rootViewController as? ReaderHostViewController else { return false }
        host.readerImmersive = enabled
        return true
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.publish() }
        publish()
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; timer?.invalidate(); timer = nil; return nil }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        if let id = session.id { session.stop(id: id) }
        setImmersive(false)
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
        if let completion = fontResult { fontResult = nil; DocumentCoordinator.shared.cancel(); completion(nil) }
        sink = nil
    }
}
