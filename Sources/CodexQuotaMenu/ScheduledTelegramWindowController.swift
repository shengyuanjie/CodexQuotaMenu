import AppKit

@MainActor
final class ScheduledTelegramWindowController: NSWindowController {
    private let enabled = NSButton(checkboxWithTitle: "通知未登记侧栏的新对话 / Notify new chats missing from Chats", target: nil, action: nil)
    private let token = NSSecureTextField()
    private let chat = NSTextField()
    private let proxy = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let bindButton = NSButton()
    private var bindingCode: String?
    private var bindingSince = Date()
    private let preferences = ScheduledTelegramPreferences()

    init() {
        let window = ScheduledMessageWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 410),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Telegram 通知 / Telegram Notifications"
        window.center()
        guard let content = window.contentView else { return }
        token.placeholderString = "Bot Token（留空保留已保存的 Token / Leave blank to keep saved token）"
        chat.placeholderString = "数字 Chat ID / Numeric recipient Chat ID"
        proxy.placeholderString = "留空跟随系统代理 / System proxy, or http://host:port / socks5://host:port"
        token.setAccessibilityLabel("Telegram Bot Token")
        chat.setAccessibilityLabel("Telegram Chat ID")
        proxy.setAccessibilityLabel("Telegram Proxy")
        let hint = NSTextField(wrappingLabelWithString: "通知包含任务 ID、模型和打开按钮，不含消息正文或附件。Token 保存在钥匙串；通知失败不会重发任务。\nNotifications include the chat ID, model and an open button. Tokens stay in Keychain; failures never resend the task.")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存 / Save", target: self, action: #selector(saveSettings))
        bindButton.title = "绑定收件人 / Bind recipient"
        bindButton.target = self; bindButton.action = #selector(bindRecipient)
        let buttons = NSStackView(views: [bindButton, NSView(), save])
        buttons.orientation = .horizontal; buttons.spacing = 12
        let views: [NSView] = [enabled, token, chat, proxy, hint, status, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
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
            status.stringValue = "已保存。后续符合条件的新对话将通知；历史记录不补发。 / Saved. Applies to future deliveries only."
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func bindRecipient() {
        if bindingCode == nil || Date().timeIntervalSince(bindingSince) > 300 {
            bindingSince = Date()
            bindingCode = "CQM-" + UUID().uuidString.prefix(8)
            bindButton.title = "读取绑定消息 / Read binding message"
            status.stringValue = "请在新机器人的私聊中发送：\(bindingCode!)\n然后点击“读取绑定消息”。 / Send this code to your bot, then read the binding message."
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
            status.stringValue = "正在读取绑定消息… / Reading binding message…"
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
                        self.bindButton.title = "绑定收件人 / Bind recipient"
                        self.status.stringValue = "收件人已识别，点击保存后启用通知。 / Recipient found. Save to enable notifications."
                    case .failure(let error): self.status.stringValue = error.localizedDescription
                    }
                }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
