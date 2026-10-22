import XCTest
#if canImport(UIKit)
@testable import Runner
#endif

final class LibraryBackupTests: XCTestCase {
    func testCaptureStoreRoundtripAndTraversalRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        XCTAssertNil(try store.latest())
        let name = try store.store(Data("分卷😀".utf8), part: true)
        XCTAssertEqual(try store.readPart(name), Data("分卷😀".utf8))
        _ = try store.store(Data("manifest".utf8), part: false)
        XCTAssertEqual(try store.latest(), Data("manifest".utf8))
        for invalid in ["../part-1-a.json", "part-1-a.json/..", "/part-1-a.json", "capture-1-a.json", "part-1-z.json"] {
            XCTAssertThrowsError(try store.readPart(invalid))
        }
        let link = root.appendingPathComponent("part-1-a.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try store.readPart("part-1-a.json"))
        XCTAssertThrowsError(try store.store(Data(), part: true))
        let limit = Data(repeating: 65, count: 16 * 1024 * 1024)
        let largest = try store.store(limit, part: true)
        XCTAssertEqual(try store.readPart(largest).count, limit.count)
        XCTAssertThrowsError(try store.store(limit + Data([0]), part: true))
    }
    func testZipContentsWithIndependentSystemReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let part = root.appendingPathComponent("part-1-ab.json")
        // More than two 64 KiB blocks; verifies the streamed entry boundary.
        let payload = Data(String(repeating: "中文😀", count: 15000).utf8)
        try payload.write(to: part)
        let destination = root.appendingPathComponent("capture.zip")
        let manifest = Data("{\"version\":1}".utf8)
        let written = try CaptureZipWriter.write(manifest: manifest, parts: [part], destination: destination)
        XCTAssertEqual(written, destination)
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-t", destination.path]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, String(decoding: output, as: UTF8.self))
        let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extract.arguments = ["-qq", destination.path, "-d", root.appendingPathComponent("unzip").path]
        try extract.run(); extract.waitUntilExit(); XCTAssertEqual(extract.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unzip/manifest.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unzip/part-1-ab.json")), payload)
        #else
        // Independent stored-ZIP reader: parse local records, then check central/end signatures.
        let archive = try Data(contentsOf: destination)
        var cursor = 0
        var entries: [String: Data] = [:]
        func number(_ at: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(archive[at + $1]) << (8 * $1) }
        }
        while number(cursor, 4) == 0x04034b50 {
            XCTAssertEqual(number(cursor + 8, 2), 0)
            let size = number(cursor + 18, 4), nameLength = number(cursor + 26, 2), extra = number(cursor + 28, 2)
            let start = cursor + 30 + nameLength + extra
            let name = String(decoding: archive[(cursor + 30)..<(cursor + 30 + nameLength)], as: UTF8.self)
            entries[name] = archive.subdata(in: start..<(start + size)); cursor = start + size
        }
        XCTAssertEqual(number(cursor, 4), 0x02014b50)
        XCTAssertEqual(number(archive.count - 22, 4), 0x06054b50)
        XCTAssertEqual(entries, ["manifest.json": manifest, "part-1-ab.json": payload])
        #endif
    }
    #if os(macOS)
    func testZip64OffsetWithSparseArchiveAndIndependentReader() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
        try output.seek(toOffset: UInt64(UInt32.max) + 1024)
        let entry = try CaptureZipWriter.writeLocal(name: "manifest.json", size: 3, crc: 0x352441c2, output: output)
        try output.write(contentsOf: Data("abc".utf8))
        try CaptureZipWriter.finish(entries: [entry], output: output)
        try output.close()
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-t", file.path]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        try task.run(); let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        let end = try input.seekToEnd(); try input.seek(toOffset: end - 98)
        let tail = try XCTUnwrap(input.read(upToCount: 98))
        XCTAssertEqual(Array(tail.prefix(4)), [0x50,0x4b,0x06,0x06])
    }
    #endif
    func testZipRejectsDuplicateUnsafeEmptyOversizedAndTooManyParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let part = root.appendingPathComponent("part-1-ab.json")
        let output = root.appendingPathComponent("capture.zip")
        try Data([1]).write(to: part)
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data([1]), parts: [part, part], destination: output))
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data(), parts: [part], destination: output))
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data([1]), parts: Array(repeating: part, count: 2001), destination: output))
        let unsafe = root.appendingPathComponent("other.json"); try Data([1]).write(to: unsafe)
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data([1]), parts: [unsafe], destination: output))
        try Data().write(to: part)
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data([1]), parts: [part], destination: output))
        let handle = try FileHandle(forWritingTo: part); try handle.truncate(atOffset: 16 * 1024 * 1024 + 1); try handle.close()
        XCTAssertThrowsError(try CaptureZipWriter.write(manifest: Data([1]), parts: [part], destination: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
