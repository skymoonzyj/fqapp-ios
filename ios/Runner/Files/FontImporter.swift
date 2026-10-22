import Foundation
import CryptoKit
#if canImport(UIKit)
import UniformTypeIdentifiers
#endif

final class FontImporter {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func importFile(_ source: URL) throws -> [String: String] {
        let bytes = try DocumentFiles.read(source, maxBytes: DocumentFiles.bookLimit)
        guard bytes.count >= 12, [[UInt8]([0,1,0,0]), Array("OTTO".utf8), Array("ttcf".utf8), Array("true".utf8)].contains(Array(bytes.prefix(4))) else { throw DocumentError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(digest + ".font")
        if !FileManager.default.fileExists(atPath: target.path) { try bytes.write(to: target, options: .atomic) }
        return ["path": target.path, "name": String(source.lastPathComponent.prefix(120))]
    }
    #if canImport(UIKit)
    /// Called by ReaderPlugin's existing fqapp/reader pickFont method.
    static func pick(completion: @escaping (Result<[String: String]?, DocumentError>) -> Void) {
        DocumentCoordinator.shared.present(request: .importDocument(allowedTypes: [.font, .data], maxBytes: DocumentFiles.bookLimit)) { result in
            switch result {
            case .failure(.cancelled): completion(.success(nil))
            case .failure(let error): completion(.failure(error))
            case .success(let selection):
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { DocumentFiles.removeTemporarySelection(selection.url) }
                    let imported: Result<[String: String]?, DocumentError>
                    do { imported = .success(try FontImporter(directory: DocumentFiles.directory("reader-fonts")).importFile(selection.url)) }
                    catch { imported = .failure(.invalid) }
                    DispatchQueue.main.async { completion(imported) }
                }
            }
        }
    }
    #endif
}
