import Foundation

/// The native document payload before Flutter converts binary Data to Uint8List.
enum LocalBookDocument {
    static func read(_ file: URL) throws -> [String: Any] {
        let bytes = try DocumentFiles.read(file, maxBytes: DocumentFiles.bookLimit)
        let suffix = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        let stem = suffix.isEmpty ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
        let name = String(stem.prefix(max(0, 240 - suffix.count))) + suffix
        if file.pathExtension.lowercased() == "txt" {
            return ["name": name, "byteLength": bytes.count, "text": try TextDecoder.decode(bytes)]
        }
        return ["name": name, "byteLength": bytes.count, "bytes": bytes]
    }
}

#if canImport(Flutter)
import Flutter
import Foundation
import UniformTypeIdentifiers

/// All replies are owned on main. Engine detach completes outstanding calls once.
final class FilePluginReplies {
    private var callbacks: [UUID: FlutterResult] = [:]
    func begin(_ result: @escaping FlutterResult) -> UUID { let id = UUID(); callbacks[id] = result; return id }
    func isActive(_ id: UUID) -> Bool { callbacks[id] != nil }
    func finish(_ id: UUID, _ value: Any?) { let reply = callbacks.removeValue(forKey: id); reply?(value) }
    func close() {
        let replies = callbacks.values; callbacks.removeAll()
        for reply in replies { reply(FlutterError(code: "FILE_INTERRUPTED", message: "文件操作已中断，请重新操作", details: nil)) }
    }
    deinit { close() }
}
func filePluginError(_ error: DocumentError) -> FlutterError {
    FlutterError(code: error == .busy ? "FILE_BUSY" : "FILE_IO_FAILED", message: error == .busy ? "请先关闭已打开的系统面板" : "文件操作失败，请重新选择文件", details: nil)
}

final class LocalBookPlugin: NSObject, FlutterPlugin {
    private let replies = FilePluginReplies()
    private let io = DispatchQueue(label: "fqapp.local-books.io", qos: .userInitiated)
    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = LocalBookPlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/local_books", binaryMessenger: registrar.messenger()))
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "pickBookFile" else { result(FlutterMethodNotImplemented); return }
        let id = replies.begin(result)
        DocumentCoordinator.shared.present(request: .importDocument(allowedTypes: [.plainText, UTType(filenameExtension: "epub") ?? .data, .data], maxBytes: DocumentFiles.bookLimit)) { [weak self] selection in
            guard let self else { return }
            switch selection {
            case .failure(.cancelled): self.replies.finish(id, nil)
            case .failure(let error): self.replies.finish(id, filePluginError(error))
            case .success(let selection):
                self.io.async { [weak self] in
                    defer { DocumentFiles.removeTemporarySelection(selection.url) }
                    let response: Any
                    do {
                        var document = try LocalBookDocument.read(selection.url)
                        if let bytes = document["bytes"] as? Data {
                            document["bytes"] = FlutterStandardTypedData(bytes: bytes)
                        }
                        response = document
                    } catch { response = filePluginError(.invalid) }
                    DispatchQueue.main.async { self?.replies.finish(id, response) }
                }
            }
        }
    }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) { DocumentCoordinator.shared.cancel(); replies.close() }
}
#endif
