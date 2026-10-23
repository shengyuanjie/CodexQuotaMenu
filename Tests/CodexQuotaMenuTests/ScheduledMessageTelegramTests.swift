import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageTelegramTests: XCTestCase {
    func testPayloadUsesHTTPButtonAndExcludesPromptPathsAndAttachments() throws {
        let id = UUID().uuidString.lowercased()
        let item = ScheduledMessage(fireDate: Date(), threadID: id, threadTitle: "private title",
            model: "test-model", message: "private prompt", effort: "low", newTaskDirectory: "/private/work")
        let body = try ScheduledTelegramClient.body(for: item, chatID: "123")
        let data = try JSONSerialization.data(withJSONObject: body)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["private title", "private prompt", "/private/work"] { XCTAssertFalse(text.contains(secret)) }
        let markup = try XCTUnwrap(body["reply_markup"] as? [String: Any])
        let rows = try XCTUnwrap(markup["inline_keyboard"] as? [[[String: String]]])
        let url = try XCTUnwrap(URLComponents(string: try XCTUnwrap(rows.first?.first?["url"])))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "chatgpt.com")
        XCTAssertEqual(url.path, "/codex/open-app")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "codex_thread_id" })?.value, id)
        XCTAssertNil(ScheduledTelegramClient.webURL("../invalid"))
    }

    func testRequestRequiresConfirmedTelegramMessageAndRedactsTransportErrors() throws {
        let item = ScheduledMessage(fireDate: Date(), threadID: UUID().uuidString, threadTitle: "test", model: "test", message: "secret")
        let token = "123:" + String(repeating: "x", count: 25)
        let settings = ScheduledTelegramSettings(enabled: true, chatID: "456", proxyURL: "http://127.0.0.1:7890")
        var calls = 0
        var client = ScheduledTelegramClient()
        client.transport = { request, proxy in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "api.telegram.org")
            XCTAssertEqual(proxy, settings.proxyURL)
            return (Data(#"{"ok":true,"result":{"message_id":8}}"#.utf8), 200)
        }
        try client.send(item, settings: settings, token: token)
        XCTAssertEqual(calls, 1)
        client.transport = { _, _ in throw NSError(domain: token, code: 1) }
        XCTAssertThrowsError(try client.send(item, settings: settings, token: token)) {
            XCTAssertFalse($0.localizedDescription.contains(token))
        }
        for response in [#"{"ok":false,"description":"secret"}"#, #"{"ok":true,"result":{}}"#, "not json"] {
            client.transport = { _, _ in (Data(response.utf8), 200) }
            XCTAssertThrowsError(try client.send(item, settings: settings, token: token))
        }
    }

    func testBindingAcceptsOnlyUniqueRecentPrivateMessageWithExactCode() throws {
        let since = Date()
        let token = "123:" + String(repeating: "x", count: 25)
        func row(id: Int, text: String = "CQM-12345678", age: Double = 0, type: String = "private") -> [String: Any] {
            ["message": ["text": text, "date": since.timeIntervalSince1970 + age,
                "chat": ["id": id, "type": type], "from": ["id": id]]]
        }
        var updates = [row(id: 123), row(id: 999, text: "unrelated"), row(id: 999, age: -600), row(id: 999, type: "group")]
        var client = ScheduledTelegramClient()
        client.transport = { request, _ in
            XCTAssertTrue(request.url?.path.hasSuffix("/getUpdates") == true)
            return (try JSONSerialization.data(withJSONObject: ["ok": true, "result": updates]), 200)
        }
        XCTAssertEqual(try client.bindRecipient(code: "CQM-12345678", since: since, token: token, proxyURL: ""), "123")
        updates.append(row(id: 456))
        XCTAssertThrowsError(try client.bindRecipient(code: "CQM-12345678", since: since, token: token, proxyURL: ""))
        updates = [row(id: 999, age: -600), row(id: 999, type: "group"), row(id: 999, text: "wrong")]
        XCTAssertThrowsError(try client.bindRecipient(code: "CQM-12345678", since: since, token: token, proxyURL: ""))
    }

    func testConfigDefaultsDisabledAndContainsNoToken() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ScheduledTelegramPreferences(defaults: defaults)
        XCTAssertFalse(preferences.load().enabled)
        let settings = ScheduledTelegramSettings(enabled: true, chatID: "-123", proxyURL: "socks5://localhost:7890")
        try preferences.save(settings)
        XCTAssertEqual(preferences.load(), settings)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).lowercased().contains("bot-token"))
        for proxy in ["https://example.com", "http://user:password@localhost:80", "http://localhost:80/?token=secret"] {
            XCTAssertThrowsError(try ScheduledTelegramClient.proxy(proxy))
        }
        XCTAssertThrowsError(try ScheduledTelegramSettings(enabled: true, chatID: "@unbound").validate())
    }

    func testNotificationFailureNeverChangesSuccessfulDeliveryOrRetriesOnRestart() throws {
        try verifyRun(enabled: true, registered: false, notificationFails: true, expected: .failed)
        try verifyRun(enabled: true, registered: false, notificationFails: false, expected: .sent)
    }

    func testDisabledRegisteredAndFailedChatsDoNotNotify() throws {
        try verifyRun(enabled: false, registered: false, notificationFails: false, expected: nil)
        try verifyRun(enabled: true, registered: true, notificationFails: false, expected: nil)
        try verifyRun(enabled: true, registered: false, notificationFails: false, expected: nil, completed: false)
    }

    private func verifyRun(enabled: Bool, registered: Bool, notificationFails: Bool,
                           expected: ScheduledTelegramNotification?, completed: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let item = ScheduledMessage(fireDate: Date().addingTimeInterval(60), threadID: "", threadTitle: "new",
            model: "test", message: "secret", newTaskDirectory: root.path)
        try store.write(item)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: TelegramTestLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { item.fireDate }
        runner.resolveEffort = { _, _, _ in "low" }
        runner.sidebarRegistration = { _ in registered }
        runner.telegramEnabled = { enabled }
        var deliveries = 0
        var notices = 0
        runner.sendNew = { _, _, _, created in
            deliveries += 1
            try created(UUID().uuidString.lowercased())
            return completed
        }
        runner.notifyTelegram = { message in
            notices += 1
            let saved = try store.read(message.id)
            XCTAssertEqual(saved.state, .sent)
            XCTAssertEqual(saved.telegramNotification, .sending)
            // Concurrent invocations cannot start the task or notification again.
            XCTAssertEqual(runner.run(id: item.id), 0)
            if notificationFails { throw ScheduledTelegramError(code: "network") }
        }
        XCTAssertEqual(runner.run(id: item.id), completed ? 0 : 1)
        let saved = try store.read(item.id)
        XCTAssertEqual(saved.state, completed ? .sent : .failed)
        XCTAssertEqual(saved.telegramNotification, expected)
        XCTAssertEqual(notices, expected == nil ? 0 : 1)
        XCTAssertEqual(runner.run(id: item.id), 0)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(notices, expected == nil ? 0 : 1)
    }
}

private final class TelegramTestLaunchctl: LaunchctlControlling {
    func bootstrap(plistURL: URL) throws {}
    func isLoaded(label: String) throws -> Bool { false }
    func loadedOwnedLabels() throws -> Set<String> { [] }
    func bootout(label: String) throws {}
}
