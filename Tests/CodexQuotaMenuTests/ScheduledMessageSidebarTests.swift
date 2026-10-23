import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageSidebarTests: XCTestCase {
    func testInteractiveListMembershipDoesNotCountAsDesktopRegistration() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let id = UUID().uuidString.lowercased()
        for (state, expected) in [([String: Any](), false), (["projectless-thread-ids": [id]], true),
                                  (["thread-project-assignments": [id: ["projectId": "project"]]], true)] {
            try JSONSerialization.data(withJSONObject: state).write(to: file)
            XCTAssertEqual(ScheduledMessageSidebar.isRegistered(id, stateURL: file), expected)
        }
        XCTAssertEqual(ScheduledMessageSidebar.chatURL(id)?.absoluteString, "codex://threads/\(id)")
        XCTAssertNil(ScheduledMessageSidebar.chatURL(""))
        XCTAssertNil(ScheduledMessageSidebar.chatURL("not-a-thread"))
    }

    func testCompletedDeliveryKeepsExactIDAndRecordsMissingRegistrationWithoutResending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let item = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: "",
            threadTitle: "New", model: "test-model", message: "hello", newTaskDirectory: root.path)
        try store.write(item)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: SidebarLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.telegramEnabled = { false }
        runner.now = { item.fireDate }
        runner.resolveEffort = { _, _, _ in "low" }
        runner.sidebarRegistration = { _ in false }
        let id = UUID().uuidString.lowercased()
        var calls = 0
        runner.sendNew = { _, _, _, created in
            calls += 1
            try created(id)
            return true
        }
        XCTAssertEqual(runner.run(id: item.id), 0)
        let saved = try store.read(item.id)
        XCTAssertEqual(saved.threadID, id)
        XCTAssertEqual(saved.state, .sent)
        XCTAssertEqual(saved.result, "turn_completed_sidebar_unregistered")
        XCTAssertEqual(runner.run(id: item.id), 0)
        XCTAssertEqual(calls, 1)
    }
}

private final class SidebarLaunchctl: LaunchctlControlling {
    func bootstrap(plistURL: URL) throws {}
    func isLoaded(label: String) throws -> Bool { false }
    func loadedOwnedLabels() throws -> Set<String> { [] }
    func bootout(label: String) throws {}
}
