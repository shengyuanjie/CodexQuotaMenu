import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexClient()
    private var timer: Timer?
    private var isRefreshing = false
    private var lastSnapshot: UsageSnapshot?
    private var lastTaskSnapshot: TaskSnapshot?
    private var languageSelection = AppLanguage.load()

    private var text: AppText {
        AppText(language: languageSelection.resolved())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--check") {
            runConnectionCheck()
            return
        }
        statusItem.button?.title = text.loadingTitle
        rebuildMenu(message: text.loadingMessage)
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        if lastSnapshot == nil { statusItem.button?.title = text.loadingTitle }

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
            let reset = window.resetsAt.map { " · \(text.shortRemaining(until: $0))" } ?? ""
            let taskStatus = " · ▶ \(tasks.running.count) \(text.taskDivider) ⏸ \(tasks.waiting.count)"
            setMenuBarTitle("Codex \(window.remainingPercent)%\(reset)\(taskStatus)")
        }

        let menu = NSMenu()
        let heading = NSMenuItem(title: text.remainingUsageHeading, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        for window in snapshot.windows {
            menu.addItem(disabledItem(text.remainingUsage(window: window)))
            if let reset = window.resetsAt {
                menu.addItem(disabledItem(text.resetDescription(date: reset)))
            }
        }

        if let plan = snapshot.plan {
            menu.addItem(.separator())
            menu.addItem(disabledItem(text.planDescription(plan)))
        }
        appendTasks(tasks, to: menu)
        menu.addItem(disabledItem(text.updatedDescription(snapshot.fetchedAt)))
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func render(error: Error) {
        statusItem.button?.title = lastSnapshot == nil ? "Codex --" : statusItem.button?.title ?? "Codex --"
        let message = text.errorDescription(error)
        rebuildMenu(message: text.refreshFailed(message, preservesLastResult: lastSnapshot != nil))
    }

    private func rebuildMenu(message: String) {
        let menu = NSMenu()
        for line in message.split(separator: "\n") { menu.addItem(disabledItem(String(line))) }
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func appendActions(to menu: NSMenu) {
        menu.addItem(.separator())
        let languageItem = NSMenuItem(title: text.languageAction, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for selection in AppLanguage.allCases {
            let item = NSMenuItem(
                title: text.languageName(selection),
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = selection.rawValue
            item.state = selection == languageSelection ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let refreshItem = NSMenuItem(title: text.refreshAction, action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: text.quitAction, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func appendTasks(_ snapshot: TaskSnapshot, to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(disabledItem(text.currentTasksHeading))
        menu.addItem(disabledItem(text.runningDescription(snapshot.running.count)))
        for task in snapshot.running.prefix(5) {
            menu.addItem(disabledItem("  ▶ \(task.title)"))
        }
        menu.addItem(disabledItem(text.waitingDescription(snapshot.waiting.count)))
        for task in snapshot.waiting.prefix(5) {
            menu.addItem(disabledItem("  ⏸ \(task.title)"))
        }
        if !snapshot.failed.isEmpty {
            menu.addItem(disabledItem(text.failedDescription(snapshot.failed.count)))
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

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selection = AppLanguage(rawValue: rawValue) else { return }
        languageSelection = selection
        languageSelection.save()
        if let snapshot = lastSnapshot, let tasks = lastTaskSnapshot {
            render(snapshot, tasks: tasks)
        } else {
            statusItem.button?.title = text.loadingTitle
            rebuildMenu(message: text.loadingMessage)
        }
    }

    private func runConnectionCheck() {
        do {
            let snapshot = try client.fetchUsage()
            let tasks = try client.fetchTasks()
            let summary = snapshot.windows
                .map { text.remainingUsage(window: $0) }
                .joined(separator: text.language == .simplifiedChinese ? "，" : ", ")
            let message = text.connectionSuccess(
                summary: summary,
                running: tasks.running.count,
                waiting: tasks.waiting.count
            )
            FileHandle.standardOutput.write(Data("\(message)\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            let message = text.connectionFailure(text.errorDescription(error))
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
