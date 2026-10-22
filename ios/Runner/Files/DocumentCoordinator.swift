import Foundation

enum DocumentError: Error, Equatable { case cancelled, busy, invalid, io }

/// Main-queue ownership. A stale picker/worker cannot complete a later request.
final class DocumentRequestSession {
    private(set) var activeID: UUID?
    private enum Phase { case waiting, processing, completed }
    private var phase = Phase.completed
    private var completion: ((Result<URL, DocumentError>) -> Void)?
    func begin(_ completion: @escaping (Result<URL, DocumentError>) -> Void) -> UUID? {
        guard activeID == nil else { completion(.failure(.busy)); return nil }
        let id = UUID(); activeID = id; phase = .waiting; self.completion = completion; return id
    }
    func acceptSelection(id: UUID) -> Bool {
        guard activeID == id, phase == .waiting else { return false }
        phase = .processing; return true
    }
    func isWaiting(id: UUID) -> Bool { activeID == id && phase == .waiting }
    func finish(id: UUID, result: Result<URL, DocumentError>) {
        guard activeID == id else { return }
        let callback = completion; activeID = nil; phase = .completed; completion = nil
        callback?(result)
    }
    func cancel() { if let id = activeID { finish(id: id, result: .failure(.cancelled)) } }
    deinit { cancel() }
}

enum DocumentFiles {
    static let bookLimit = 32 * 1024 * 1024
    static let backupLimit = 16 * 1024 * 1024
    static func directory(_ name: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fqapp-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// Bounded streaming read, including providers whose size metadata is absent/stale.
    static func read(_ source: URL, maxBytes: Int) throws -> Data {
        guard source.isFileURL, maxBytes > 0 else { throw DocumentError.invalid }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { throw DocumentError.invalid }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        var data = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count <= maxBytes - chunk.count else { throw DocumentError.invalid }
            data.append(chunk)
        }
        return data
    }
    static func copy(_ source: URL, maxBytes: Int, into directory: URL) throws -> URL {
        guard source.isFileURL, maxBytes > 0 else { throw DocumentError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw DocumentError.io }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { throw DocumentError.invalid }
                let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
                var count = 0
                while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    guard count <= maxBytes - chunk.count else { throw DocumentError.invalid }
                    count += chunk.count; try output.write(contentsOf: chunk)
                }
                try output.synchronize()
            } catch { readError = error }
        }
        if let error = coordinationError ?? readError as NSError? { throw error }
        try output.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    static func removeTemporarySelection(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

enum DocumentRequest {
    case importDocument(allowedTypes: [UTType], maxBytes: Int)
    case exportDocument(file: URL, name: String)
}
struct DocumentSelection { let url: URL }

final class DocumentCoordinator: NSObject {
    static let shared = DocumentCoordinator()
    private let session = DocumentRequestSession()
    private var picker: UIDocumentPickerViewController?
    private var pickerDelegate: PickerDelegate?
    private let io = DispatchQueue(label: "fqapp.documents.io", qos: .userInitiated)
    // Engineering may inject its scene-specific root; never walk through an existing modal.
    var rootViewController: () -> UIViewController? = {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    }
    static func availablePresenter(_ root: UIViewController?) -> UIViewController? {
        guard let root, root.viewIfLoaded?.window != nil, root.presentedViewController == nil,
              !root.isBeingDismissed, !root.isBeingPresented, root.transitionCoordinator == nil else { return nil }
        return root
    }
    func present(request: DocumentRequest, completion: @escaping (Result<DocumentSelection, DocumentError>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard session.activeID == nil, let host = Self.availablePresenter(rootViewController()) else {
            completion(.failure(.busy)); return
        }
        let controller: UIDocumentPickerViewController
        switch request {
        case .importDocument(let types, let maxBytes):
            guard !types.isEmpty, maxBytes > 0 else { completion(.failure(.invalid)); return }
            controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        case .exportDocument(let file, let name):
            guard file.isFileURL, file.lastPathComponent == name, FileManager.default.fileExists(atPath: file.path) else {
                completion(.failure(.invalid)); return
            }
            controller = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        }
        guard let id = session.begin({ completion($0.map { DocumentSelection(url: $0) }) }) else { return }
        let delegate = PickerDelegate(owner: self, id: id, request: request)
        picker = controller; pickerDelegate = delegate; controller.delegate = delegate; controller.allowsMultipleSelection = false
        host.present(controller, animated: true) { [weak self, weak controller] in
            guard let self else { return }
            guard controller?.presentingViewController != nil else { self.finish(id, .failure(.io)); return }
        }
        controller.presentationController?.delegate = delegate
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        let old = picker; picker = nil; pickerDelegate = nil
        session.cancel(); old?.dismiss(animated: false)
    }
    private func finish(_ id: UUID, _ result: Result<URL, DocumentError>) {
        guard session.activeID == id else { return }
        picker = nil; pickerDelegate = nil; session.finish(id: id, result: result)
    }
    private func cancelledByPicker(_ id: UUID) {
        // UIKit dismissal can follow selection while its file is still copying.
        guard session.isWaiting(id: id) else { return }
        finish(id, .failure(.cancelled))
    }
    private func selected(_ urls: [URL], id: UUID, request: DocumentRequest) {
        guard session.acceptSelection(id: id) else { return }
        guard urls.count == 1, let url = urls.first else { finish(id, .failure(.invalid)); return }
        switch request {
        case .exportDocument:
            finish(id, .success(url))
        case .importDocument(_, let maximum):
            io.async { [weak self] in
                var directory: URL?
                let result: Result<URL, DocumentError>
                do {
                    let temporary = try DocumentFiles.temporaryDirectory(); directory = temporary
                    result = .success(try DocumentFiles.copy(url, maxBytes: maximum, into: temporary))
                } catch { if let directory { try? FileManager.default.removeItem(at: directory) }; result = .failure(.io) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session.activeID == id else {
                        if case .success(let file) = result { DocumentFiles.removeTemporarySelection(file) }; return
                    }
                    self.finish(id, result)
                }
            }
        }
    }
    // A picker disappearing is not a semantic cancel: UIKit can dismiss it
    // before didPickDocumentsAt. Keep the delegate alive until selection,
    // explicit picker cancellation, or host/engine cancel() completes the request.
    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        weak var owner: DocumentCoordinator?
        let id: UUID; let request: DocumentRequest
        init(owner: DocumentCoordinator, id: UUID, request: DocumentRequest) { self.owner = owner; self.id = id; self.request = request }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            owner?.selected(urls, id: id, request: request)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { owner?.cancelledByPicker(id) }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { owner?.cancelledByPicker(id) }
    }
}
#endif
