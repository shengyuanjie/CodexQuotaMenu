import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexClient()
    private var timer: Timer?
    private var isRefreshing = false
    private var lastSnapshot: UsageSnapshot?
    private var lastTaskSnapshot: TaskSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--check") {
            runConnectionCheck()
            return
        }
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Codex 用量")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = "读取中…"
        rebuildMenu(message: "正在读取 Codex 用量…")
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if lastSnapshot == nil { statusItem.button?.title = "读取中…" }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { (try self.client.fetchUsage(), try self.client.fetchTasks()) }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let (usage, tasks)):
                    self.lastSnapshot = usage
                    self.lastTaskSnapshot = tasks
                    self.render(usage, tasks: tasks)
                case .failure(let error):
                    self.render(error: error)
                }
            }
        }
    }

    private func render(_ snapshot: UsageSnapshot, tasks: TaskSnapshot) {
        if let window = snapshot.headlineWindow {
            let reset = window.resetsAt.map { " · \(Self.shortRemaining(until: $0))" } ?? ""
            let taskStatus = " · ▶\(tasks.running.count) ｜ ⏸\(tasks.waiting.count)"
            setMenuBarTitle("Codex \(window.remainingPercent)%\(reset)\(taskStatus)")
        }

        let menu = NSMenu()
        let heading = NSMenuItem(title: "Codex 剩余用量", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        for window in snapshot.windows {
            menu.addItem(disabledItem("\(window.name)：剩余 \(window.remainingPercent)%"))
            if let reset = window.resetsAt {
                menu.addItem(disabledItem("  重置：\(Self.fullDate(reset))（\(Self.longRemaining(until: reset))）"))
            }
        }

        if let plan = snapshot.plan {
            menu.addItem(.separator())
            menu.addItem(disabledItem("方案：\(plan.uppercased())"))
        }
        appendTasks(tasks, to: menu)
        menu.addItem(disabledItem("更新：\(Self.updateTime(snapshot.fetchedAt)) · 实时连接 / 5 秒校准"))
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func render(error: Error) {
        statusItem.button?.title = lastSnapshot == nil ? "Codex --" : statusItem.button?.title ?? "Codex --"
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if lastSnapshot != nil {
            rebuildMenu(message: "刷新失败：\(message)\n将保留上次结果")
        } else {
            rebuildMenu(message: message)
        }
    }

    private func rebuildMenu(message: String) {
        let menu = NSMenu()
        for line in message.split(separator: "\n") { menu.addItem(disabledItem(String(line))) }
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func appendActions(to menu: NSMenu) {
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func appendTasks(_ snapshot: TaskSnapshot, to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(disabledItem("当前任务"))
        menu.addItem(disabledItem("▶ 正常执行：\(snapshot.running.count)"))
        for task in snapshot.running.prefix(5) {
            menu.addItem(disabledItem("  ▶ \(task.title)"))
        }
        menu.addItem(disabledItem("⏸ 等待手动操作：\(snapshot.waiting.count)"))
        for task in snapshot.waiting.prefix(5) {
            menu.addItem(disabledItem("  ⏸ \(task.title)"))
        }
        if !snapshot.failed.isEmpty {
            menu.addItem(disabledItem("⚠ 异常：\(snapshot.failed.count)"))
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func setMenuBarTitle(_ title: String) {
        let baseFont = NSFont.menuBarFont(ofSize: 0)
        let attributed = NSMutableAttributedString(
            string: title,
            attributes: [.font: baseFont]
        )
        let pauseRange = (title as NSString).range(of: "⏸")
        if pauseRange.location != NSNotFound {
            let pauseFont = NSFont.menuBarFont(ofSize: baseFont.pointSize + 2)
            attributed.addAttributes([
                .font: pauseFont,
                .baselineOffset: -0.6
            ], range: pauseRange)
        }
        statusItem.button?.attributedTitle = attributed
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func runConnectionCheck() {
        do {
            let snapshot = try client.fetchUsage()
            let tasks = try client.fetchTasks()
            let summary = snapshot.windows
                .map { "\($0.name)剩余 \($0.remainingPercent)%" }
                .joined(separator: "，")
            FileHandle.standardOutput.write(Data("连接成功：\(summary)，正常执行 \(tasks.running.count)，等待操作 \(tasks.waiting.count)\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("连接失败：\(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func shortRemaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86_400 { return "\(seconds / 86_400)天\((seconds % 86_400) / 3_600)时" }
        if seconds >= 3_600 { return "\(seconds / 3_600)时\((seconds % 3_600) / 60)分" }
        return "\(max(1, seconds / 60))分"
    }

    private static func longRemaining(until date: Date) -> String { "还剩 \(shortRemaining(until: date))" }

    private static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func updateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
