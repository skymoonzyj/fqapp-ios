import Foundation

struct RenewalState: Decodable {
    var schema_version: Int?
    var status: String
    var message: String
    var paused: Bool
    var installed_expires_at: String?
    var last_check_at: String?
    var last_success_at: String?
    var next_check_at: String?
    var error_code: String?
    var notification_id: String?
    var last_run_dir: String?

    static let initial = RenewalState(status: "unknown", message: "等待首次检查", paused: false)

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    var expiryDate: Date? { Self.date(installed_expires_at) }
    var meaningfulNotificationID: String? {
        guard ["renewed", "error", "deferred"].contains(status),
              let id = notification_id, !id.isEmpty else { return nil }
        return id
    }
}

struct RenewalSnapshot {
    private(set) var state = RenewalState.initial
    private var lastPersistedData: Data?

    mutating func loadPersisted(_ data: Data) {
        guard data != lastPersistedData,
              let saved = try? JSONDecoder().decode(RenewalState.self, from: data) else { return }
        lastPersistedData = data
        state = saved
    }

    // Command output can report a lock or write failure that could not itself
    // be saved. Keep it until a later persisted snapshot actually changes.
    mutating func applyCommand(_ state: RenewalState) { self.state = state }
}

// Accessed only on the AppKit main thread. The engine also owns an interprocess
// lock; this gate prevents duplicate launches from menu, timer, and wake events.
struct RunGate {
    private(set) var isRunning = false
    private var lastAutomaticStart: Date?

    mutating func begin(automatic: Bool, paused: Bool, now: Date = Date()) -> Bool {
        guard !isRunning, !(automatic && paused) else { return false }
        if automatic, let lastAutomaticStart,
           now.timeIntervalSince(lastAutomaticStart) < 60 { return false }
        isRunning = true
        if automatic { lastAutomaticStart = now }
        return true
    }

    mutating func finish() { isRunning = false }
}

struct EngineResult {
    let exitCode: Int32
    let state: RenewalState?
    let failure: String?
}

private final class BoundedPipeReader {
    private let handle: FileHandle
    private(set) var data = Data()
    init(_ handle: FileHandle) { self.handle = handle }

    func drain() {
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let remaining = 1024 * 1024 - data.count
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
        }
    }
}

struct EngineRunner {
    let pythonPath: String
    let home: URL

    // Must run off the main thread. Both pipes drain concurrently, including
    // beyond the capture limit, so verbose diagnostics cannot block the engine.
    func run(command: String) -> EngineResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [home.appendingPathComponent("renew.py").path, "--home", home.path, command]
        process.currentDirectoryURL = home
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return EngineResult(exitCode: -1, state: nil, failure: "无法启动续签程序，请检查安装并查看日志。")
        }
        // Close the parent's write descriptors; only the child keeps a writer.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let output = BoundedPipeReader(stdout.fileHandleForReading)
        let diagnostic = BoundedPipeReader(stderr.fileHandleForReading)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { output.drain(); readers.leave() }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { diagnostic.drain(); readers.leave() }
        process.waitUntilExit()
        readers.wait()
        let state = try? JSONDecoder().decode(RenewalState.self, from: output.data)
        let failure = state == nil ? "续签程序未返回有效状态，请打开日志查看。" : nil
        return EngineResult(exitCode: process.terminationStatus, state: state, failure: failure)
    }
}
