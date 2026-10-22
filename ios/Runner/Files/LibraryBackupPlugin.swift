import Foundation

final class CaptureStore {
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }
    static func validPartName(_ name: String) -> Bool { name.range(of: #"\Apart-[0-9]+-[a-fA-F0-9-]+\.json\z"#, options: .regularExpression) != nil }
    private static func validCaptureName(_ name: String) -> Bool { name.range(of: #"\Acapture-[0-9]+-[a-fA-F0-9-]+\.json\z"#, options: .regularExpression) != nil }
    func store(_ bytes: Data, part: Bool) throws -> String {
        guard !bytes.isEmpty, bytes.count <= DocumentFiles.backupLimit else { throw DocumentError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(part ? "part" : "capture")-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .atomic)
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(name))
        return name
    }
    func partURL(_ name: String) throws -> URL {
        guard Self.validPartName(name) else { throw DocumentError.invalid }
        let file = directory.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath() == file, file.deletingLastPathComponent().path == directory.path else { throw DocumentError.invalid }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let count = values.fileSize, count > 0, count <= DocumentFiles.backupLimit else { throw DocumentError.invalid }
        return file
    }
    func readPart(_ name: String) throws -> Data { try DocumentFiles.read(partURL(name), maxBytes: DocumentFiles.backupLimit) }
    func latest() throws -> Data? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(Self.validCaptureName).sorted()
        guard let name = names.last else { return nil }
        let file = directory.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath() == file else { throw DocumentError.invalid }
        let bytes = try DocumentFiles.read(file, maxBytes: DocumentFiles.backupLimit)
        guard !bytes.isEmpty else { throw DocumentError.invalid }; return bytes
    }
}

#if canImport(Flutter)
import Flutter
import UniformTypeIdentifiers

final class LibraryBackupPlugin: NSObject, FlutterPlugin {
    private let replies = FilePluginReplies()
    private let io = DispatchQueue(label: "fqapp.library-backup.io", qos: .userInitiated)
    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = LibraryBackupPlugin()
        registrar.publish(plugin)
        registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(name: "fqapp/library_backup", binaryMessenger: registrar.messenger()))
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let methods = ["saveBackup", "openBackup", "storeFanqieCapture", "storeFanqieCapturePart", "latestFanqieCapture", "readFanqieCapturePart", "exportFanqieCapture"]
        guard methods.contains(call.method) else { result(FlutterMethodNotImplemented); return }
        let id = replies.begin(result)
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "openBackup" {
            DocumentCoordinator.shared.present(request: .importDocument(allowedTypes: [.json, .plainText, .data], maxBytes: DocumentFiles.backupLimit)) { [weak self] selected in
                guard let self else { return }
                switch selected {
                case .failure(.cancelled): self.replies.finish(id, nil)
                case .failure(let error): self.replies.finish(id, filePluginError(error))
                case .success(let selection):
                    self.io.async { [weak self] in
                        defer { DocumentFiles.removeTemporarySelection(selection.url) }
                        let response: Any
                        do { response = FlutterStandardTypedData(bytes: try DocumentFiles.read(selection.url, maxBytes: DocumentFiles.backupLimit)) }
                        catch { response = filePluginError(.io) }
                        DispatchQueue.main.async { self?.replies.finish(id, response) }
                    }
                }
            }
            return
        }
        io.async { [weak self] in
            guard let self else { return }
            var temporary: URL?
            do {
                let store = CaptureStore(directory: try DocumentFiles.directory("fanqie-library-captures"))
                let response: Any?
                switch call.method {
                case "storeFanqieCapture", "storeFanqieCapturePart":
                    let data = try Self.bytes(args)
                    let name = try store.store(data, part: call.method == "storeFanqieCapturePart")
                    response = call.method == "storeFanqieCapturePart" ? name : true
                case "latestFanqieCapture": response = try store.latest().map { FlutterStandardTypedData(bytes: $0) }
                case "readFanqieCapturePart":
                    guard let name = args["name"] as? String else { throw DocumentError.invalid }
                    response = FlutterStandardTypedData(bytes: try store.readPart(name))
                default:
                    let data = try Self.bytes(args)
                    let exporting = call.method == "exportFanqieCapture"
                    let fallback = exporting ? "fqapp-fanqie-capture.zip" : "fqapp-backup.json"
                    let supplied = args["name"] as? String ?? fallback
                    let pattern = exporting ? #"\A[a-zA-Z0-9_.-]{1,100}\.zip\z"# : #"\A[a-zA-Z0-9_.-]{1,100}\.json\z"#
                    let name = supplied.range(of: pattern, options: .regularExpression) == nil ? fallback : supplied
                    let directory = try DocumentFiles.temporaryDirectory(); temporary = directory
                    let file = directory.appendingPathComponent(name)
                    if exporting {
                        guard let names = args["parts"] as? [String], names.count <= 2000, Set(names).count == names.count else { throw DocumentError.invalid }
                        let parts = try names.map { try store.partURL($0) }
                        _ = try CaptureZipWriter.write(manifest: data, parts: parts, destination: file)
                    } else { try data.write(to: file, options: .atomic) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.replies.isActive(id) else { try? FileManager.default.removeItem(at: directory); return }
                        DocumentCoordinator.shared.present(request: .exportDocument(file: file, name: name)) { [weak self] result in
                            try? FileManager.default.removeItem(at: directory)
                            switch result {
                            case .success: self?.replies.finish(id, true)
                            case .failure(.cancelled): self?.replies.finish(id, false)
                            case .failure(let error): self?.replies.finish(id, filePluginError(error))
                            }
                        }
                    }
                    return
                }
                DispatchQueue.main.async { self.replies.finish(id, response) }
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                DispatchQueue.main.async { self.replies.finish(id, filePluginError(.io)) }
            }
        }
    }
    private static func bytes(_ args: [String: Any]) throws -> Data {
        guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data, !bytes.isEmpty, bytes.count <= DocumentFiles.backupLimit else { throw DocumentError.invalid }
        return bytes
    }
    func detachFromEngine(for registrar: FlutterPluginRegistrar) { DocumentCoordinator.shared.cancel(); replies.close() }
}
#endif
