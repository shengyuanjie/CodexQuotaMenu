import AppKit

extension AppText {
    var defaultModelAction: String { language == .simplifiedChinese ? "默认模型…" : "Default Model…" }
    func modelText(_ chinese: String, _ english: String) -> String { language == .simplifiedChinese ? chinese : english }
}

@MainActor
final class DefaultModelWindowController: NSWindowController {
    private let service: DefaultModelSettingsService
    private let textProvider: () -> AppText
    private var snapshot: DefaultModelSnapshot?
    private var busy = false
    private let queue = DispatchQueue(label: "CodexQuotaMenu.DefaultModelSettings", qos: .userInitiated)
    private let heading = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let effortLabel = NSTextField(labelWithString: "")
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fastToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let speedNote = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(service: DefaultModelSettingsService = .init(), textProvider: @escaping () -> AppText) {
        self.service = service
        self.textProvider = textProvider
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 560, height: 620)
        window.center()
        buildView()
        updateLanguage()
        setBusy(false)
    }
    required init?(coder: NSCoder) { nil }

    func showWindowAndRefresh() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !busy { refresh() }
    }

    func updateLanguage() {
        let t = textProvider()
        window?.title = t.modelText("Codex 默认模型", "Codex Default Model")
        heading.stringValue = t.modelText("新会话默认模型", "Defaults for new chats")
        modelLabel.stringValue = t.modelText("模型", "Model")
        effortLabel.stringValue = t.modelText("推理强度", "Reasoning effort")
        fastToggle.title = t.modelText("开启 1.5 倍速度（Fast）", "Enable 1.5× speed (Fast)")
        speedNote.stringValue = t.modelText("实际提速取决于模型和服务状态，可能增加用量消耗；不支持 Fast 的模型会禁用此选项。", "Actual speed depends on the model and service conditions and may consume more usage. This option is disabled for models without Fast support.")
        refreshButton.title = t.modelText("刷新", "Refresh")
        saveButton.title = t.modelText("保存并核验", "Save and Verify")
        note.stringValue = t.modelText("用于以后创建的本机 Codex 会话。已打开的会话和定时激活设置不变。保存并核验成功后，可选择现在重启 Codex 或稍后手动重启。", "Applies to future local Codex chats. Existing chats and activation schedules stay unchanged. After saving and verification, choose to restart Codex now or manually later.")
        renderSnapshot()
    }

    private func buildView() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        currentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        speedNote.textColor = .secondaryLabelColor
        speedNote.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        for label in [currentLabel, sourceLabel, speedNote, note, feedback] {
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        modelPicker.setAccessibilityLabel("Codex model")
        effortPicker.setAccessibilityLabel("Reasoning effort")
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let grid = NSGridView(views: [[modelLabel, modelPicker], [effortLabel, effortPicker]])
        grid.column(at: 0).width = 90
        grid.rowSpacing = 14
        modelPicker.widthAnchor.constraint(equalToConstant: 390).isActive = true
        let buttons = NSStackView(views: [spinner, NSView(), refreshButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [heading, currentLabel, sourceLabel, grid, fastToggle, speedNote, note, feedback, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
        for view in [currentLabel, sourceLabel, speedNote, note, feedback, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func renderSnapshot() {
        let t = textProvider()
        guard let snapshot else {
            currentLabel.stringValue = t.modelText("尚未读取默认值", "Defaults not loaded")
            sourceLabel.stringValue = ""
            return
        }
        let selection = snapshot.effective
        currentLabel.stringValue = t.modelText("后端新会话默认：", "Backend defaults: ") + "\(selection.model) · \(selection.effort) · " + (selection.fastEnabled
            ? t.modelText("1.5 倍速度：开启", "1.5× speed: On")
            : t.modelText("1.5 倍速度：关闭", "1.5× speed: Off"))
        sourceLabel.stringValue = snapshot.hasManagedOverride
            ? t.modelText("检测到系统/托管覆盖。修改本机系统默认值时，macOS 将请求管理员验证。", "Managed defaults are active. Updating local system defaults may require macOS administrator authentication.")
            : t.modelText("使用当前用户的 Codex 默认配置。", "Using your Codex user configuration.")
    }

    private func populate(_ value: DefaultModelSnapshot) {
        snapshot = value
        modelPicker.removeAllItems()
        for model in value.models {
            modelPicker.addItem(withTitle: model.name == model.id ? model.id : "\(model.name) — \(model.id)")
            modelPicker.lastItem?.representedObject = model.id
        }
        if let index = value.models.firstIndex(where: { $0.id == value.effective.model }) {
            modelPicker.selectItem(at: index)
        } else { modelPicker.select(nil) }
        fastToggle.state = value.effective.fastEnabled ? .on : .off
        populateEfforts(preferred: value.effective.effort)
        renderSnapshot()
    }

    private func populateEfforts(preferred: String?) {
        effortPicker.removeAllItems()
        guard let id = modelPicker.selectedItem?.representedObject as? String,
              let model = snapshot?.models.first(where: { $0.id == id }) else { return }
        effortPicker.addItems(withTitles: model.efforts)
        let effort = preferred.flatMap { model.efforts.contains($0) ? $0 : nil } ?? model.defaultEffort
        effortPicker.selectItem(withTitle: effort)
        fastToggle.isEnabled = !busy && model.supportsFast
        if !model.supportsFast { fastToggle.state = .off }
    }

    @objc private func modelChanged() { populateEfforts(preferred: effortPicker.titleOfSelectedItem) }

    private func setBusy(_ value: Bool) {
        busy = value
        modelPicker.isEnabled = !value && snapshot != nil
        effortPicker.isEnabled = !value && snapshot != nil
        fastToggle.isEnabled = !value && (snapshot?.models.first { $0.id == modelPicker.selectedItem?.representedObject as? String }?.supportsFast ?? false)
        refreshButton.isEnabled = !value
        saveButton.isEnabled = !value && snapshot != nil
        window?.standardWindowButton(.closeButton)?.isEnabled = !value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func refresh() {
        guard !busy else { return }
        perform(saving: false) { try self.service.load() }
    }

    @objc private func save() {
        guard !busy, let model = modelPicker.selectedItem?.representedObject as? String,
              let effort = effortPicker.titleOfSelectedItem else { return }
        let selection = DefaultModelSelection(model: model, effort: effort, serviceTier: fastToggle.state == .on ? "fast" : "default")
        perform(saving: true) { try self.service.save(selection) }
    }

    static func restartPrompt(text: AppText) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text.modelText("已保存并核验，是否现在重启 Codex？", "Saved and verified. Restart Codex now?")
        alert.informativeText = text.modelText("重启 Codex 后，新默认设置才能在桌面端生效。现在重启可能中断正在运行的任务，请先保存工作。也可以稍后手动重启；设置已保存。", "Restart Codex to apply the new defaults in the desktop app. Restarting now may interrupt running tasks; save your work first. You can also restart manually later; your settings are already saved.")
        alert.addButton(withTitle: text.modelText("现在重启 Codex", "Restart Codex Now"))
        alert.addButton(withTitle: text.modelText("稍后手动重启", "Restart Manually Later"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert
    }

    private func offerRestart() {
        guard let window else { return }
        Self.restartPrompt(text: textProvider()).beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.restartCodex()
            } else {
                self.feedback.stringValue = self.textProvider().modelText("设置已保存并核验；请稍后手动重启 Codex 使其生效。", "Settings saved and verified. Restart Codex manually later to apply them.")
            }
        }
    }

    private func restartCodex() {
        setBusy(true)
        feedback.stringValue = textProvider().modelText("设置已保存，正在重启 Codex…", "Settings saved. Restarting Codex…")
        Task { @MainActor in
            do {
                try await CodexDesktopRestarter().restart()
                feedback.textColor = .secondaryLabelColor
                feedback.stringValue = textProvider().modelText("设置已保存并核验，Codex 已重新启动。", "Settings saved and verified. Codex has relaunched.")
            } catch {
                feedback.textColor = .systemRed
                feedback.stringValue = textProvider().modelText("设置已保存并核验，但自动重启未完成。\n", "Settings saved and verified, but automatic restart did not finish.\n") + error.localizedDescription
            }
            setBusy(false)
        }
    }

    private func perform(saving: Bool, operation: @escaping () throws -> DefaultModelSnapshot) {
        setBusy(true)
        feedback.textColor = .secondaryLabelColor
        let t = textProvider()
        feedback.stringValue = saving
            ? t.modelText("正在保存并重新读取后端配置…", "Saving and reloading backend configuration…")
            : t.modelText("正在读取配置及可用模型…", "Reading configuration and available models…")
        queue.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    self.populate(value)
                    self.feedback.textColor = .secondaryLabelColor
                    self.feedback.stringValue = saving
                        ? self.textProvider().modelText("已保存，后端核验通过。", "Saved. Backend verification passed.") : ""
                case .failure(let error):
                    self.feedback.textColor = .systemRed
                    self.feedback.stringValue = error.localizedDescription
                }
                self.setBusy(false)
                if saving, case .success = result { self.offerRestart() }
            }
        }
    }
}
