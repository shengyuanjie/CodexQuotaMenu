import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ActivationScheduleWindowControllerTests: XCTestCase {
    func testActivationScheduleMenuItemUsesLocalizedTitleAndSettingsShortcut() {
        let item = AppDelegate.activationScheduleMenuItem(
            text: AppText(language: .english),
            target: nil,
            action: nil
        )

        XCTAssertEqual(item.title, "Activation Times…")
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
    }

    func testSyncCopiesPromptAndOpensNewThreadWithoutClaimingSynced() throws {
        let (model, suite) = makeModel()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.load()
        try model.add(time: ActivationTime(hour: 6, minute: 0))
        var copied: String?
        var opened: URL?
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .simplifiedChinese) },
            pasteboardWriter: { copied = $0; return true },
            urlOpener: { opened = $0; return true }
        )

        XCTAssertTrue(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))

        XCTAssertTrue(copied?.contains("CodexQuotaMenu · 06:00") == true)
        XCTAssertEqual(opened?.absoluteString, "codex://threads/new")
        XCTAssertEqual(controller.lastGeneratedPrompt, copied)
        XCTAssertEqual(controller.syncFeedback, .copiedAndOpened)
        XCTAssertNotEqual(model.syncState, .synced)
    }

    func testPasteboardFailureKeepsGeneratedPromptAndDoesNotOpenCodex() throws {
        let (model, suite) = makeModel()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.load()
        try model.add(time: ActivationTime(hour: 7, minute: 30))
        var didTryToOpen = false
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in false },
            urlOpener: { _ in didTryToOpen = true; return true }
        )

        XCTAssertFalse(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))

        XCTAssertTrue(controller.lastGeneratedPrompt?.contains("CodexQuotaMenu · 07:30") == true)
        XCTAssertEqual(controller.syncFeedback, .pasteboardFailed)
        XCTAssertFalse(didTryToOpen)
        XCTAssertNotEqual(model.syncState, .synced)
    }

    func testCodexOpenFailureKeepsCopiedPromptAvailableForRetry() throws {
        let (model, suite) = makeModel()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.load()
        try model.add(time: ActivationTime(hour: 11, minute: 2))
        var copied: String?
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { copied = $0; return true },
            urlOpener: { _ in false }
        )

        XCTAssertFalse(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))

        XCTAssertEqual(controller.lastGeneratedPrompt, copied)
        XCTAssertEqual(controller.syncFeedback, .codexOpenFailed)
        XCTAssertNotEqual(model.syncState, .synced)
    }

    func testKeyWindowRefreshStartsTenSecondTimerAndCloseStopsIt() async {
        let suite = "ActivationScheduleWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let readCount = TestLockedCounter()
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount.increment(); return .available([]) }
        )
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        let refreshStarted = await waitUntil { readCount.value == 1 }
        XCTAssertTrue(refreshStarted)
        XCTAssertTrue(controller.isRefreshTimerRunning)
        XCTAssertEqual(controller.refreshTimerInterval, 10)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.isRefreshTimerRunning)
    }

    func testManualRefreshReadsActualAutomationState() async {
        let suite = "ActivationScheduleWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let readCount = TestLockedCounter()
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount.increment(); return .available([]) }
        )
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.refreshActualState()

        let refreshStarted = await waitUntil { readCount.value == 1 }
        XCTAssertTrue(refreshStarted)
    }

    func testOpenAndImmediateFocusEventDoNotStartDuplicateScans() async {
        let suite = "ActivationScheduleWindowControllerTests.Open.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let readCount = TestLockedCounter()
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount.increment(); return .available([]) }
        )
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.showWindowAndRefresh()
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        let refreshStarted = await waitUntil { readCount.value >= 1 }
        XCTAssertTrue(refreshStarted)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(readCount.value, 1)
        controller.close()
    }

    func testVisibleTimerInvokesAsyncRefresh() async {
        let suite = "ActivationScheduleWindowControllerTests.Timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let readCount = TestLockedCounter()
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount.increment(); return .available([]) }
        )
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true },
            refreshInterval: 0.02
        )
        controller.window?.orderFront(nil)

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        let timerRefreshStarted = await waitUntil(timeout: 1) { readCount.value >= 2 }
        XCTAssertTrue(timerRefreshStarted)
        controller.close()
    }

    func testAppliedAsyncScanRerendersStatusOnMainActor() async {
        let suite = "ActivationScheduleWindowControllerTests.AsyncRender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { .unavailable("fixture unavailable") }
        )
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.refreshActualState()

        let statusRerendered = await waitUntil {
            self.findTextField(in: controller.window?.contentView) {
                $0.stringValue == "Could not read Codex automation status. Try again later."
            } != nil
        }
        XCTAssertTrue(statusRerendered)
    }

    func testAddButtonChoosesFirstUnoccupiedMinuteWithMidnightWrap() throws {
        let suite = "ActivationScheduleWindowControllerTests.Add.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([
            ActivationScheduleEntry(time: ActivationTime(hour: 23, minute: 59)),
            ActivationScheduleEntry(time: ActivationTime(hour: 0, minute: 0))
        ])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()
        let (calendar, now) = fixedDate(hour: 23, minute: 59)
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true },
            nowProvider: { now },
            calendarProvider: { calendar }
        )
        let addButton = try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Add Time"))

        addButton.performClick(nil)

        XCTAssertEqual(model.entries.map(\.time.displayValue), ["00:00", "00:01", "23:59"])
        XCTAssertEqual(try store.load(), model.entries)
    }

    func testAddButtonShowsFullScheduleErrorWithoutChangingStorage() throws {
        let suite = "ActivationScheduleWindowControllerTests.Full.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivationScheduleStore(defaults: defaults)
        let entries = try (0..<1_440).map { minute in
            ActivationScheduleEntry(
                time: try ActivationTime(hour: minute / 60, minute: minute % 60)
            )
        }
        try store.save(entries)
        let storedData = try XCTUnwrap(
            defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data
        )
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()
        let (calendar, now) = fixedDate(hour: 12, minute: 34)
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true },
            nowProvider: { now },
            calendarProvider: { calendar }
        )
        let addButton = try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Add Time"))

        addButton.performClick(nil)

        XCTAssertEqual(model.entries.count, 1_440)
        XCTAssertEqual(
            defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data,
            storedData
        )
        XCTAssertNotNil(findTextField(in: controller.window?.contentView) {
            $0.stringValue == "All 1,440 daily minutes are already in use."
        })
    }

    func testEmptyValidListCanSyncButCorruptStorageCannot() {
        let validSuite = "ActivationScheduleWindowControllerTests.Valid.\(UUID().uuidString)"
        let validDefaults = UserDefaults(suiteName: validSuite)!
        defer { validDefaults.removePersistentDomain(forName: validSuite) }
        let validModel = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: validDefaults),
            readAutomations: { .available([]) }
        )
        validModel.load()
        let validController = ActivationScheduleWindowController(
            model: validModel,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )
        XCTAssertTrue(validController.isSyncEnabled)

        let corruptSuite = "ActivationScheduleWindowControllerTests.Corrupt.\(UUID().uuidString)"
        let corruptDefaults = UserDefaults(suiteName: corruptSuite)!
        defer { corruptDefaults.removePersistentDomain(forName: corruptSuite) }
        corruptDefaults.set(Data("not-json".utf8), forKey: ActivationScheduleStore.storageKey)
        let corruptModel = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: corruptDefaults),
            readAutomations: { .available([]) }
        )
        corruptModel.load()
        let corruptController = ActivationScheduleWindowController(
            model: corruptModel,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )
        XCTAssertFalse(corruptController.isSyncEnabled)
    }

    func testCorruptStorageDisablesEveryMutatingControl() throws {
        let suite = "ActivationScheduleWindowControllerTests.CorruptControls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
        ])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()
        defaults.set(Data("not-json".utf8), forKey: ActivationScheduleStore.storageKey)
        model.load()
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        XCTAssertFalse(try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Add Time")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Sync to Codex")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Delete")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Enabled")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(findDatePicker(in: controller.window?.contentView)).isEnabled)
        XCTAssertTrue(try XCTUnwrap(findButton(in: controller.window?.contentView, title: "Refresh Status")).isEnabled)
    }

    func testReopenAndManualRefreshClearFeedbackButKeepRetryPrompt() throws {
        let (model, suite) = makeModel()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.load()
        try model.add(time: ActivationTime(hour: 6, minute: 0))
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        XCTAssertTrue(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))
        let retryPrompt = try XCTUnwrap(controller.lastGeneratedPrompt)
        controller.refreshActualState()
        XCTAssertEqual(controller.syncFeedback, .none)
        XCTAssertEqual(controller.lastGeneratedPrompt, retryPrompt)

        XCTAssertTrue(controller.performSync(timeZoneIdentifier: "Asia/Shanghai"))
        controller.showWindowAndRefresh()
        XCTAssertEqual(controller.syncFeedback, .none)
        XCTAssertEqual(controller.lastGeneratedPrompt, retryPrompt)
        controller.close()
    }

    func testPendingStatusRendersEveryDifferenceCategory() throws {
        let difference = AutomationDifference(
            missing: [try ActivationTime(hour: 6, minute: 0)],
            extra: [try ActivationTime(hour: 7, minute: 30)],
            duplicate: [try ActivationTime(hour: 8, minute: 15)],
            paused: [try ActivationTime(hour: 9, minute: 45)],
            misconfigured: [try ActivationTime(hour: 10, minute: 5)],
            unmatchedNames: ["CodexQuotaMenu · invalid"]
        )

        let value = ActivationScheduleWindowController.statusText(
            for: .pending(difference),
            text: AppText(language: .english)
        )

        XCTAssertTrue(value.contains("Pending"))
        XCTAssertTrue(value.contains("Missing: 06:00"))
        XCTAssertTrue(value.contains("Extra: 07:30"))
        XCTAssertTrue(value.contains("Duplicate: 08:15"))
        XCTAssertTrue(value.contains("Paused: 09:45"))
        XCTAssertTrue(value.contains("Misconfigured: 10:05"))
        XCTAssertTrue(value.contains("Unrecognized managed names: CodexQuotaMenu · invalid"))
    }

    func testUnavailableStatusDoesNotExposeInternalReasonInEitherLanguage() {
        let internalReason = "managed automation parse failed at /private/internal/task.toml"

        let chinese = ActivationScheduleWindowController.statusText(
            for: .unavailable(internalReason),
            text: AppText(language: .simplifiedChinese)
        )
        let english = ActivationScheduleWindowController.statusText(
            for: .unavailable(internalReason),
            text: AppText(language: .english)
        )

        XCTAssertEqual(chinese, "无法读取 Codex 计划任务状态。请稍后重试。")
        XCTAssertEqual(english, "Could not read Codex automation status. Try again later.")
        XCTAssertFalse(chinese.contains(internalReason))
        XCTAssertFalse(english.contains(internalReason))
    }

    func testLongDifferenceStatusIsReachableInsideResizableScrollableWindow() async throws {
        let suite = "ActivationScheduleWindowControllerTests.LongStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automations = try (0..<480).map { index in
            let time = try ActivationTime(hour: index / 60, minute: index % 60)
            return CodexAutomation(
                id: "extra-\(index)",
                version: 1,
                kind: "cron",
                name: ManagedAutomationPolicy.name(for: time),
                prompt: ManagedAutomationPolicy.activationPrompt,
                status: "ACTIVE",
                rrule: "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute);TZID=Asia/Shanghai",
                model: ManagedAutomationPolicy.model,
                reasoningEffort: ManagedAutomationPolicy.reasoningEffort,
                notificationPolicy: ManagedAutomationPolicy.notificationPolicy,
                executionEnvironment: "local",
                targetType: "projectless"
            )
        }
        let store = ActivationScheduleStore(defaults: defaults)
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available(automations) }
        )
        model.load()
        let pendingApplied = await waitUntil {
            if case .pending = model.syncState { return true }
            return false
        }
        XCTAssertTrue(pendingApplied)
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let statusView = try XCTUnwrap(findTextField(in: window.contentView) {
            $0.stringValue.contains("Extra: 00:00, 00:01")
        })
        let scrollView = try XCTUnwrap(enclosingScrollView(of: statusView))
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.minSize.width, 420)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 320)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(documentView.fittingSize.height, scrollView.contentView.bounds.height)
        statusView.scrollToVisible(statusView.bounds)
        XCTAssertFalse(statusView.visibleRect.isEmpty)
    }

    func testUpdateLanguageRefreshesWindowCopy() {
        let (model, suite) = makeModel()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        model.load()
        var language = DisplayLanguage.simplifiedChinese
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: language) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )
        XCTAssertEqual(controller.window?.title, "激活时间设置")

        language = .english
        controller.updateLanguage()

        XCTAssertEqual(controller.window?.title, "Activation Times")
    }

    private func makeModel() -> (ActivationScheduleSettingsModel, String) {
        let suite = "ActivationScheduleWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (
            ActivationScheduleSettingsModel(
                store: ActivationScheduleStore(defaults: defaults),
                readAutomations: { .available([]) }
            ),
            suite
        )
    }

    private func findTextField(
        in view: NSView?,
        where predicate: (NSTextField) -> Bool
    ) -> NSTextField? {
        guard let view else { return nil }
        if let textField = view as? NSTextField, predicate(textField) {
            return textField
        }
        for subview in view.subviews {
            if let match = findTextField(in: subview, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func findButton(in view: NSView?, title: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let match = findButton(in: subview, title: title) { return match }
        }
        return nil
    }

    private func findDatePicker(in view: NSView?) -> NSDatePicker? {
        guard let view else { return nil }
        if let picker = view as? NSDatePicker { return picker }
        for subview in view.subviews {
            if let match = findDatePicker(in: subview) { return match }
        }
        return nil
    }

    private func fixedDate(hour: Int, minute: Int) -> (Calendar, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 1,
            hour: hour,
            minute: minute
        ))!
        return (calendar, date)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }

    private func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }
}

private final class TestLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}
