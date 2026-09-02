import AppKit

enum ActivationScheduleSyncFeedback: Equatable {
    case none
    case applied
    case failed
    case unavailable
}

private final class ActivationScheduleCheckbox: NSButton {
    var representedObject: Any?
}

private final class ActivationScheduleDatePicker: NSDatePicker {
    var representedObject: Any?
}

private final class ActivationScheduleButton: NSButton {
    var representedObject: Any?
}

@MainActor
final class ActivationScheduleWindowController: NSWindowController, NSWindowDelegate {
    private let model: ActivationScheduleSettingsModel
    private let textProvider: () -> AppText
    private let nowProvider: @MainActor () -> Date
    private let calendarProvider: @MainActor () -> Calendar
    private let refreshInterval: TimeInterval
    private var refreshTimer: Timer?
    private var inlineError: String?
    private var suppressImmediateFocusRefresh = false

    private let headingLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let syncButton = NSButton(title: "", target: nil, action: nil)

    private(set) var syncFeedback = ActivationScheduleSyncFeedback.none

    var isRefreshTimerRunning: Bool { refreshTimer?.isValid == true }
    var refreshTimerInterval: TimeInterval? { refreshTimer?.timeInterval }
    var isSyncEnabled: Bool { syncButton.isEnabled }

    init(
        model: ActivationScheduleSettingsModel,
        textProvider: @escaping () -> AppText,
        refreshInterval: TimeInterval = 10,
        nowProvider: @escaping @MainActor () -> Date = Date.init,
        calendarProvider: @escaping @MainActor () -> Calendar = { .current }
    ) {
        self.model = model
        self.textProvider = textProvider
        self.refreshInterval = refreshInterval
        self.nowProvider = nowProvider
        self.calendarProvider = calendarProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        window.delegate = self
        window.center()
        buildViewHierarchy()
        model.stateDidChange = { [weak self] in
            self?.render()
        }
        render()
    }

    required init?(coder: NSCoder) { nil }

    func showWindowAndRefresh() {
        suppressImmediateFocusRefresh = true
        requestRefresh(clearFeedback: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        startRefreshTimer()
        DispatchQueue.main.async { [weak self] in
            self?.suppressImmediateFocusRefresh = false
        }
    }

    func updateLanguage() {
        render()
    }

    func refreshActualState() {
        requestRefresh(clearFeedback: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !suppressImmediateFocusRefresh {
            requestRefresh(clearFeedback: false)
        }
        startRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    @discardableResult
    func performSync() -> Bool {
        performSyncOperation { try model.synchronize() }
    }

    @discardableResult
    func performSync(timeZoneIdentifier: String) -> Bool {
        performSyncOperation {
            try model.synchronize(timeZoneIdentifier: timeZoneIdentifier)
        }
    }

    private func performSyncOperation(_ operation: () throws -> Void) -> Bool {
        guard model.loadError == nil else {
            syncFeedback = .unavailable
            render()
            return false
        }
        do {
            try operation()
            inlineError = nil
            syncFeedback = .applied
            render()
            return true
        } catch CodexAutomationSynchronizationError.recoveryRequired(let path) {
            syncFeedback = .failed
            inlineError = textProvider().activationRecoveryRequiredError(path: path)
            render()
            return false
        } catch {
            syncFeedback = .failed
            inlineError = nil
            render()
            return false
        }
    }

    private func requestRefresh(clearFeedback: Bool) {
        if clearFeedback {
            syncFeedback = .none
        }
        model.refreshActualState()
        render()
    }

    static func statusText(for state: AutomationSyncState, text: AppText) -> String {
        switch state {
        case .unconfigured:
            return text.activationUnconfiguredStatus
        case .synced:
            return text.activationSyncedStatus
        case .unavailable:
            return text.activationUnavailableDescription
        case .pending(let difference):
            var lines = [text.activationPendingStatus]
            appendDifference(
                difference.missing.map(\.displayValue),
                label: text.activationMissingDifferenceLabel,
                to: &lines
            )
            appendDifference(
                difference.extra.map(\.displayValue),
                label: text.activationExtraDifferenceLabel,
                to: &lines
            )
            appendDifference(
                difference.duplicate.map(\.displayValue),
                label: text.activationDuplicateDifferenceLabel,
                to: &lines
            )
            appendDifference(
                difference.paused.map(\.displayValue),
                label: text.activationPausedDifferenceLabel,
                to: &lines
            )
            appendDifference(
                difference.misconfigured.map(\.displayValue),
                label: text.activationMisconfiguredDifferenceLabel,
                to: &lines
            )
            appendDifference(
                difference.unmatchedNames,
                label: text.activationUnmatchedNamesDifferenceLabel,
                to: &lines
            )
            return lines.joined(separator: "\n")
        }
    }

    private static func appendDifference(_ values: [String], label: String, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(label): \(values.joined(separator: ", "))")
    }

    private func buildViewHierarchy() {
        guard let contentView = window?.contentView else { return }

        headingLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        errorLabel.maximumNumberOfLines = 0
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.textColor = .systemRed
        errorLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [headingLabel, emptyLabel, rowsStack, statusLabel, errorLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView

        let buttonBar = NSStackView(views: [addButton, NSView(), refreshButton, syncButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8

        addButton.target = self
        addButton.action = #selector(addTime)
        refreshButton.target = self
        refreshButton.action = #selector(manualRefresh)
        syncButton.target = self
        syncButton.action = #selector(syncToCodex)

        let rootStack = NSStackView(views: [scrollView, buttonBar])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            buttonBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -4),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -4),
            emptyLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            rowsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])
    }

    private func render() {
        let text = textProvider()
        window?.title = text.activationScheduleWindowTitle
        headingLabel.stringValue = text.activationScheduleHeading
        emptyLabel.stringValue = text.activationEmptyListDescription
        emptyLabel.isHidden = !model.entries.isEmpty
        addButton.title = text.addActivationTimeAction
        refreshButton.title = text.refreshActivationStatusAction
        syncButton.title = text.syncToCodexAction
        let canMutate = model.loadError == nil
        addButton.isEnabled = canMutate
        syncButton.isEnabled = canMutate
        if case .unavailable = model.syncState, model.loadError == nil {
            refreshButton.isHidden = false
        } else {
            refreshButton.isHidden = true
        }

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in model.entries {
            let row = makeRow(for: entry, text: text, isEnabled: canMutate)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        let actualStatus = model.loadError == nil
            ? Self.statusText(for: model.syncState, text: text)
            : text.activationCorruptStorageStatus
        statusLabel.stringValue = [actualStatus, feedbackText(text)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        errorLabel.stringValue = inlineError ?? ""
        errorLabel.isHidden = inlineError == nil
    }

    private func feedbackText(_ text: AppText) -> String {
        switch syncFeedback {
        case .none, .unavailable:
            return ""
        case .applied:
            return text.activationTasksAppliedStatus
        case .failed:
            return text.activationDirectSyncFailedStatus
        }
    }

    private func makeRow(
        for entry: ActivationScheduleEntry,
        text: AppText,
        isEnabled: Bool
    ) -> NSView {
        let checkbox = ActivationScheduleCheckbox(checkboxWithTitle: text.activationEnabledLabel, target: self, action: #selector(toggleEntry(_:)))
        checkbox.state = entry.isEnabled ? .on : .off
        checkbox.representedObject = entry.id
        checkbox.isEnabled = isEnabled

        let picker = ActivationScheduleDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = .hourMinute
        picker.dateValue = date(for: entry.time)
        picker.target = self
        picker.action = #selector(changeTime(_:))
        picker.representedObject = entry.id
        picker.isEnabled = isEnabled
        picker.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let delete = ActivationScheduleButton(title: text.deleteActivationTimeAction, target: self, action: #selector(deleteEntry(_:)))
        delete.representedObject = entry.id
        delete.isEnabled = isEnabled

        let spacer = NSView()
        let row = NSStackView(views: [checkbox, picker, spacer, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func date(for time: ActivationTime) -> Date {
        let calendar = calendarProvider()
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2001,
            month: 1,
            day: 1,
            hour: time.hour,
            minute: time.minute
        )) ?? nowProvider()
    }

    private func entryID(from representedObject: Any?) -> UUID? {
        representedObject as? UUID
    }

    @discardableResult
    private func handleMutation(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            inlineError = nil
            syncFeedback = .none
            render()
            return true
        } catch ActivationScheduleError.duplicateTime {
            inlineError = textProvider().duplicateActivationTimeError
        } catch {
            inlineError = textProvider().activationSaveFailedError
        }
        render()
        return false
    }

    @objc private func addTime() {
        guard model.loadError == nil else { return }
        let calendar = calendarProvider()
        let components = calendar.dateComponents([.hour, .minute], from: nowProvider())
        guard let hour = components.hour, let minute = components.minute else { return }
        let occupiedMinutes = Set(model.entries.map { $0.time.hour * 60 + $0.time.minute })
        let startingMinute = hour * 60 + minute
        guard let availableMinute = (0..<1_440)
            .map({ (startingMinute + $0) % 1_440 })
            .first(where: { !occupiedMinutes.contains($0) }),
              let time = try? ActivationTime(
                hour: availableMinute / 60,
                minute: availableMinute % 60
              ) else {
            inlineError = textProvider().activationScheduleFullError
            render()
            return
        }
        handleMutation { try model.add(time: time) }
    }

    @objc private func toggleEntry(_ sender: ActivationScheduleCheckbox) {
        guard let id = entryID(from: sender.representedObject),
              let entry = model.entries.first(where: { $0.id == id }) else { return }
        handleMutation {
            try model.update(id: id, time: entry.time, isEnabled: sender.state == .on)
        }
    }

    @objc private func changeTime(_ sender: ActivationScheduleDatePicker) {
        guard let id = entryID(from: sender.representedObject),
              let entry = model.entries.first(where: { $0.id == id }) else { return }
        let components = calendarProvider().dateComponents([.hour, .minute], from: sender.dateValue)
        guard let hour = components.hour,
              let minute = components.minute,
              let time = try? ActivationTime(hour: hour, minute: minute) else { return }
        handleMutation {
            try model.update(id: id, time: time, isEnabled: entry.isEnabled)
        }
    }

    @objc private func deleteEntry(_ sender: ActivationScheduleButton) {
        guard let id = entryID(from: sender.representedObject) else { return }
        handleMutation { try model.remove(id: id) }
    }

    @objc private func manualRefresh() {
        refreshActualState()
    }

    @objc private func syncToCodex() {
        performSync()
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.requestRefresh(clearFeedback: false)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

}
