import Foundation

@main
struct CoreTests {
    static func main() throws {
        // Removing pause handling or allowing a second process must fail here.
        var gate = RunGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(!gate.begin(automatic: true, paused: true, now: now))
        precondition(gate.begin(automatic: false, paused: true, now: now))
        precondition(!gate.begin(automatic: false, paused: false, now: now))
        gate.finish()
        precondition(gate.begin(automatic: true, paused: false, now: now))
        gate.finish()
        precondition(!gate.begin(automatic: true, paused: false, now: now.addingTimeInterval(10)))
        precondition(gate.begin(automatic: true, paused: false, now: now.addingTimeInterval(60)))
        gate.finish()

        // Fractional ISO dates and optional fields are emitted by valid engines.
        let data = Data(#"{"schema_version":1,"status":"healthy","message":"正常","paused":false,"installed_expires_at":"2026-10-29T04:30:00.123Z","notification_id":null}"#.utf8)
        let state = try JSONDecoder().decode(RenewalState.self, from: data)
        precondition(state.expiryDate != nil)
        precondition(state.meaningfulNotificationID == nil)
        let success = try JSONDecoder().decode(RenewalState.self, from: Data(#"{"schema_version":1,"status":"renewed","message":"续签完成","paused":false,"notification_id":"installed-1"}"#.utf8))
        precondition(success.meaningfulNotificationID == "installed-1")
        let nonEvent = try JSONDecoder().decode(RenewalState.self, from: Data(#"{"schema_version":1,"status":"healthy","message":"正常","paused":false,"notification_id":"old-event"}"#.utf8))
        precondition(nonEvent.meaningfulNotificationID == nil)

        // An error returned without a successful state write must remain
        // visible when the menu reloads unchanged, older disk bytes.
        var snapshot = RenewalSnapshot()
        snapshot.loadPersisted(data)
        let commandError = try JSONDecoder().decode(RenewalState.self, from: Data(#"{"status":"error","message":"写入失败","paused":false,"notification_id":"write-failed"}"#.utf8))
        snapshot.applyCommand(commandError)
        snapshot.loadPersisted(data)
        precondition(snapshot.state.status == "error")
        precondition(snapshot.state.meaningfulNotificationID == "write-failed")
        let fresh = Data(#"{"schema_version":1,"status":"healthy","message":"已恢复","paused":false,"last_check_at":"2026-10-22T15:00:00Z"}"#.utf8)
        snapshot.loadPersisted(fresh)
        precondition(snapshot.state.message == "已恢复")
        snapshot.loadPersisted(Data("invalid".utf8))
        precondition(snapshot.state.message == "已恢复")

        // Run the actual process boundary with output larger than pipe capacity
        // on both streams: serial pipe reading would deadlock.
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let result = EngineRunner(pythonPath: "/usr/bin/python3", home: fixture).run(command: "check")
        precondition(result.exitCode == 0, "fixture runner failed: \(result.failure ?? "unknown")")
        precondition(result.state?.message.count == 200_000)
        let failure = EngineRunner(pythonPath: "/usr/bin/python3", home: fixture).run(command: "renew")
        precondition(failure.exitCode == 1)
        precondition(failure.state?.status == "error")
        let missing = EngineRunner(pythonPath: "/missing/fqapp-python", home: fixture).run(command: "check")
        precondition(missing.failure != nil)
        print("PASS: pause/overlap/debounce, ISO state, event filtering, concurrent pipe drain, nonzero and launch failures")
    }
}
