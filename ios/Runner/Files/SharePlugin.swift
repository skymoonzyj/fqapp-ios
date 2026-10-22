#if canImport(Flutter)
import Flutter
import UIKit

final class SharePlugin: NSObject, FlutterPlugin, UIAdaptivePresentationControllerDelegate {
    private var reply: FlutterResult?
    private weak var activity: UIActivityViewController?
    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = SharePlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/share", binaryMessenger: registrar.messenger()))
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "shareText" else { result(FlutterMethodNotImplemented); return }
        guard reply == nil, let host = DocumentCoordinator.availablePresenter(DocumentCoordinator.shared.rootViewController()),
              let args = call.arguments as? [String: Any], let text = args["text"] as? String, !text.isEmpty else { result(false); return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.setValue(args["title"] as? String ?? "", forKey: "subject")
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = host.view; popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        reply = result; activity = sheet
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in self?.finish(completed && error == nil) }
        host.present(sheet, animated: true) { [weak self, weak sheet] in
            if sheet?.presentingViewController == nil { self?.finish(false) }
        }
        sheet.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(false) }
    private func finish(_ completed: Bool) { let callback = reply; reply = nil; activity = nil; callback?(completed) }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) { activity?.dismiss(animated: false); finish(false) }
    deinit { reply?(false) }
}
#endif
