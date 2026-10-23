import AppKit

@MainActor
final class ScheduledTelegramWindowController: NSWindowController {
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let textProvider: () -> AppText
    private func text(_ zh: String, _ en: String) -> String { textProvider().modelText(zh, en) }
    private let token = NSSecureTextField()
    private let chat = NSTextField()
    private let proxy = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bindButton = NSButton()
    private var bindingCode: String?
    private var bindingSince = Date()
    private let preferences = ScheduledTelegramPreferences()

    init(textProvider: @escaping () -> AppText = { AppText(language: .simplifiedChinese) }) {
        self.textProvider = textProvider
        let window = ScheduledMessageWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = text("Telegram 通知", "Telegram Notifications")
        window.center()
        guard let content = window.contentView else { return }
        enabled.title = text("通知已完成、但未出现在聊天侧栏的新对话", "Notify completed new chats missing from Chats")
        token.placeholderString = text("粘贴 BotFather 提供的完整 Token", "Paste the full token from BotFather")
        chat.placeholderString = text("绑定后自动填写，无需手工查询", "Filled automatically after binding")
        proxy.placeholderString = text("通常留空；仅连接失败时按需填写", "Usually leave blank; set only if needed to connect")
        token.setAccessibilityLabel("Telegram Bot Token")
        chat.setAccessibilityLabel("Telegram Chat ID")
        proxy.setAccessibilityLabel("Telegram Proxy")
        bindButton.title = text("绑定收件人", "Bind recipient")
        bindButton.target = self; bindButton.action = #selector(bindRecipient)
        let recipientRow = NSStackView(views: [chat, bindButton])
        recipientRow.orientation = .horizontal; recipientRow.spacing = 10
        chat.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bindButton.setContentHuggingPriority(.required, for: .horizontal)
        bindButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.isSelectable = true
        status.setAccessibilityLabel("Telegram setup status")
        func section(_ title: String, input: NSView, help: String) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            let guide = NSTextField(wrappingLabelWithString: help)
            guide.font = .systemFont(ofSize: 12); guide.textColor = .secondaryLabelColor
            let group = NSStackView(views: [label, input, guide])
            group.orientation = .vertical; group.alignment = .leading; group.spacing = 6
            for view in [input, guide] { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
            return group
        }
        let tokenGroup = section(text("1. 机器人 Token", "1. Bot token"), input: token,
            help: text("首次使用先填写 Token；以后留空会保留已保存的 Token。", "Enter the token on first use. Leave blank later to keep the saved token."))
        let recipientGroup = section(text("2. 收件人（Chat ID）", "2. Recipient (Chat ID)"), input: recipientRow,
            help: text("点击“绑定收件人” → 把绑定码发到你的机器人私聊 → 回来点击“读取绑定消息”。识别成功后自动填写上框。", "Click Bind recipient → send the code in a private chat with your bot → return and click Read binding message. The ID above will be filled automatically."))
        let proxyGroup = section(text("3. 代理地址（可选）", "3. Proxy address (optional)"), input: proxy,
            help: text("先留空，使用 macOS 系统代理。只有连接失败且需要指定代理时才填写。\n例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890；端口以你的代理软件显示为准。", "Leave blank to use the macOS system proxy. Set this only if connection fails and a specific proxy is needed.\nExamples: http://127.0.0.1:7890 or socks5://127.0.0.1:7890. Use the port shown in your proxy app."))
        let hint = NSTextField(wrappingLabelWithString: text("通知只包含任务 ID、模型和打开按钮，不含消息正文或附件。Token 保存在钥匙串。", "Notifications include only the chat ID, model and open button, without prompts or attachments. Tokens stay in Keychain."))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let save = NSButton(title: text("保存并应用", "Save and apply"), target: self, action: #selector(saveSettings))
        let buttons = NSStackView(views: [NSView(), save])
        buttons.orientation = .horizontal; buttons.spacing = 12
        let views: [NSView] = [enabled, tokenGroup, recipientGroup, status, proxyGroup, hint, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let settings = preferences.load()
        enabled.state = settings.enabled ? .on : .off
        chat.stringValue = settings.chatID
        proxy.stringValue = settings.proxyURL
    }
    required init?(coder: NSCoder) { nil }

    @objc private func saveSettings() {
        let settings = ScheduledTelegramSettings(enabled: enabled.state == .on,
            chatID: chat.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyURL: proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            if settings.enabled {
                try settings.validate()
                let text = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { _ = try ScheduledTelegramKeychain().load(foreground: true) }
                else { try ScheduledTelegramKeychain().save(text) }
            }
            try preferences.save(settings)
            token.stringValue = ""
            status.stringValue = text("已保存。后续符合条件的新对话将通知；历史记录不补发。", "Saved. Applies to future deliveries only.")
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func bindRecipient() {
        if bindingCode == nil || Date().timeIntervalSince(bindingSince) > 300 {
            bindingSince = Date()
            bindingCode = "CQM-" + UUID().uuidString.prefix(8)
            bindButton.title = text("读取绑定消息", "Read binding message")
            status.stringValue = text("请把以下绑定码发到你的机器人私聊（可选中文字复制）：\n\(bindingCode!)\n发送后点击右侧“读取绑定消息”，最后点击“保存并应用”。", "Send this code in a private chat with your bot (select the text to copy):\n\(bindingCode!)\nThen click Read binding message, followed by Save and apply.")
            return
        }
        do {
            let entered = token.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = try entered.isEmpty ? ScheduledTelegramKeychain().load(foreground: true) : entered
            guard ScheduledTelegramClient.validToken(secret) else { throw ScheduledTelegramError(code: "configuration") }
            let address = proxy.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try ScheduledTelegramClient.proxy(address)
            let code = bindingCode!, since = bindingSince
            bindButton.isEnabled = false
            status.stringValue = text("正在读取绑定消息…", "Reading binding message…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try ScheduledTelegramClient().bindRecipient(code: code, since: since, token: secret, proxyURL: address) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.bindButton.isEnabled = true
                    switch result {
                    case .success(let id):
                        self.chat.stringValue = id
                        self.enabled.state = .on
                        self.bindingCode = nil
                        self.bindButton.title = self.text("绑定收件人", "Bind recipient")
                        self.status.stringValue = self.text("收件人已自动填写。点击“保存并应用”启用通知。", "Recipient filled in. Click Save and apply to enable notifications.")
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
