import Foundation

/// Only native-discovered sandbox roots enter this policy. No channel accepts
/// caller-selected paths. Backup exclusion is limited to replaceable downloads
/// and caches, while imported books and user history retain their backup policy.
struct StorageProtectionPolicy {
    struct Change {
        let url: URL
        let backgroundReadable: Bool
        let excludeFromBackup: Bool
    }
    enum PolicyError: Error { case unsafePath, tooManyFiles }

    let documents: URL
    let support: URL
    let caches: URL

    static func application(fileManager: FileManager = .default) throws -> Self {
        try Self(
            documents: fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
            support: fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true),
            caches: fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        )
    }

    func apply(boxName: String? = nil) throws {
        try apply(boxName: boxName) { change in
            #if os(iOS)
            if change.backgroundReadable {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: change.url.path
                )
            }
            #endif
            if change.excludeFromBackup {
                var url = change.url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
        }
    }

    /// Preflight every path before modifying attributes; a symlink in a cache
    /// must never redirect backup exclusion or file protection into user data.
    func apply(boxName: String? = nil, _ write: (Change) throws -> Void) throws {
        let fm = FileManager.default
        var changes: [Change] = []
        let supportRoot = support.standardizedFileURL.resolvingSymlinksInPath()
        let documentRoot = documents.standardizedFileURL.resolvingSymlinksInPath()
        let cacheRoot = caches.standardizedFileURL.resolvingSymlinksInPath()

        func check(_ url: URL, within root: URL) throws {
            guard url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
                throw PolicyError.unsafePath
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == url.standardizedFileURL.path else { throw PolicyError.unsafePath }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PolicyError.unsafePath }
        }

        func tree(_ name: String, root: URL, create: Bool, readable: Bool, excluded: Bool) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            // Inspect existing parent components too (for example backend/config).
            var component = root
            for part in name.split(separator: "/") {
                component.appendPathComponent(String(part))
                if fm.fileExists(atPath: component.path) {
                    try check(component, within: root)
                } else if (try? fm.destinationOfSymbolicLink(atPath: component.path)) != nil {
                    throw PolicyError.unsafePath
                }
            }
            if !fm.fileExists(atPath: directory.path) {
                if !create { return }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var pending = [directory]
            while let item = pending.popLast() {
                try check(item, within: root)
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values.isDirectory == true || values.isRegularFile == true else {
                    throw PolicyError.unsafePath
                }
                changes.append(Change(url: item, backgroundReadable: readable, excludeFromBackup: excluded))
                guard changes.count <= 100_000 else { throw PolicyError.tooManyFiles }
                if values.isDirectory == true {
                    pending.append(contentsOf: try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))
                }
            }
        }

        if boxName == nil {
        try tree("offline-audio", root: supportRoot, create: true, readable: true, excluded: true)
        try tree("offline-video", root: supportRoot, create: true, readable: true, excluded: true)
        try tree("imported_books", root: supportRoot, create: true, readable: true, excluded: false)
        try tree("backend/config", root: supportRoot, create: true, readable: true, excluded: false)
        // path_provider_foundation maps getTemporaryDirectory to NSCachesDirectory.
        try tree("fqapp_images_v1", root: cacheRoot, create: false, readable: false, excluded: true)

        }

        let boxes: [(String, Bool)] = [
            ("history", false), ("read_time", false), ("watched_episodes", false),
            ("audio_download_v1", true), ("drama_download_v1", true), ("chapter_cache_v1", true),
        ]
        if let boxName, !boxes.contains(where: { $0.0 == boxName }) { throw PolicyError.unsafePath }
        for (name, excluded) in boxes where boxName == nil || boxName == name {
            for suffix in ["_enc.hive", "_enc.hivec", "_enc.lock", ".hive", ".hivec", ".lock"] {
                let url = documentRoot.appendingPathComponent(name + suffix)
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    throw PolicyError.unsafePath
                }
                guard fm.fileExists(atPath: url.path) else { continue }
                try check(url, within: documentRoot)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw PolicyError.unsafePath
                }
                changes.append(Change(url: url, backgroundReadable: true, excludeFromBackup: excluded))
            }
        }
        for change in changes {
            // Revalidate just before the write as well; the sandbox is private,
            // but a moved/replaced path must fail rather than follow a symlink.
            let path = change.url.standardizedFileURL.path
            let root = path.hasPrefix(supportRoot.path + "/") ? supportRoot
                : path.hasPrefix(documentRoot.path + "/") ? documentRoot : cacheRoot
            try check(change.url, within: root)
            try write(change)
        }
    }
}
