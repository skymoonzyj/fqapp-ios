#if canImport(Flutter)
import Flutter
import Foundation

final class TextExportPlugin: NSObject, FlutterPlugin {
    private let replies = FilePluginReplies()
    private let io = DispatchQueue(label: "fqapp.text-export.io", qos: .userInitiated)
    private var busy = false
    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = TextExportPlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/downloads", binaryMessenger: registrar.messenger()))
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "saveText" else { result(FlutterMethodNotImplemented); return }
        guard !busy else { result(filePluginError(.busy)); return }
        guard let args = call.arguments as? [String: Any], let name = args["fileName"] as? String,
              let text = args["text"] as? String, !name.isEmpty, name.count <= 240,
              name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            result(filePluginError(.invalid)); return
        }
        busy = true
        let id = replies.begin(result)
        io.async { [weak self] in
            var temporary: URL?
            do {
                let directory = try DocumentFiles.temporaryDirectory(); temporary = directory
                let file = directory.appendingPathComponent(name)
                try Data(text.utf8).write(to: file, options: .atomic)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.replies.isActive(id) else { try? FileManager.default.removeItem(at: directory); return }
                    DocumentCoordinator.shared.present(request: .exportDocument(file: file, name: name)) { [weak self] selected in
                        try? FileManager.default.removeItem(at: directory)
                        guard let self else { return }; self.busy = false
                        switch selected {
                        case .success(let selection): self.replies.finish(id, ["path": selection.url.path, "public": true, "destinationLabel": "文件"])
                        case .failure(.cancelled): self.replies.finish(id, ["cancelled": true])
                        case .failure(let error): self.replies.finish(id, filePluginError(error))
                        }
                    }
                }
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                DispatchQueue.main.async { self?.busy = false; self?.replies.finish(id, filePluginError(.io)) }
            }
        }
    }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) { DocumentCoordinator.shared.cancel(); replies.close(); busy = false }
}
#endif
