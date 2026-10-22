import Foundation
import zlib

/// Stored entries streamed in 64 KiB blocks. Only central-directory metadata is retained.
enum CaptureZipWriter {
    struct Entry { let name: String; let size: UInt32; let crc: UInt32; let offset: UInt64 }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    static func writeLocal(name: String, size: UInt32, crc: UInt32, output: FileHandle) throws -> Entry {
        let entry = Entry(name: name, size: size, crc: crc, offset: try output.offset())
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= Int(UInt16.max) else { throw DocumentError.invalid }
        var header = Data()
        append(UInt32(0x04034b50), to: &header)
        for value: UInt16 in [20, 0x800, 0, 0, 0] { append(value, to: &header) }
        append(crc, to: &header); append(size, to: &header); append(size, to: &header)
        append(UInt16(nameBytes.count), to: &header); append(UInt16(0), to: &header); header.append(nameBytes)
        try output.write(contentsOf: header); return entry
    }
    static func finish(entries: [Entry], output: FileHandle) throws {
        let start = try output.offset()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let largeOffset = entry.offset >= UInt64(UInt32.max)
            var header = Data(); append(UInt32(0x02014b50), to: &header)
            for value: UInt16 in [45, largeOffset ? 45 : 20, 0x800, 0, 0, 0] { append(value, to: &header) }
            append(entry.crc, to: &header); append(entry.size, to: &header); append(entry.size, to: &header)
            for value: UInt16 in [UInt16(name.count), largeOffset ? 12 : 0, 0, 0, 0] { append(value, to: &header) }
            append(UInt32(0), to: &header)
            append(largeOffset ? UInt32.max : UInt32(entry.offset), to: &header)
            header.append(name)
            if largeOffset { append(UInt16(1), to: &header); append(UInt16(8), to: &header); append(entry.offset, to: &header) }
            try output.write(contentsOf: header)
        }
        let end = try output.offset(), size = end - start
        let zip64 = start >= UInt64(UInt32.max) || size >= UInt64(UInt32.max) || entries.count >= Int(UInt16.max)
        var trailer = Data()
        if zip64 {
            append(UInt32(0x06064b50), to: &trailer); append(UInt64(44), to: &trailer)
            append(UInt16(45), to: &trailer); append(UInt16(45), to: &trailer)
            append(UInt32(0), to: &trailer); append(UInt32(0), to: &trailer)
            append(UInt64(entries.count), to: &trailer); append(UInt64(entries.count), to: &trailer)
            append(size, to: &trailer); append(start, to: &trailer)
            append(UInt32(0x07064b50), to: &trailer); append(UInt32(0), to: &trailer)
            append(end, to: &trailer); append(UInt32(1), to: &trailer)
        }
        append(UInt32(0x06054b50), to: &trailer)
        append(UInt16(0), to: &trailer); append(UInt16(0), to: &trailer)
        append(zip64 ? UInt16.max : UInt16(entries.count), to: &trailer)
        append(zip64 ? UInt16.max : UInt16(entries.count), to: &trailer)
        append(zip64 ? UInt32.max : UInt32(size), to: &trailer)
        append(zip64 ? UInt32.max : UInt32(start), to: &trailer); append(UInt16(0), to: &trailer)
        try output.write(contentsOf: trailer); try output.synchronize()
    }
    private static func checksum(_ data: Data, seed: uLong = 0) -> uLong {
        data.withUnsafeBytes { crc32(seed, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
    }
    private static func stream(_ file: URL, consume: (Data) throws -> Void) throws -> (UInt32, UInt32) {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var count = 0, crc: uLong = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard count <= DocumentFiles.backupLimit - chunk.count else { throw DocumentError.invalid }
            count += chunk.count; crc = checksum(chunk, seed: crc); try consume(chunk)
        }
        guard count > 0 else { throw DocumentError.invalid }
        return (UInt32(count), UInt32(crc))
    }
    static func write(manifest: Data, parts: [URL], destination: URL) throws -> URL {
        guard !manifest.isEmpty, manifest.count <= DocumentFiles.backupLimit, parts.count <= 2000,
              Set(parts.map(\.lastPathComponent)).count == parts.count else { throw DocumentError.invalid }
        for part in parts {
            guard part.isFileURL, CaptureStore.validPartName(part.lastPathComponent),
                  part.standardizedFileURL.resolvingSymlinksInPath() == part.standardizedFileURL else { throw DocumentError.invalid }
            let values = try part.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= DocumentFiles.backupLimit else { throw DocumentError.invalid }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw DocumentError.io }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        var entries = [try writeLocal(name: "manifest.json", size: UInt32(manifest.count), crc: UInt32(checksum(manifest)), output: output)]
        try output.write(contentsOf: manifest)
        for part in parts {
            let (size, crc) = try stream(part) { _ in }
            entries.append(try writeLocal(name: part.lastPathComponent, size: size, crc: crc, output: output))
            let (written, check) = try stream(part) { try output.write(contentsOf: $0) }
            guard written == size, check == crc else { throw DocumentError.io }
        }
        try finish(entries: entries, output: output); try output.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
