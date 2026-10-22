import Flutter
import UIKit

final class FanqieAccountPlugin: NSObject, FlutterPlugin {
    private weak var root: UIViewController?
    private weak var registrar: FlutterPluginRegistrar?
    private let store: AccountCookieStore
    private let session: AccountLoginSession
    private var loginController: FanqieLoginController?
    private var navigation: UINavigationController?
    private var presenting = false
    private var closeAfterPresentation: (() -> Void)?

    init(root: UIViewController?) {
        precondition(Thread.isMainThread)
        self.root = root
        let store = AccountCookieStore()
        self.store = store
        session = AccountLoginSession(store: store)
        super.init()
        session.closeWindow = { [weak self] _, done in
            guard let self else { done(); return }
            self.close(done)
        }
        session.invalidCookie = { [weak self] in self?.loginController?.invalidSession() }
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        precondition(Thread.isMainThread)
        let channel = FlutterMethodChannel(name: "fqapp/fanqie_account", binaryMessenger: registrar.messenger())
        let plugin = FanqieAccountPlugin(root: registrar.viewController)
        plugin.registrar = registrar
        registrar.addMethodCallDelegate(plugin, channel: channel)
        // Flutter only delivers engine-detach cleanup to published plugins.
        registrar.publish(plugin)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        accountOnMain { [self] in
            switch call.method {
            case "login":
                self.login(call.arguments as? [String: Any] ?? [:], result: result)
            case "cancelLogin":
                self.session.cancel()
                result(nil)
            case "clearSession":
                if !self.session.clear({ result(nil) }) { result(self.busyError()) }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        accountOnMain { [self] in session.cancel() }
    }

    private func busyError() -> FlutterError { FlutterError(code: "LOGIN_BUSY", message: "登录窗口正在处理", details: nil) }

    private func login(_ arguments: [String: Any], result: @escaping FlutterResult) {
        guard !session.busy else { result(busyError()); return }
        guard let root = registrar?.viewController ?? root, root.viewIfLoaded?.window != nil else {
            result(FlutterError(code: "NO_ACTIVITY", message: "应用窗口不可用", details: nil)); return
        }
        guard root.presentedViewController == nil, !root.isBeingPresented, !root.isBeingDismissed, root.transitionCoordinator == nil else {
            result(busyError()); return
        }
        guard let id = session.begin({ result($0) }) else { result(busyError()); return }
        let controller = FanqieLoginController(dataStore: store.dataStore, dark: arguments["dark"] as? Bool, eink: arguments["eink"] as? Bool == true)
        controller.onCancel = { [weak self] in self?.session.cancel() }
        controller.onRead = { [weak self] in self?.session.readCookies(for: id) }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = controller.overrideUserInterfaceStyle
        navigation.presentationController?.delegate = controller
        loginController = controller
        self.navigation = navigation
        presenting = true
        root.present(navigation, animated: true) { [self] in
            self.presenting = false
            let close = self.closeAfterPresentation
            self.closeAfterPresentation = nil
            close?()
        }
    }

    private func close(_ done: @escaping () -> Void) {
        // Programmatic success dismissal must not masquerade as user cancel.
        // A later channel cancel/engine detach can still revoke its payload.
        loginController?.onCancel = nil
        loginController?.onRead = nil
        loginController?.stop()
        guard let navigation else { done(); return }
        let dismiss = { [weak self, weak navigation] in
            guard let self else { done(); return }
            let finished = { [weak self] in
                self?.loginController = nil
                self?.navigation = nil
                done()
            }
            guard let navigation, navigation.presentingViewController != nil else { finished(); return }
            navigation.dismiss(animated: true, completion: finished)
        }
        if presenting { closeAfterPresentation = dismiss } else { dismiss() }
    }
}
