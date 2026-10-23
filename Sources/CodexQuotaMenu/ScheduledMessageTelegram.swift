import Foundation
import Security
import LocalAuthentication

struct ScheduledTelegramError: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "background_credentials": return "Telegram 后台凭据检查未通过，通知可能无法发送。已保存的定时计划不受影响；可在 Telegram 设置中重新保存 Token 并处理授权。"
        case "credentials": return "无法读取 Telegram Token，请在通知设置中重新保存或完成钥匙串授权。"
        case "configuration": return "请填写有效的 Bot Token、数字 Chat ID 和代理地址。"
        case "binding": return "未找到唯一的近期绑定消息。请在新机器人的私聊中发送当前绑定码，然后再次读取。"
        case "rejected": return "Telegram 拒绝通知，请检查机器人、收件人和发送权限。"
        default: return "Telegram 通知未确认送达，请检查网络或代理；任务消息不会因此重发。"
        }
    }
}

struct ScheduledTelegramSettings: Codable, Equatable {
    var enabled = false
    var chatID = ""
    var proxyURL = ""

    func validate() throws {
        guard chatID.range(of: #"^-?[0-9]{1,20}$"#, options: .regularExpression) != nil else {
            throw ScheduledTelegramError(code: "configuration")
        }
        _ = try ScheduledTelegramClient.proxy(proxyURL)
    }
}

struct ScheduledTelegramPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private let key = "scheduledMessage.telegram"
    func load() -> ScheduledTelegramSettings {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(ScheduledTelegramSettings.self, from: data) else {
            return ScheduledTelegramSettings()
        }
        return settings
    }
    func save(_ settings: ScheduledTelegramSettings) throws {
        if settings.enabled { try settings.validate() }
        defaults.set(try JSONEncoder().encode(settings), forKey: key)
    }
}

struct ScheduledTelegramKeychain {
    var service = "com.local.codexquotamenu.telegram"
    var account = "bot-token"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func load(foreground: Bool = false) throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !foreground {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        let read = { () throws -> String in
            var value: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
                  let data = value as? Data, let token = String(data: data, encoding: .utf8),
                  ScheduledTelegramClient.validToken(token) else { throw ScheduledTelegramError(code: "credentials") }
            return token
        }
        if foreground { return try read() }
        return try ScheduledTelegramBackgroundAccess.read(read)
    }

    func save(_ token: String) throws {
        guard ScheduledTelegramClient.validToken(token) else { throw ScheduledTelegramError(code: "configuration") }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ScheduledTelegramError(code: "credentials") }
        } else if status != errSecSuccess { throw ScheduledTelegramError(code: "credentials") }
    }
}

enum ScheduledTelegramNotification: String, Codable {
    case sending, sent, failed
    var title: String {
        switch self {
        case .sending: return "Telegram 通知发送中或结果未确认"
        case .sent: return "Telegram 通知已发送"
        case .failed: return "Telegram 通知未确认送达（任务已完成，不会重发）"
        }
    }
}

struct ScheduledTelegramClient {
    static func validToken(_ token: String) -> Bool {
        token.range(of: #"^[0-9]+:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil
    }
    static func webURL(_ id: String) -> URL? {
        guard let id = UUID(uuidString: id)?.uuidString.lowercased() else { return nil }
        var parts = URLComponents(string: "https://chatgpt.com/codex/open-app")!
        parts.queryItems = [URLQueryItem(name: "codex_thread_id", value: id), URLQueryItem(name: "hostId", value: "local")]
        return parts.url
    }
    static func proxy(_ text: String) throws -> [AnyHashable: Any]? {
        if text.isEmpty { return nil }
        guard let url = URLComponents(string: text), let host = url.host, !host.isEmpty,
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw ScheduledTelegramError(code: "configuration")
        }
        switch url.scheme {
        case "http": return ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        case "socks5": return ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port, "SOCKSVersion": 5]
        default: throw ScheduledTelegramError(code: "configuration")
        }
    }
    static func body(for item: ScheduledMessage, chatID: String) throws -> [String: Any] {
        guard let link = webURL(item.threadID) else { throw ScheduledTelegramError(code: "configuration") }
        // Keep prompt, attachments, output and local paths out of external notifications.
        return ["chat_id": chatID,
                "text": "Codex 定时新对话已完成\n\n对话尚未登记到默认“聊天”侧栏，可点击下方按钮查看。\n任务 ID：\(item.threadID)\n模型：\(item.model) / \(item.effort ?? "auto")\n\n请在运行此任务的 Mac 上打开；若未唤起 Codex，请选择在系统浏览器中打开。",
                "link_preview_options": ["is_disabled": true],
                "reply_markup": ["inline_keyboard": [[ ["text": "打开 Codex 对话", "url": link.absoluteString] ]]]]
    }

    var transport: (URLRequest, String) throws -> (Data, Int) = perform
    func send(_ item: ScheduledMessage, settings: ScheduledTelegramSettings, token: String) throws {
        try settings.validate()
        guard Self.validToken(token) else { throw ScheduledTelegramError(code: "configuration") }
        let value = try call("sendMessage", body: Self.body(for: item, chatID: settings.chatID), token: token, proxyURL: settings.proxyURL)
        guard let result = value as? [String: Any], result["message_id"] is NSNumber else {
            throw ScheduledTelegramError(code: "rejected")
        }
    }

    func bindRecipient(code: String, since: Date, token: String, proxyURL: String) throws -> String {
        guard let updates = try call("getUpdates", body: ["timeout": 0, "limit": 100, "allowed_updates": ["message"]],
                                     token: token, proxyURL: proxyURL) as? [[String: Any]] else {
            throw ScheduledTelegramError(code: "rejected")
        }
        let matches = Set(updates.compactMap { row -> String? in
            guard let message = row["message"] as? [String: Any], message["text"] as? String == code,
                  let date = message["date"] as? Double, date >= since.timeIntervalSince1970 - 5,
                  date <= Date().timeIntervalSince1970 + 60,
                  let chat = message["chat"] as? [String: Any], chat["type"] as? String == "private",
                  let id = chat["id"] as? NSNumber,
                  let from = message["from"] as? [String: Any], (from["id"] as? NSNumber) == id else { return nil }
            return id.stringValue
        })
        guard matches.count == 1, let id = matches.first else { throw ScheduledTelegramError(code: "binding") }
        return id
    }

    private func call(_ method: String, body: [String: Any], token: String, proxyURL: String) throws -> Any {
        guard Self.validToken(token) else { throw ScheduledTelegramError(code: "configuration") }
        _ = try Self.proxy(proxyURL)
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Never surface URLSession errors: their URLs can include the secret Bot Token.
        let response: (Data, Int)
        do { response = try transport(request, proxyURL) }
        catch { throw ScheduledTelegramError(code: "network") }
        guard let value = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              response.1 == 200, value["ok"] as? Bool == true, let result = value["result"] else {
            throw ScheduledTelegramError(code: "rejected")
        }
        return result
    }

    static func perform(_ request: URLRequest, proxyURL: String) throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.connectionProxyDictionary = try proxy(proxyURL)
        let session = URLSession(configuration: config, delegate: ScheduledTelegramNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result = ScheduledTelegramHTTPResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            result.lock.lock(); defer { result.lock.unlock(); semaphore.signal() }
            if error == nil, let data, let response = response as? HTTPURLResponse {
                result.value = (data, response.statusCode)
            }
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 25) == .success else {
            task.cancel(); throw ScheduledTelegramError(code: "network")
        }
        result.lock.lock(); defer { result.lock.unlock() }
        guard let value = result.value else { throw ScheduledTelegramError(code: "network") }
        return value
    }
}

private final class ScheduledTelegramHTTPResult: @unchecked Sendable {
    let lock = NSLock()
    var value: (Data, Int)?
}
private final class ScheduledTelegramNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
