import Foundation
import XCTest
#if canImport(Runner)
@testable import Runner
#endif

final class DiagnosticsTests: XCTestCase {
    func testMemoryWarningOnlyTrimsRebuildableCachesWhileAttached() {
        let center = NotificationCenter()
        let warning = Notification.Name("test.memory.warning")
        var events: [String] = []
        let relay = MemoryPressureRelay(center: center, warningName: warning) { events.append($0) }
        center.post(name: Notification.Name("unrelated"), object: nil)
        center.post(name: warning, object: nil)
        XCTAssertEqual(events, ["trim"])
        relay.close()
        center.post(name: warning, object: nil)
        XCTAssertEqual(events, ["trim"], "detached engines must not receive late warnings")
    }

    func testMemoryObserverDoesNotRetainRelayOrInventTerminationWarning() {
        let center = NotificationCenter()
        let warning = Notification.Name("test.memory.warning")
        var events: [String] = []
        var relay: MemoryPressureRelay? = MemoryPressureRelay(center: center, warningName: warning) { events.append($0) }
        weak let weakRelay = relay
        relay = nil
        XCTAssertNil(weakRelay)
        center.post(name: warning, object: nil)
        XCTAssertTrue(events.isEmpty)
    }

    func testStoragePolicyExcludesOnlyCacheAndDownloadsAndPreservesBytes() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support")
        let caches = root.appendingPathComponent("Caches")
        let names = ["Documents/history_enc.hive", "Documents/chapter_cache_v1_enc.hive",
                     "Support/imported_books/book/chapter.txt", "Support/offline-audio/chapter.m4a.part",
                     "Support/offline-video/episode.mp4", "Support/backend/config/device_pool.json",
                     "Documents/my-backup.json", "Support/reader-fonts/font.ttf", "Caches/fqapp_images_v1/cover"]
        for name in names { try put(root.appendingPathComponent(name), bytes: Data("keep:\(name)".utf8)) }
        var writes: [StorageProtectionPolicy.Change] = []
        try StorageProtectionPolicy(documents: documents, support: support, caches: caches).apply { writes.append($0) }
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("offline-audio/chapter.m4a.part") && $0.backgroundReadable && $0.excludeFromBackup })
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("offline-video/episode.mp4") && $0.backgroundReadable && $0.excludeFromBackup })
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("chapter_cache_v1_enc.hive") && $0.excludeFromBackup })
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("history_enc.hive") && $0.backgroundReadable && !$0.excludeFromBackup })
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("imported_books/book/chapter.txt") && $0.backgroundReadable && !$0.excludeFromBackup })
        XCTAssertTrue(writes.contains { $0.url.path.hasSuffix("backend/config/device_pool.json") && $0.backgroundReadable && !$0.excludeFromBackup })
        XCTAssertFalse(writes.contains { $0.url == documents || $0.url == support || $0.url.path.hasSuffix("my-backup.json") || $0.url.path.hasSuffix("font.ttf") })
        for name in names { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("keep:\(name)".utf8)) }
        let first = Set(writes.map { $0.url.path })
        writes.removeAll()
        try StorageProtectionPolicy(documents: documents, support: support, caches: caches).apply { writes.append($0) }
        XCTAssertEqual(Set(writes.map { $0.url.path }), first, "repeat startup must be idempotent")
    }

    func testDownloadRootSymlinkCannotExcludeUserBooks() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let userBook = support.appendingPathComponent("imported_books/book.txt")
        try put(userBook, bytes: Data("user book".utf8))
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("offline-audio"), withDestinationURL: userBook.deletingLastPathComponent())
        var writes: [StorageProtectionPolicy.Change] = []
        XCTAssertThrowsError(try StorageProtectionPolicy(documents: root.appendingPathComponent("Documents"), support: support, caches: root.appendingPathComponent("Caches")).apply { writes.append($0) })
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: userBook), Data("user book".utf8))
    }

    func testNestedSymlinkCannotChangeExternalFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = try scratch()
        defer { try? FileManager.default.removeItem(at: external) }
        let target = external.appendingPathComponent("private.txt")
        try put(target, bytes: Data("untouched".utf8))
        let audio = root.appendingPathComponent("Support/offline-audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: audio.appendingPathComponent("redirect"), withDestinationURL: external)
        var writes: [StorageProtectionPolicy.Change] = []
        XCTAssertThrowsError(try StorageProtectionPolicy(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches")).apply { writes.append($0) })
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), Data("untouched".utf8))
    }

    func testStorageAttributeFailureIsReportedRatherThanClaimingConfigured() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = StorageProtectionPolicy(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        XCTAssertThrowsError(try policy.apply { _ in throw CocoaError(.fileWriteNoPermission) })
    }

    func testLazyBoxPolicyCannotSelectArbitraryPathsOrTraverseMediaTrees() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try put(documents.appendingPathComponent("chapter_cache_v1_enc.hive"), bytes: Data("cache".utf8))
        try put(documents.appendingPathComponent("history_enc.hive"), bytes: Data("history".utf8))
        let policy = StorageProtectionPolicy(documents: documents, support: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        var writes: [StorageProtectionPolicy.Change] = []
        try policy.apply(boxName: "chapter_cache_v1") { writes.append($0) }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].excludeFromBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Support").path))
        writes.removeAll()
        XCTAssertThrowsError(try policy.apply(boxName: "../history") { writes.append($0) })
        XCTAssertTrue(writes.isEmpty)
    }

    #if os(iOS)
    func testNativeBackupMetadataPreservesUserHistory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support")
        let audio = support.appendingPathComponent("offline-audio/chapter.m4a")
        let history = documents.appendingPathComponent("history_enc.hive")
        try put(audio, bytes: Data("encrypted media fixture".utf8))
        try put(history, bytes: Data("history fixture".utf8))
        try StorageProtectionPolicy(documents: documents, support: support, caches: root.appendingPathComponent("Caches")).apply()
        XCTAssertEqual(try audio.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertNotEqual(try history.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: audio), Data("encrypted media fixture".utf8))
    }
    func testFileProtectionAttributeOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator does not expose Data Protection attributes; physical-device verification pending")
        #else
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Support/offline-audio/chapter.m4a")
        try put(audio, bytes: Data("synthetic".utf8))
        try StorageProtectionPolicy(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches")).apply()
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
    }
    #endif

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fqapp-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func put(_ url: URL, bytes: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
}
