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
    private var resetCreditArrivalTracker = ResetCreditArrivalTracker()
    private var lastTaskSnapshot: TaskSnapshot?
    private var lastForecastSnapshot = ForecastDisplaySnapshot.unavailable
    private var localRefreshError: Error?
    private var lastForecastAttempt: Date?
    private var languageSelection = AppLanguage.load()
    private let forecastRefreshGate = RefreshGate(interval: 300, manualMinimumInterval: 30)
    private let resetCelebrationStateStore = UserDefaultsResetCelebrationStateStore()
    private lazy var resetCelebrationState = resetCelebrationStateStore.load()
    private let widgetSnapshotStore = WidgetSnapshotStore()
    private let widgetTokenStore = KeychainWidgetTokenStore()
    private let widgetTokenCache = WidgetTokenCache()
    private let widgetPreferences = WidgetPreferences()
    private var widgetServer: WidgetServer?
    private var widgetServerState = WidgetServerState.stopped
    private var widgetRetryAttempt = 0
    private var widgetRetryWorkItem: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    @MainActor private lazy var activationScheduleModel = ActivationScheduleSettingsModel()
    @MainActor private var activationScheduleWindowController: ActivationScheduleWindowController?
    @MainActor private var defaultModelWindowController: DefaultModelWindowController?
    @MainActor private var scheduledMessageWindowController: ScheduledMessageWindowController?

    private var text: AppText {
        AppText(language: languageSelection.resolved())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeWorkspaceRecovery()
        statusItem.button?.title = text.loadingTitle
        rebuildMenu(message: text.loadingMessage)
        if widgetPreferences.isServerEnabled {
            startWidgetServer()
        }
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

        MainActor.assumeIsolated {
            activationScheduleModel.load()
            if CommandLine.arguments.contains("--activation-settings") { openActivationScheduleSettings() }
            if CommandLine.arguments.contains("--model-settings") { openDefaultModelSettings() }
            if CommandLine.arguments.contains("--scheduled-message-settings") { openScheduledMessageSettings() }
        }
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
                var newResetCredit = false
                switch result {
                case .success(let (usage, tasks)):
                    newResetCredit = self.resetCreditArrivalTracker.observe(usage.resetCredits, fetchedAt: usage.fetchedAt)
                    self.lastSnapshot = usage
                    self.lastTaskSnapshot = tasks
                    self.localRefreshError = nil
                case .failure(let error):
                    self.localRefreshError = error
                }
                self.renderCurrentState(newlyGrantedResetCredit: newResetCredit)
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

    private func renderCurrentState(newlyGrantedResetCredit: Bool = false) {
        let now = Date()
        let shortWindow = lastSnapshot?.shortWindow
        let weeklyWindow = lastSnapshot?.weeklyWindow
        let celebration = ResetCelebrationPolicy.evaluate(
            state: resetCelebrationState,
            probability48h: lastForecastSnapshot.probability48h,
            observation: resetQuotaObservation(shortWindow: shortWindow, weeklyWindow: weeklyWindow),
            newlyGrantedResetCredit: newlyGrantedResetCredit
        )
        if celebration.state != resetCelebrationState {
            resetCelebrationState = celebration.state
            resetCelebrationStateStore.save(celebration.state)
        }
        updateWidgetSnapshot(resetCelebrationActive: celebration.isActive)
        setMenuBarTitle(MenuPresentation.title(
            shortRemainingPercent: shortWindow?.remainingPercent,
            shortResetText: shortWindow?.resetsAt.map { text.compactRemaining(until: $0, now: now) },
            weeklyRemainingPercent: weeklyWindow?.remainingPercent,
            weeklyResetText: weeklyWindow?.resetsAt.map { text.compactRemaining(until: $0, now: now) },
            forecast: lastForecastSnapshot,
            resetCelebrationActive: celebration.isActive,
            runningCount: lastTaskSnapshot?.running.count,
            language: text.language
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
            menu.addItem(.separator())
            for line in text.resetCreditDescriptions(snapshot.resetCredits) {
                menu.addItem(disabledItem(line))
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
        updateWidgetSnapshot(resetCelebrationActive: false)
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
        menu.addItem(disabledItem(text.forecast48hDescription(forecast.probability48h)))
        menu.addItem(disabledItem(text.forecastStatusDescription(forecast.status)))
        let updateTime = forecast.updatedAt.map(text.updateTime)
        menu.addItem(disabledItem(text.forecastUpdatedDescription(updateTime, isCached: forecast.isCached)))
        menu.addItem(disabledItem(text.forecastSourceDescription))
    }

    private func appendActions(to menu: NSMenu) {
        menu.addItem(.separator())
        appendWidgetMenu(to: menu)

        menu.addItem(Self.activationScheduleMenuItem(
            text: text,
            target: self,
            action: #selector(openActivationScheduleSettings)
        ))

        let modelItem = NSMenuItem(title: text.defaultModelAction, action: #selector(openDefaultModelSettings), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)

        let messageItem = NSMenuItem(title: text.modelText("定时发送消息…", "Scheduled Message…"), action: #selector(openScheduledMessageSettings), keyEquivalent: "")
        messageItem.target = self
        menu.addItem(messageItem)

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

    private func appendWidgetMenu(to menu: NSMenu) {
        let widgetItem = NSMenuItem(title: text.phoneWidgetHeading, action: nil, keyEquivalent: "")
        let widgetMenu = NSMenu()

        let toggleItem = NSMenuItem(
            title: text.enableWidgetServerAction,
            action: #selector(toggleWidgetServer),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = widgetPreferences.isServerEnabled ? .on : .off
        widgetMenu.addItem(toggleItem)

        widgetMenu.addItem(.separator())
        let addressItem = NSMenuItem(
            title: text.copyWidgetAddressAction,
            action: #selector(copyWidgetAddress),
            keyEquivalent: ""
        )
        addressItem.target = self
        widgetMenu.addItem(addressItem)

        let tokenItem = NSMenuItem(
            title: text.copyWidgetTokenAction,
            action: #selector(copyWidgetToken),
            keyEquivalent: ""
        )
        tokenItem.target = self
        widgetMenu.addItem(tokenItem)

        let regenerateItem = NSMenuItem(
            title: text.regenerateWidgetTokenAction,
            action: #selector(regenerateWidgetToken),
            keyEquivalent: ""
        )
        regenerateItem.target = self
        widgetMenu.addItem(regenerateItem)

        if widgetServerState == .failed {
            widgetMenu.addItem(.separator())
            widgetMenu.addItem(disabledItem("⚠ \(text.widgetServerFailed)"))
        }

        widgetItem.submenu = widgetMenu
        menu.addItem(widgetItem)
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
        // AppKit still dims attributed titles for disabled menu items. A custom
        // label keeps status information readable without making it an action.
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.sizeToFit()
        let height = max(22, ceil(label.frame.height) + 4)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: ceil(label.frame.width) + 28, height: height))
        label.frame.origin = NSPoint(x: 14, y: (height - label.frame.height) / 2)
        label.autoresizingMask = [.width]
        row.addSubview(label)
        item.view = row
        return item
    }

    private func setMenuBarTitle(_ title: String) {
        statusItem.button?.title = title
    }

    static func activationScheduleMenuItem(
        text: AppText,
        target: AnyObject?,
        action: Selector?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: text.activationScheduleAction, action: action, keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        item.target = target
        return item
    }

    @objc private func refreshClicked() {
        refreshLocal()
        refreshForecast(manual: true)
    }

    @MainActor
    @objc private func openActivationScheduleSettings() {
        if activationScheduleWindowController == nil {
            activationScheduleWindowController = ActivationScheduleWindowController(
                model: activationScheduleModel,
                textProvider: { [weak self] in self?.text ?? AppText.current }
            )
        }
        activationScheduleWindowController?.showWindowAndRefresh()
    }

    @MainActor
    @objc private func openDefaultModelSettings() {
        if defaultModelWindowController == nil {
            defaultModelWindowController = DefaultModelWindowController(textProvider: { [weak self] in self?.text ?? AppText.current })
        }
        defaultModelWindowController?.showWindowAndRefresh()
    }

    @MainActor
    @objc private func openScheduledMessageSettings() {
        if scheduledMessageWindowController == nil {
            scheduledMessageWindowController = ScheduledMessageWindowController(textProvider: { [weak self] in self?.text ?? AppText.current })
        }
        scheduledMessageWindowController?.showWindowAndRefresh()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func toggleWidgetServer() {
        if widgetPreferences.isServerEnabled {
            widgetPreferences.isServerEnabled = false
            cancelWidgetServerRetry()
            widgetServer?.stop()
            widgetServerState = .stopped
            renderCurrentState()
        } else {
            startWidgetServer()
        }
    }

    @objc private func copyWidgetAddress() {
        copyToPasteboard("http://\(LocalNetworkAddress.current()):\(WidgetServer.port)")
    }

    @objc private func copyWidgetToken() {
        do {
            copyToPasteboard(try ensureWidgetToken())
        } catch {
            widgetServerState = .failed
            renderCurrentState()
        }
    }

    @objc private func regenerateWidgetToken() {
        do {
            let token = try WidgetToken.generate()
            try widgetTokenStore.save(token)
            widgetTokenCache.replace(with: token)
        } catch {
            widgetServerState = .failed
        }
        renderCurrentState()
    }

    @MainActor
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selection = AppLanguage(rawValue: rawValue) else { return }
        languageSelection = selection
        languageSelection.save()
        activationScheduleWindowController?.updateLanguage()
        defaultModelWindowController?.updateLanguage()
        scheduledMessageWindowController?.updateLanguage()
        renderCurrentState()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        cancelWidgetServerRetry()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        activationScheduleWindowController?.close()
        defaultModelWindowController?.close()
        scheduledMessageWindowController?.close()
        widgetServer?.stop()
    }

    private func updateWidgetSnapshot(resetCelebrationActive: Bool) {
        let payload = WidgetPayloadBuilder.build(
            usage: lastSnapshot,
            tasks: lastTaskSnapshot,
            forecast: lastForecastSnapshot,
            resetCelebrationActive: resetCelebrationActive,
            generatedAt: Date()
        )
        if let data = try? JSONEncoder.widgetEncoder.encode(payload) {
            widgetSnapshotStore.replace(with: data)
        }
    }

    private func resetQuotaObservation(
        shortWindow: RateLimitWindow?,
        weeklyWindow: RateLimitWindow?
    ) -> ResetQuotaObservation? {
        guard let shortWindow,
              let shortResetsAt = shortWindow.resetsAt,
              let weeklyWindow,
              let weeklyResetsAt = weeklyWindow.resetsAt else {
            return nil
        }
        return ResetQuotaObservation(
            shortRemainingPercent: shortWindow.remainingPercent,
            shortResetsAt: shortResetsAt,
            weeklyRemainingPercent: weeklyWindow.remainingPercent,
            weeklyResetsAt: weeklyResetsAt
        )
    }

    private func startWidgetServer() {
        widgetPreferences.isServerEnabled = true
        do {
            let token = try ensureWidgetToken()
            widgetTokenCache.replace(with: token)
            if widgetServerState == .failed {
                widgetServer?.stop()
            }
            if widgetServer == nil {
                widgetServer = makeWidgetServer()
            }
            widgetServerState = .starting
            try widgetServer?.start()
        } catch {
            widgetServerState = .failed
            scheduleWidgetServerRetry()
        }
        renderCurrentState()
    }

    private func makeWidgetServer() -> WidgetServer {
        let tokenCache = widgetTokenCache
        let snapshotStore = widgetSnapshotStore
        return WidgetServer(
            tokenProvider: { tokenCache.current() },
            payloadProvider: { snapshotStore.current() },
            stateHandler: { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.widgetServerState = state
                    if state == .ready {
                        self.cancelWidgetServerRetry()
                    } else if state == .failed {
                        self.scheduleWidgetServerRetry()
                    }
                    self.renderCurrentState()
                }
            }
        )
    }

    private func ensureWidgetToken() throws -> String {
        if let existing = try widgetTokenStore.load(),
           existing.count == 64,
           existing.allSatisfy({
               ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
           }) {
            widgetTokenCache.replace(with: existing)
            return existing
        }
        let token = try WidgetToken.generate()
        try widgetTokenStore.save(token)
        widgetTokenCache.replace(with: token)
        return token
    }

    private func observeWorkspaceRecovery() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.retryWidgetServerIfNeeded(resetRetryBudget: true)
            })
        }
    }

    private func retryWidgetServerIfNeeded(resetRetryBudget: Bool = false) {
        guard widgetPreferences.isServerEnabled,
              widgetServerState != .ready,
              widgetServerState != .starting else { return }
        if resetRetryBudget {
            cancelWidgetServerRetry()
        }
        startWidgetServer()
    }

    private func scheduleWidgetServerRetry() {
        let delays: [TimeInterval] = [1, 3, 10]
        guard widgetPreferences.isServerEnabled,
              widgetRetryWorkItem == nil,
              widgetRetryAttempt < delays.count else { return }
        let delay = delays[widgetRetryAttempt]
        widgetRetryAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.widgetRetryWorkItem = nil
            self.retryWidgetServerIfNeeded()
        }
        widgetRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelWidgetServerRetry() {
        widgetRetryWorkItem?.cancel()
        widgetRetryWorkItem = nil
        widgetRetryAttempt = 0
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
