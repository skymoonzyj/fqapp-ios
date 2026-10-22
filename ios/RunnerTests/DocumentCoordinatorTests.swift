import XCTest
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
@testable import Runner
#endif

final class DocumentCoordinatorTests: XCTestCase {
    #if canImport(UIKit)
    @MainActor
    func testExportPickerDisappearanceBeforeSelectionStillCompletesSuccessOnce() throws {
        let harness = DocumentPickerHarness()
        defer { harness.close() }
        let source = try harness.file("export.json", bytes: Data([123, 125]))
        let (picker, delegate) = try harness.begin(.exportDocument(file: source, name: "export.json"))
        picker.viewDidDisappear(false)
        XCTAssertTrue(harness.results.isEmpty, "Picker disappearance is not semantic cancellation")
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        delegate.documentPickerWasCancelled?(picker)
        XCTAssertEqual(harness.results.count, 1)
        XCTAssertEqual(try harness.results.first?.get().url, source)
    }

    @MainActor
    func testImportPickerDisappearanceBeforeSelectionStillCopiesSelectedFile() throws {
        let harness = DocumentPickerHarness()
        defer { harness.close() }
        let bytes = Data("Self authored Files selection 😀".utf8)
        let source = try harness.file("book.txt", bytes: bytes)
        let completed = expectation(description: "selected file copied")
        let (picker, delegate) = try harness.begin(.importDocument(allowedTypes: [.plainText], maxBytes: 1024)) { completed.fulfill() }
        picker.viewDidDisappear(false)
        XCTAssertTrue(harness.results.isEmpty)
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(harness.results.count, 1)
        let selected = try XCTUnwrap(harness.results.first).get().url
        defer { DocumentFiles.removeTemporarySelection(selected) }
        XCTAssertNotEqual(selected, source)
        XCTAssertEqual(try Data(contentsOf: selected), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    func testAcceptedImportIgnoresPickerDismissalAndDuplicateSelection() throws {
        let harness = DocumentPickerHarness()
        defer { harness.close() }
        let source = try harness.file("book.txt", bytes: Data("A selected book".utf8))
        let completed = expectation(description: "accepted copy completes once")
        let (picker, delegate) = try harness.begin(.importDocument(allowedTypes: [.plainText], maxBytes: 1024)) { completed.fulfill() }
        // Copy completes on the main queue later; these callbacks arrive while processing.
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        let adaptive = try XCTUnwrap(delegate as? UIAdaptivePresentationControllerDelegate)
        adaptive.presentationControllerDidDismiss?(UIPresentationController(presentedViewController: picker, presenting: harness.host))
        delegate.documentPickerWasCancelled?(picker)
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        XCTAssertTrue(harness.results.isEmpty, "Ordinary dismissal cannot replace the accepted copy result")
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(harness.results.count, 1)
        let selected = try XCTUnwrap(harness.results.first).get().url
        defer { DocumentFiles.removeTemporarySelection(selected) }
        XCTAssertEqual(try Data(contentsOf: selected), Data("A selected book".utf8))
    }

    @MainActor
    func testExplicitHostTeardownCancelsAcceptedCopyAndLateDelegateCannotFinishNextRequest() throws {
        let harness = DocumentPickerHarness()
        defer { harness.close() }
        let source = try harness.file("book.txt", bytes: Data("A selected book".utf8))
        let (picker, delegate) = try harness.begin(.importDocument(allowedTypes: [.plainText], maxBytes: 1024))
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        harness.coordinator.cancel()
        harness.coordinator.cancel()
        XCTAssertEqual(harness.results.count, 1)
        XCTAssertThrowsError(try harness.results[0].get()) { XCTAssertEqual($0 as? DocumentError, .cancelled) }
        let (next, nextDelegate) = try harness.begin(.exportDocument(file: source, name: "book.txt"))
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        delegate.documentPickerWasCancelled?(picker)
        XCTAssertEqual(harness.results.count, 1)
        nextDelegate.documentPicker?(next, didPickDocumentsAt: [source])
        XCTAssertEqual(harness.results.count, 2)
        XCTAssertEqual(try harness.results[1].get().url, source)
    }

    @MainActor
    func testActualPickerCancelAndReentryCompleteEachRequestExactlyOnce() throws {
        let harness = DocumentPickerHarness()
        defer { harness.close() }
        let source = try harness.file("book.txt", bytes: Data([65]))
        let (picker, delegate) = try harness.begin(.importDocument(allowedTypes: [.plainText], maxBytes: 1024))
        harness.coordinator.present(request: .exportDocument(file: source, name: "book.txt")) { harness.results.append($0) }
        XCTAssertEqual(harness.results.count, 1)
        XCTAssertThrowsError(try harness.results[0].get()) { XCTAssertEqual($0 as? DocumentError, .busy) }
        delegate.documentPickerWasCancelled?(picker)
        delegate.documentPickerWasCancelled?(picker)
        delegate.documentPicker?(picker, didPickDocumentsAt: [source])
        XCTAssertEqual(harness.results.count, 2)
        XCTAssertThrowsError(try harness.results[1].get()) { XCTAssertEqual($0 as? DocumentError, .cancelled) }
    }
    #endif

    func testSelectionCancelAndLateDelegateCompleteOnlyOnce() throws {
        let session = DocumentRequestSession()
        var values: [Result<URL, DocumentError>] = []
        let first = try XCTUnwrap(session.begin { values.append($0) })
        let url = URL(fileURLWithPath: "/tmp/book.txt")
        session.finish(id: first, result: .success(url))
        session.finish(id: first, result: .failure(.cancelled))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(try values[0].get(), url)
        let second = try XCTUnwrap(session.begin { values.append($0) })
        XCTAssertNotEqual(first, second)
        session.finish(id: first, result: .failure(.cancelled))
        session.cancel()
        session.cancel()
        session.finish(id: second, result: .success(url))
        XCTAssertEqual(values.count, 2)
        XCTAssertThrowsError(try values[1].get()) { XCTAssertEqual($0 as? DocumentError, .cancelled) }
    }
    func testReentryRejectsNewRequestWithoutOverwritingFirst() throws {
        let session = DocumentRequestSession()
        var first = 0
        var second: DocumentError?
        let id = try XCTUnwrap(session.begin { _ in first += 1 })
        XCTAssertNil(session.begin { if case .failure(let error) = $0 { second = error } })
        XCTAssertEqual(second, .busy)
        session.finish(id: id, result: .failure(.cancelled))
        XCTAssertEqual(first, 1)
    }
    func testHostSessionReleaseCancelsExactlyOnce() throws {
        var count = 0
        var cancelled = false
        var session: DocumentRequestSession? = DocumentRequestSession()
        _ = session?.begin { result in
            count += 1
            if case .failure(.cancelled) = result { cancelled = true }
        }
        session = nil
        XCTAssertTrue(cancelled)
        XCTAssertEqual(count, 1)
    }
    func testBoundedCopyRejectsOversizeAndDoesNotPublishPartialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source")
        try Data(repeating: 65, count: 32 * 1024 * 1024).write(to: input)
        let output = try DocumentFiles.copy(input, maxBytes: 32 * 1024 * 1024, into: root.appendingPathComponent("accepted"))
        XCTAssertEqual(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, 32 * 1024 * 1024)
        let handle = try FileHandle(forWritingTo: input)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        let rejected = root.appendingPathComponent("rejected")
        XCTAssertThrowsError(try DocumentFiles.copy(input, maxBytes: 32 * 1024 * 1024, into: rejected))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rejected.path), [])
    }
    func testLongBookNamesRetainExtensionAndMatchingPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(Int, String, String, Data)] = [
            (236, "txt", ".txt", Data("中文😀".utf8)),
            (237, "txt", ".txt", Data("中文😀".utf8)),
            (235, "epub", ".epub", Data([0x50,0x4b,3,4])),
            (237, "EPUB", ".EPUB", Data([0x50,0x4b,3,4]))
        ]
        for (stemCount, ext, suffix, bytes) in fixtures {
            let file = root.appendingPathComponent(String(repeating: "a", count: stemCount) + "." + ext)
            try bytes.write(to: file)
            let payload = try LocalBookDocument.read(file)
            let name = try XCTUnwrap(payload["name"] as? String)
            XCTAssertEqual(name.count, 240)
            XCTAssertTrue(name.hasSuffix(suffix))
            XCTAssertEqual(payload["byteLength"] as? Int, bytes.count)
            // Mirror the existing Dart consumer's suffix classification, not the source URL.
            if name.lowercased().hasSuffix(".txt") {
                XCTAssertEqual(payload["text"] as? String, "中文😀")
                XCTAssertNil(payload["bytes"])
            } else {
                XCTAssertTrue(name.lowercased().hasSuffix(".epub"))
                XCTAssertEqual(payload["bytes"] as? Data, bytes)
                XCTAssertNil(payload["text"])
            }
        }
    }
    func testFontMagicSizeAndPrivatePersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = FontImporter(directory: root.appendingPathComponent("fonts"))
        let input = root.appendingPathComponent("字体.ttf")
        for signature: [UInt8] in [[0,1,0,0], [79,84,84,79], [116,116,99,102], [116,114,117,101]] {
            try Data(signature + [UInt8](repeating: 0, count: 8)).write(to: input)
            let value = try importer.importFile(input)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(value["path"])))
            XCTAssertEqual(value["name"], "字体.ttf")
        }
        try Data(repeating: 0, count: 12).write(to: input)
        XCTAssertThrowsError(try importer.importFile(input))
        try Data([0,1,0,0]).write(to: input)
        XCTAssertThrowsError(try importer.importFile(input))
        try (Data([0,1,0,0]) + Data(repeating: 0, count: 32 * 1024 * 1024 - 4)).write(to: input)
        XCTAssertNoThrow(try importer.importFile(input))
        let handle = try FileHandle(forWritingTo: input)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try importer.importFile(input))
    }
}

#if canImport(UIKit)
/// Replaces only UIKit presentation. Production coordinator, picker, delegates,
/// session transitions and asynchronous bounded file copy all execute unchanged.
@MainActor
private final class DocumentPickerHarness {
    let coordinator = DocumentCoordinator()
    let host = DocumentTestPresenter()
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var results: [Result<DocumentSelection, DocumentError>] = []
    init() {
        window.isHidden = false
        window.addSubview(host.view)
        coordinator.rootViewController = { [weak host] in host }
    }
    func file(_ name: String, bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name); try bytes.write(to: url); return url
    }
    func begin(_ request: DocumentRequest, completed: (() -> Void)? = nil) throws -> (UIDocumentPickerViewController, UIDocumentPickerDelegate) {
        coordinator.present(request: request) { [weak self] result in self?.results.append(result); completed?() }
        let picker = try XCTUnwrap(host.picker)
        return (picker, try XCTUnwrap(picker.delegate))
    }
    func close() {
        coordinator.cancel(); host.view.removeFromSuperview(); window.isHidden = true
        try? FileManager.default.removeItem(at: directory)
    }
}
@MainActor
private final class DocumentTestPresenter: UIViewController {
    var picker: UIDocumentPickerViewController?
    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        picker = controller as? UIDocumentPickerViewController
        // The tests supply the documented UIKit callbacks in the observed order.
    }
}
#endif
