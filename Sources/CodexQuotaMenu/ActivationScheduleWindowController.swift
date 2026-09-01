import AppKit

enum ActivationScheduleSyncFeedback: Equatable {
    case none
    case copiedAndOpened
    case pasteboardFailed
    case codexOpenFailed
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
    typealias PasteboardWriter = @MainActor (String) -> Bool
    typealias URLOpener = @MainActor (URL) -> Bool

    private let model: ActivationScheduleSettingsModel
    private let textProvider: () -> AppText
    private let pasteboardWriter: PasteboardWriter
    private let urlOpener: URLOpener
    private var refreshTimer: Timer?
    private var inlineError: String?

    private let headingLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let syncButton = NSButton(title: "", target: nil, action: nil)

    private(set) var lastGeneratedPrompt: String?
    private(set) var syncFeedback = ActivationScheduleSyncFeedback.none

    var isRefreshTimerRunning: Bool { refreshTimer?.isValid == true }
    var refreshTimerInterval: TimeInterval? { refreshTimer?.timeInterval }
    var isSyncEnabled: Bool { syncButton.isEnabled }

    init(
        model: ActivationScheduleSettingsModel,
        textProvider: @escaping () -> AppText,
        pasteboardWriter: @escaping PasteboardWriter = ActivationScheduleWindowController.writePasteboard,
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) }
    ) {
        self.model = model
        self.textProvider = textProvider
        self.pasteboardWriter = pasteboardWriter
        self.urlOpener = urlOpener
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.center()
        buildViewHierarchy()
        render()
    }

    required init?(coder: NSCoder) { nil }

    func showWindowAndRefresh() {
        refreshActualState()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        startRefreshTimer()
    }

    func updateLanguage() {
        render()
    }

    func refreshActualState() {
        model.refreshActualState()
        render()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshActualState()
        startRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    @discardableResult
    func performSync(timeZoneIdentifier: String = TimeZone.current.identifier) -> Bool {
        guard model.loadError == nil,
              let prompt = try? model.makeSyncPrompt(timeZoneIdentifier: timeZoneIdentifier) else {
            syncFeedback = .unavailable
            render()
            return false
        }
        lastGeneratedPrompt = prompt

        guard pasteboardWriter(prompt) else {
            syncFeedback = .pasteboardFailed
            render()
            return false
        }
        guard let url = URL(string: "codex://threads/new"), urlOpener(url) else {
            syncFeedback = .codexOpenFailed
            render()
            return false
        }
        syncFeedback = .copiedAndOpened
        render()
        return true
    }

    static func statusText(for state: AutomationSyncState, text: AppText) -> String {
        switch state {
        case .unconfigured:
            return text.activationUnconfiguredStatus
        case .synced:
            return text.activationSyncedStatus
        case .unavailable(let reason):
            return "\(text.activationUnavailableStatus): \(reason)"
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
        errorLabel.maximumNumberOfLines = 0
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.textColor = .systemRed

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
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

        let rootStack = NSStackView(views: [headingLabel, emptyLabel, scrollView, statusLabel, errorLabel, buttonBar])
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            statusLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            buttonBar.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: rowsStack.heightAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            rowsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8)
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
        syncButton.isEnabled = model.loadError == nil

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for entry in model.entries {
            let row = makeRow(for: entry, text: text)
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
        case .copiedAndOpened:
            return text.activationPromptCopiedStatus
        case .pasteboardFailed:
            return text.activationPasteboardFailedStatus
        case .codexOpenFailed:
            return text.activationCodexOpenFailedStatus
        }
    }

    private func makeRow(for entry: ActivationScheduleEntry, text: AppText) -> NSView {
        let checkbox = ActivationScheduleCheckbox(checkboxWithTitle: text.activationEnabledLabel, target: self, action: #selector(toggleEntry(_:)))
        checkbox.state = entry.isEnabled ? .on : .off
        checkbox.representedObject = entry.id

        let picker = ActivationScheduleDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = .hourMinute
        picker.dateValue = date(for: entry.time)
        picker.target = self
        picker.action = #selector(changeTime(_:))
        picker.representedObject = entry.id
        picker.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let delete = ActivationScheduleButton(title: text.deleteActivationTimeAction, target: self, action: #selector(deleteEntry(_:)))
        delete.representedObject = entry.id

        let spacer = NSView()
        let row = NSStackView(views: [checkbox, picker, spacer, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func date(for time: ActivationTime) -> Date {
        Calendar.current.date(from: DateComponents(
            calendar: Calendar.current,
            timeZone: TimeZone.current,
            year: 2001,
            month: 1,
            day: 1,
            hour: time.hour,
            minute: time.minute
        )) ?? Date()
    }

    private func entryID(from representedObject: Any?) -> UUID? {
        representedObject as? UUID
    }

    private func handleMutation(_ operation: () throws -> Void) {
        do {
            try operation()
            inlineError = nil
            syncFeedback = .none
        } catch ActivationScheduleError.duplicateTime {
            inlineError = textProvider().duplicateActivationTimeError
        } catch {
            inlineError = textProvider().activationSaveFailedError
        }
        render()
    }

    @objc private func addTime() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let hour = components.hour,
              let minute = components.minute,
              let time = try? ActivationTime(hour: hour, minute: minute) else { return }
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
        let components = Calendar.current.dateComponents([.hour, .minute], from: sender.dateValue)
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
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.model.refreshActualState()
                self.render()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private static func writePasteboard(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}
