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

    func testKeyWindowRefreshStartsTenSecondTimerAndCloseStopsIt() {
        let suite = "ActivationScheduleWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var readCount = 0
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount += 1; return .available([]) }
        )
        model.load()
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(controller.isRefreshTimerRunning)
        XCTAssertEqual(controller.refreshTimerInterval, 10)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(controller.isRefreshTimerRunning)
    }

    func testManualRefreshReadsActualAutomationState() {
        let suite = "ActivationScheduleWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var readCount = 0
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { readCount += 1; return .available([]) }
        )
        model.load()
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )

        controller.refreshActualState()

        XCTAssertEqual(readCount, 2)
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

    func testLongDifferenceStatusIsReachableInsideResizableScrollableWindow() throws {
        let suite = "ActivationScheduleWindowControllerTests.LongStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automations = (0..<48).map { index in
            CodexAutomation(
                id: "unmatched-\(index)",
                version: 1,
                kind: "cron",
                name: "\(ManagedAutomationPolicy.namePrefix)invalid-\(index)-\(String(repeating: "detail", count: 8))",
                prompt: ManagedAutomationPolicy.activationPrompt,
                status: "ACTIVE",
                rrule: "FREQ=DAILY;BYHOUR=0;BYMINUTE=0",
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
        let controller = ActivationScheduleWindowController(
            model: model,
            textProvider: { AppText(language: .english) },
            pasteboardWriter: { _ in true },
            urlOpener: { _ in true }
        )
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let statusView = try XCTUnwrap(findTextField(in: window.contentView) {
            $0.stringValue.contains("Unrecognized managed names: CodexQuotaMenu · invalid-0-")
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
