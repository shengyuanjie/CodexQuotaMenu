import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexClient()
    private lazy var forecastCoordinator = ForecastCoordinator(
        client: ForecastClient(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        ),
        cache: UserDefaultsForecastCache()
    )
    private var localTimer: Timer?
    private var forecastTimer: Timer?
    private var isRefreshing = false
    private var lastSnapshot: UsageSnapshot?
    private var lastTaskSnapshot: TaskSnapshot?
    private var lastForecastSnapshot = ForecastDisplaySnapshot.unavailable
    private var localRefreshError: Error?
    private var lastForecastAttempt: Date?
    private var languageSelection = AppLanguage.load()
    private let forecastRefreshGate = RefreshGate(interval: 300, manualMinimumInterval: 30)

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
        loadCachedForecast()
        refreshLocal()
        refreshForecast(manual: false)

        localTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshLocal()
        }
        RunLoop.main.add(localTimer!, forMode: .common)

        forecastTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshForecast(manual: false)
        }
        RunLoop.main.add(forecastTimer!, forMode: .common)
    }

    private func refreshLocal() {
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
                    self.localRefreshError = nil
                case .failure(let error):
                    self.localRefreshError = error
                }
                self.renderCurrentState()
            }
        }
    }

    private func loadCachedForecast() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.forecastCoordinator.current(now: Date())
            self.lastForecastSnapshot = snapshot
            self.renderCurrentState()
        }
    }

    private func refreshForecast(manual: Bool) {
        let now = Date()
        guard forecastRefreshGate.shouldRefresh(
            lastAttempt: lastForecastAttempt,
            now: now,
            manual: manual
        ) else { return }
        lastForecastAttempt = now

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.forecastCoordinator.refresh(now: now)
            self.lastForecastSnapshot = snapshot
            self.renderCurrentState()
        }
    }

    private func renderCurrentState() {
        let window = lastSnapshot?.headlineWindow
        setMenuBarTitle(MenuPresentation.title(
            remainingPercent: window?.remainingPercent,
            resetText: window?.resetsAt.map { text.shortRemaining(until: $0) },
            forecast: lastForecastSnapshot,
            runningCount: lastTaskSnapshot?.running.count
        ))

        let menu = NSMenu()
        if let snapshot = lastSnapshot {
            menu.addItem(disabledItem(text.remainingUsageHeading))
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
        } else {
            appendMessage(localRefreshError.map(text.errorDescription) ?? text.loadingMessage, to: menu)
        }

        if let localRefreshError, lastSnapshot != nil {
            menu.addItem(.separator())
            appendMessage(
                text.refreshFailed(text.errorDescription(localRefreshError), preservesLastResult: true),
                to: menu
            )
        }
        appendForecast(to: menu)
        if let tasks = lastTaskSnapshot {
            appendTasks(tasks, to: menu)
        }
        if let fetchedAt = lastSnapshot?.fetchedAt {
            menu.addItem(disabledItem(text.updatedDescription(fetchedAt)))
        }
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func rebuildMenu(message: String) {
        let menu = NSMenu()
        appendMessage(message, to: menu)
        appendActions(to: menu)
        statusItem.menu = menu
    }

    private func appendMessage(_ message: String, to menu: NSMenu) {
        for line in message.split(separator: "\n") {
            menu.addItem(disabledItem(String(line)))
        }
    }

    private func appendForecast(to menu: NSMenu) {
        let forecast = lastForecastSnapshot
        menu.addItem(.separator())
        menu.addItem(disabledItem(text.globalResetForecastHeading))
        menu.addItem(disabledItem(text.forecast24hDescription(forecast.probability24h)))
        menu.addItem(disabledItem(text.forecast48hDescription(forecast.probability48h)))
        menu.addItem(disabledItem(text.forecastConfidenceDescription(forecast.confidence)))
        menu.addItem(disabledItem(text.forecastStatusDescription(forecast.status)))
        let updateTime = forecast.updatedAt.map(text.updateTime)
        menu.addItem(disabledItem(text.forecastUpdatedDescription(updateTime, isCached: forecast.isCached)))
        if forecast.strongSignal {
            menu.addItem(disabledItem(text.strongSignalDescription))
        }
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
        statusItem.button?.title = title
    }

    @objc private func refreshClicked() {
        refreshLocal()
        refreshForecast(manual: true)
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selection = AppLanguage(rawValue: rawValue) else { return }
        languageSelection = selection
        languageSelection.save()
        renderCurrentState()
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
                running: tasks.running.count
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
