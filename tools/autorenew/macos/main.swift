import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let runtime = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FqappAutoRenew", isDirectory: true)
    private var statusItem: NSStatusItem?
    private var statusWindow: NSWindow?
    private var windowStatusLabel: NSTextField?
    private var windowExpiryLabel: NSTextField?
    private var windowNextLabel: NSTextField?
    private var windowActionButtons: [NSButton] = []
    private var windowPauseButton: NSButton?
    private var snapshot = RenewalSnapshot()
    private var state: RenewalState { snapshot.state }
    private var gate = RunGate()
    private var timer: Timer?
    private var stateRefreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var nextAutomaticCheck: Date?
    private var operationMessage: String?
    private var localFailure: String?
    private var notificationInFlight: String?
    private let notificationKey = "lastDeliveredNotificationID"
    private let engineQueue = DispatchQueue(label: "com.fqapp.autorenew.engine", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test") {
            let menu = makeMenu()
            let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            guard titles.count == 10, titles.contains("查看状态…"), titles.contains("立即检查"), titles.contains("立即续签"),
                  titles.contains("暂停自动续签"), titles.contains("打开日志"), titles.contains("退出（本次登录停止续签）") else {
                fputs("FAIL: menu construction\n", stderr)
                exit(1)
            }
            createStatusWindow()
            updateStatusWindow()
            guard statusWindow != nil, windowStatusLabel?.stringValue == "等待首次检查",
                  windowActionButtons.count == 3, windowPauseButton?.title == "暂停自动续签" else {
                fputs("FAIL: status window construction\n", stderr)
                exit(1)
            }
            print("{\"self_test\":\"passed\",\"menu_items\":10,\"status_window\":true,\"engine_invoked\":false}")
            NSApp.terminate(nil)
            return
        }
        loadState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.notifyIfNeeded() }
        }
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.run("check", automatic: true)
        }
        run("check", automatic: true)
        if !UserDefaults.standard.bool(forKey: "didShowInitialStatusWindow") {
            UserDefaults.standard.set(true, forKey: "didShowInitialStatusWindow")
            showStatusWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        stateRefreshTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func scheduleTimer() {
        let next = Date().addingTimeInterval(3600)
        nextAutomaticCheck = next
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.nextAutomaticCheck = Date().addingTimeInterval(3600)
            self?.run("check", automatic: true)
        }
        timer?.tolerance = 30
        updateMenu()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("state.json")) else { return }
        snapshot.loadPersisted(data)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "尚未获取" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = action != nil
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let description = operationMessage ?? localFailure ?? state.message
        menu.addItem(item("状态：\(description)"))
        menu.addItem(item("签名到期：\(formatted(state.expiryDate))"))
        let next = state.paused ? "已暂停" : formatted(nextAutomaticCheck)
        menu.addItem(item("下次检查：\(next)"))
        menu.addItem(.separator())
        menu.addItem(item("查看状态…", action: #selector(showStatusWindow)))
        let check = item("立即检查", action: #selector(checkNow))
        let renew = item("立即续签", action: #selector(renewNow))
        let pause = item(state.paused ? "恢复自动续签" : "暂停自动续签", action: #selector(togglePause))
        for entry in [check, renew, pause] {
            entry.isEnabled = !gate.isRunning
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("打开日志", action: #selector(openLogs)))
        let info = item("fqapp 自动续签")
        info.toolTip = "自动检查每小时运行一次；距离到期 48 小时内尝试续签。"
        menu.addItem(info)
        let quit = item(gate.isRunning ? "任务进行中，完成后可退出" : "退出（本次登录停止续签）", action: #selector(quitApp))
        quit.isEnabled = !gate.isRunning
        menu.addItem(quit)
        return menu
    }

    private func updateMenu() {
        let symbol: String
        if gate.isRunning { symbol = "arrow.triangle.2.circlepath" }
        else if localFailure != nil || state.status == "error" { symbol = "exclamationmark.shield" }
        else if state.paused { symbol = "pause.circle" }
        else { symbol = "checkmark.shield" }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "fqapp 自动续签")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "fqapp 自动续签：\(operationMessage ?? localFailure ?? state.message)"
        let refreshed = makeMenu()
        if let menu = statusItem?.menu, menu.items.count == refreshed.items.count {
            for (old, new) in zip(menu.items, refreshed.items) {
                old.title = new.title
                old.isEnabled = new.isEnabled
                old.toolTip = new.toolTip
            }
        } else {
            statusItem?.menu = refreshed
        }
        updateStatusWindow()
    }

    private func createStatusWindow() {
        guard statusWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 370),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "fqapp 自动续签"
        window.isReleasedWhenClosed = false
        window.center()
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "fqapp 自动续签")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 14)
        status.maximumNumberOfLines = 3
        let expiry = NSTextField(labelWithString: "")
        let next = NSTextField(labelWithString: "")
        expiry.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        next.font = expiry.font
        let check = NSButton(title: "立即检查", target: self, action: #selector(checkNow))
        let renew = NSButton(title: "立即续签", target: self, action: #selector(renewNow))
        let pause = NSButton(title: "暂停自动续签", target: self, action: #selector(togglePause))
        let logs = NSButton(title: "打开日志", target: self, action: #selector(openLogs))
        for button in [check, renew, pause, logs] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [check, renew, pause, logs])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString: "每小时检查，距到期 48 小时内自动续签。\n关闭窗口后，菜单栏继续工作。")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, status, expiry, next, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        windowStatusLabel = status
        windowExpiryLabel = expiry
        windowNextLabel = next
        windowActionButtons = [check, renew, pause]
        windowPauseButton = pause
        statusWindow = window
    }

    private func updateStatusWindow() {
        windowStatusLabel?.stringValue = operationMessage ?? localFailure ?? state.message
        windowExpiryLabel?.stringValue = "签名到期：\(formatted(state.expiryDate))"
        windowNextLabel?.stringValue = "下次检查：\(state.paused ? "已暂停" : formatted(nextAutomaticCheck))"
        windowPauseButton?.title = state.paused ? "恢复自动续签" : "暂停自动续签"
        for button in windowActionButtons { button.isEnabled = !gate.isRunning }
    }

    @objc private func showStatusWindow() {
        loadState()
        createStatusWindow()
        updateStatusWindow()
        if statusWindow?.isMiniaturized == true { statusWindow?.deminiaturize(nil) }
        statusWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        loadState()
        // Update existing titles while tracking rather than replacing the menu.
        let refreshed = makeMenu()
        for (old, new) in zip(menu.items, refreshed.items) {
            old.title = new.title
            old.isEnabled = new.isEnabled
        }
    }

    private func run(_ command: String, automatic: Bool = false) {
        loadState()
        guard gate.begin(automatic: automatic, paused: state.paused) else { updateMenu(); return }
        localFailure = nil
        operationMessage = command == "renew" ? "正在续签…" : command == "pause" ? "正在暂停…" : command == "resume" ? "正在恢复…" : "正在检查…"
        updateMenu()
        stateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.loadState()
            if self.state.status == "renewing" { self.operationMessage = self.state.message }
            self.updateMenu()
        }
        let python = Bundle.main.object(forInfoDictionaryKey: "FQPythonPath") as? String ?? "/usr/bin/python3"
        let runner = EngineRunner(pythonPath: python, home: runtime)
        engineQueue.async { [weak self] in
            let result = runner.run(command: command)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stateRefreshTimer?.invalidate()
                self.stateRefreshTimer = nil
                self.gate.finish()
                self.operationMessage = nil
                self.loadState()
                // A busy/error result may be unable to write state under the
                // engine lock; its command output is newer than disk state.
                if let outputState = result.state { self.snapshot.applyCommand(outputState) }
                self.localFailure = result.failure
                if result.exitCode != 0 && result.state?.status != "error" {
                    self.localFailure = "续签程序执行失败，请打开日志查看。"
                }
                self.updateMenu()
                self.notifyIfNeeded()
                if command == "resume", !self.state.paused { self.run("check") }
            }
        }
    }

    private func notifyIfNeeded() {
        let id: String
        let message: String
        if let localFailure {
            id = "gui-engine-error-\(localFailure)"
            message = localFailure
        } else {
            guard let stateID = state.meaningfulNotificationID else { return }
            id = stateID
            message = state.message
        }
        guard UserDefaults.standard.string(forKey: notificationKey) != id, notificationInFlight != id else { return }
        notificationInFlight = id
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { self?.notificationInFlight = nil }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "fqapp 自动续签"
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(identifier: "fqapp-renewal-event", content: content, trigger: nil)
            center.add(request) { [weak self] error in
                DispatchQueue.main.async {
                    self?.notificationInFlight = nil
                    if error == nil { UserDefaults.standard.set(id, forKey: self?.notificationKey ?? "lastDeliveredNotificationID") }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func checkNow() { run("check") }
    @objc private func renewNow() { run("renew") }
    @objc private func togglePause() { run(state.paused ? "resume" : "pause") }
    @objc private func openLogs() {
        let logs = runtime.appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logs.path) ? logs : runtime)
    }
    @objc private func quitApp() { if !gate.isRunning { NSApp.terminate(nil) } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
