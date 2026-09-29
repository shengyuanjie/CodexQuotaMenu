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
    private let note = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    init(service: DefaultModelSettingsService = .init(), textProvider: @escaping () -> AppText) {
        self.service = service
        self.textProvider = textProvider
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 560, height: 560)
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
        refreshButton.title = t.modelText("刷新", "Refresh")
        saveButton.title = t.modelText("保存并核验", "Save and Verify")
        note.stringValue = t.modelText("用于以后创建的本机 Codex 会话。已打开的会话和定时激活设置不变。保存后如桌面端仍显示旧默认值，请在任务结束后重启 Codex。", "Applies to future local Codex chats. Existing chats and activation schedules stay unchanged. If the desktop app still shows old defaults, restart Codex after running tasks finish.")
        renderSnapshot()
    }

    private func buildView() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        currentLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)
        for label in [currentLabel, sourceLabel, note, feedback] {
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
        let stack = NSStackView(views: [heading, currentLabel, sourceLabel, grid, note, feedback, NSView(), buttons])
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
        for view in [currentLabel, sourceLabel, note, feedback, buttons] {
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
        currentLabel.stringValue = t.modelText("后端新会话默认：", "Backend defaults: ") + "\(selection.model) · \(selection.effort)"
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
    }

    @objc private func modelChanged() { populateEfforts(preferred: effortPicker.titleOfSelectedItem) }

    private func setBusy(_ value: Bool) {
        busy = value
        modelPicker.isEnabled = !value && snapshot != nil
        effortPicker.isEnabled = !value && snapshot != nil
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
        let selection = DefaultModelSelection(model: model, effort: effort)
        perform(saving: true) { try self.service.save(selection) }
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
            }
        }
    }
}
