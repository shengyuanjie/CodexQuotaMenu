import AppKit

@MainActor
final class ScheduledMessageWindowController: NSWindowController, NSTextFieldDelegate {
    private let store = ScheduledMessageStore()
    private let scheduler = ScheduledMessageScheduler()
    private let textProvider: () -> AppText
    private var loading = false
    private var scheduling = false
    private var taskRows: [(id: String, title: String)] = []
    private var modelRows: [CodexModelOption] = []
    private var savedRows: [ScheduledMessage] = []

    private let taskPicker = NSPopUpButton()
    private let taskField = NSTextField()
    private let modelPicker = NSPopUpButton()
    private let effortPicker = NSPopUpButton()
    private let datePicker = NSDatePicker()
    private var timeAdjustmentButtons: [NSButton] = []
    private let messageView = ScheduledMessageTextView()
    private let savedPicker = NSPopUpButton()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let refreshButton = NSButton()
    private let heading = NSTextField(labelWithString: "")
    private let taskLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let effortLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let savedLabel = NSTextField(labelWithString: "")

    init(textProvider: @escaping () -> AppText) {
        self.textProvider = textProvider
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 600, height: 680)
        window.center()
        buildView()
        updateLanguage()
    }
    required init?(coder: NSCoder) { nil }

    func showWindowAndRefresh() {
        if window?.isVisible != true { resetSendTimeToNow() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refreshSaved()
        refreshOptions()
    }

    func updateLanguage() {
        let t = textProvider()
        window?.title = t.modelText("定时发送到任务", "Scheduled Message to Chat")
        heading.stringValue = t.modelText("指定日期发送一次", "Send once at the selected time")
        taskLabel.stringValue = t.modelText("目标任务", "Target chat")
        modelLabel.stringValue = t.modelText("模型", "Model")
        effortLabel.stringValue = t.modelText("推理强度", "Reasoning effort")
        dateLabel.stringValue = t.modelText("发送时间", "Send at")
        let timeTitles = [("−1分钟", "−1 min"), ("＋1分钟", "+1 min"),
                          ("−10分钟", "−10 min"), ("＋10分钟", "+10 min"),
                          ("−1小时", "−1 hour"), ("＋1小时", "+1 hour"),
                          ("−1天", "−1 day"), ("＋1天", "+1 day")]
        for (button, titles) in zip(timeAdjustmentButtons, timeTitles) {
            button.title = t.modelText(titles.0, titles.1)
            button.setAccessibilityLabel(button.title)
        }
        messageLabel.stringValue = t.modelText("消息内容", "Message")
        savedLabel.stringValue = t.modelText("已安排的消息", "Scheduled messages")
        taskField.placeholderString = t.modelText("任务 ID，也可从 codex://threads/ 链接粘贴", "Chat ID or codex://threads/ link")
        addButton.title = t.modelText("安排发送", "Schedule")
        removeButton.title = t.modelText("取消所选", "Remove selected")
        refreshButton.title = t.modelText("刷新", "Refresh")
    }

    private func buildView() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        feedback.textColor = .secondaryLabelColor
        feedback.maximumNumberOfLines = 0
        taskPicker.target = self; taskPicker.action = #selector(selectTask)
        taskPicker.addItem(withTitle: "…")
        taskField.setAccessibilityLabel("Target Codex chat ID")
        taskField.delegate = self
        savedPicker.target = self; savedPicker.action = #selector(showSavedDetails)
        modelPicker.addItem(withTitle: "…")
        modelPicker.target = self; modelPicker.action = #selector(modelChanged)
        effortPicker.setAccessibilityLabel("Scheduled message reasoning effort")
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        resetSendTimeToNow()
        let timeRow = NSStackView(views: [datePicker])
        timeRow.orientation = .horizontal; timeRow.alignment = .centerY; timeRow.spacing = 12
        for offsets in [[-1, 1], [-10, 10], [-60, 60], [-1440, 1440]] {
            let pair = NSStackView()
            pair.orientation = .vertical; pair.alignment = .leading; pair.spacing = 3
            for offset in offsets {
                let button = NSButton(title: "", target: self, action: #selector(adjustSendTime(_:)))
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 12)
                button.tag = offset
                timeAdjustmentButtons.append(button)
                pair.addArrangedSubview(button)
            }
            timeRow.addArrangedSubview(pair)
        }
        messageView.isRichText = false
        messageView.allowsUndo = true
        messageView.font = .systemFont(ofSize: 13)
        messageView.setAccessibilityLabel("Scheduled message text")
        messageView.frame = NSRect(x: 0, y: 0, width: 580, height: 140)
        messageView.isVerticallyResizable = true
        messageView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = messageView
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        addButton.target = self; addButton.action = #selector(schedule)
        removeButton.target = self; removeButton.action = #selector(remove)
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        let buttons = NSStackView(views: [refreshButton, NSView(), removeButton, addButton])
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [heading, taskLabel, taskPicker, taskField, modelLabel,
                                        modelPicker, effortLabel, effortPicker, dateLabel, timeRow, messageLabel, scroll,
                                        savedLabel, savedPicker, feedback, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        for view in [taskPicker, taskField, modelPicker, effortPicker, scroll, savedPicker, feedback, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func resetSendTimeToNow() {
        let now = Date()
        datePicker.minDate = now
        datePicker.maxDate = now.addingTimeInterval(365 * 86_400)
        datePicker.dateValue = now
    }

    @objc private func adjustSendTime(_ sender: NSButton) {
        let now = Date()
        datePicker.minDate = now
        datePicker.maxDate = now.addingTimeInterval(365 * 86_400)
        // Calendar days retain the local clock time across daylight-saving transitions.
        let isDay = abs(sender.tag) == 1440
        guard let adjusted = Calendar.current.date(byAdding: isDay ? .day : .minute,
            value: isDay ? sender.tag / 1440 : sender.tag, to: datePicker.dateValue) else { return }
        let latest = datePicker.maxDate ?? now.addingTimeInterval(365 * 86_400)
        datePicker.dateValue = min(max(adjusted, now), latest)
        feedback.stringValue = adjusted < now
            ? textProvider().modelText("发送时间不能早于当前时间。", "The send time cannot be earlier than now.")
            : adjusted > latest
                ? textProvider().modelText("发送时间不能超过未来一年。", "The send time must be within the next year.") : ""
    }

    @objc private func selectTask() {
        if let id = taskPicker.selectedItem?.representedObject as? String { taskField.stringValue = id }
        else { taskField.stringValue = "" }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === taskField else { return }
        selectTaskMenu(id: Self.canonicalTaskID(taskField.stringValue))
    }

    static func canonicalTaskID(_ entered: String) -> String {
        let value = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = value.components(separatedBy: "codex://threads/").last?.components(separatedBy: "?").first ?? value
        return UUID(uuidString: raw)?.uuidString.lowercased() ?? raw
    }

    static func populateTaskMenu(_ picker: NSPopUpButton, tasks: [(id: String, title: String)], placeholder: String) {
        picker.removeAllItems()
        picker.menu?.addItem(NSMenuItem(title: placeholder, action: nil, keyEquivalent: ""))
        var seen = Set<String>()
        for task in tasks where seen.insert(task.id).inserted {
            let item = NSMenuItem(title: "\(task.title.prefix(70)) · \(task.id.suffix(8))", action: nil, keyEquivalent: "")
            item.representedObject = task.id
            item.toolTip = "\(task.title)\n\(task.id)"
            picker.menu?.addItem(item)
        }
    }

    private func selectTaskMenu(id: String) {
        let index = taskPicker.itemArray.firstIndex { ($0.representedObject as? String) == id } ?? 0
        taskPicker.selectItem(at: index)
    }

    @objc private func refresh() { refreshSaved(); refreshOptions() }

    private func refreshOptions() {
        guard !loading else { return }
        let selectedModel = modelRows.indices.contains(modelPicker.indexOfSelectedItem)
            ? modelRows[modelPicker.indexOfSelectedItem].id : nil
        let selectedEffort = effortPicker.titleOfSelectedItem
        loading = true
        addButton.isEnabled = false
        feedback.stringValue = textProvider().modelText("正在读取任务与模型…", "Loading chats and models…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> ([(String, String)], [CodexModelOption]) in
                let rows = try CodexClient().modelRequest("thread/list", params: ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "useStateDbOnly": true])
                let tasks = (rows["data"] as? [[String: Any]] ?? []).compactMap { row -> (String, String)? in
                    guard let id = row["id"] as? String, row["canAcceptDirectInput"] as? Bool != false else { return nil }
                    let title = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? (row["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                    return (id, title.components(separatedBy: .newlines)[0])
                }
                return (tasks, try DefaultModelSettingsService().load().models)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                self.addButton.isEnabled = !self.scheduling
                switch result {
                case .success(let (tasks, models)):
                    self.taskRows = tasks; self.modelRows = models
                    Self.populateTaskMenu(self.taskPicker, tasks: tasks,
                        placeholder: self.textProvider().modelText("选择最近任务…", "Choose a recent chat…"))
                    self.selectTaskMenu(id: Self.canonicalTaskID(self.taskField.stringValue))
                    self.modelPicker.removeAllItems()
                    models.forEach { self.modelPicker.addItem(withTitle: $0.name == $0.id ? $0.id : "\($0.name) — \($0.id)") }
                    if let selectedModel, let index = models.firstIndex(where: { $0.id == selectedModel }) {
                        self.modelPicker.selectItem(at: index)
                    }
                    self.populateEfforts(preferred: selectedEffort)
                    self.feedback.stringValue = ""
                case .failure(let error): self.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func modelChanged() { populateEfforts(preferred: effortPicker.titleOfSelectedItem) }

    private func populateEfforts(preferred: String?) {
        effortPicker.removeAllItems()
        guard modelRows.indices.contains(modelPicker.indexOfSelectedItem) else { return }
        let model = modelRows[modelPicker.indexOfSelectedItem]
        effortPicker.addItems(withTitles: model.efforts)
        let selected = preferred.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.defaultEffort
        if model.efforts.contains(selected) { effortPicker.selectItem(withTitle: selected) }
    }

    private func refreshSaved() {
        do {
            savedRows = try store.all()
            savedPicker.removeAllItems()
            let format = DateFormatter(); format.dateStyle = .short; format.timeStyle = .short
            for item in savedRows {
                let row = NSMenuItem(title: "\(format.string(from: item.fireDate)) · \(item.threadTitle.prefix(35)) · \(item.state.rawValue) · \(item.id.uuidString.suffix(6))", action: nil, keyEquivalent: "")
                row.representedObject = item.id
                row.toolTip = "\(item.threadTitle)\n\(item.threadID)\n\(item.model) / \(item.effort ?? "auto")\n\(item.result ?? "pending")"
                savedPicker.menu?.addItem(row)
            }
            removeButton.isEnabled = !savedRows.isEmpty
        } catch { feedback.stringValue = error.localizedDescription }
    }

    @objc private func schedule() {
        guard !loading, !scheduling else { return }
        let id = Self.canonicalTaskID(taskField.stringValue)
        if let selectedID = taskPicker.selectedItem?.representedObject as? String, selectedID != id {
            feedback.stringValue = textProvider().modelText("目标任务与任务 ID 不一致，请重新选择。", "Selected chat and chat ID do not match. Select the chat again.")
            return
        }
        let modelIndex = modelPicker.indexOfSelectedItem
        guard modelRows.indices.contains(modelIndex) else { feedback.stringValue = ScheduledMessageError.invalidInput.localizedDescription; return }
        guard let effort = effortPicker.titleOfSelectedItem, modelRows[modelIndex].efforts.contains(effort) else {
            feedback.stringValue = ScheduledMessageError.invalidInput.localizedDescription; return
        }
        let title = taskRows.first(where: { $0.id == id })?.title ?? id
        let item = ScheduledMessage(fireDate: datePicker.dateValue, threadID: id, threadTitle: title,
                                    model: modelRows[modelIndex].id, message: messageView.string, effort: effort)
        do { try item.validate() } catch { feedback.stringValue = error.localizedDescription; return }
        scheduling = true
        addButton.isEnabled = false
        feedback.stringValue = textProvider().modelText("正在核对目标任务…", "Checking target chat…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> Void in
                _ = try ScheduledMessageRunner().resolveThread(id)
                try ScheduledMessageScheduler().schedule(item)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduling = false
                self.addButton.isEnabled = !self.loading
                switch result {
                case .success:
                    self.feedback.stringValue = self.textProvider().modelText("已安排一次发送。", "One-time delivery scheduled.")
                    if self.messageView.string == item.message { self.messageView.string = "" }
                    self.refreshSaved()
                case .failure(let error): self.feedback.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func showSavedDetails() {
        guard let id = savedPicker.selectedItem?.representedObject as? UUID,
              let item = savedRows.first(where: { $0.id == id }) else { return }
        feedback.stringValue = "\(item.threadTitle)\n\(item.threadID) · \(item.model) / \(item.effort ?? "auto")\n\(item.result.map { ScheduledMessageDeliveryError(code: $0).localizedDescription } ?? item.state.rawValue)"
    }

    @objc private func remove() {
        guard let id = savedPicker.selectedItem?.representedObject as? UUID,
              let index = savedRows.firstIndex(where: { $0.id == id }) else { return }
        do {
            try scheduler.cancel(savedRows[index])
            feedback.stringValue = textProvider().modelText("已移除。", "Removed.")
            refreshSaved()
        } catch { feedback.stringValue = error.localizedDescription }
    }
}

// Accessory apps have no standard Edit menu to dispatch these key equivalents.
private final class ScheduledMessageTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command || modifiers == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == .command {
            switch key {
            case "v" where isEditable: paste(nil); return true
            case "x" where isEditable: cut(nil); return true
            case "c": copy(nil); return true
            case "a": selectAll(nil); return true
            case "z" where undoManager?.canUndo == true: undoManager?.undo(); return true
            default: break
            }
        } else if key == "z", undoManager?.canRedo == true {
            undoManager?.redo(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
