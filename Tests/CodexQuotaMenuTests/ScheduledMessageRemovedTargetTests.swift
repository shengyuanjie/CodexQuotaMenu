import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageRemovedTargetTests: XCTestCase {
    func testPreviewNewChatRecordsRemainReadableButNeverSend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root,
                                                  controller: RemovedTargetLaunchctl())
        // A previous attempt may already have saved a real chat ID. Both forms must stop.
        for threadID in ["", UUID().uuidString] {
            let original = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: threadID,
                threadTitle: "Old preview", model: "gpt-6-sol", message: "Do not send")
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            json["targetKind"] = "newChat"
            json["newTaskDirectory"] = "/unused/preview-directory"
            let legacy = try JSONDecoder().decode(ScheduledMessage.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertThrowsError(try legacy.validate())
            try store.write(legacy)
            XCTAssertEqual(try store.all().first(where: { $0.id == legacy.id })?.threadID, threadID.lowercased())
            var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
            runner.now = { legacy.fireDate }
            runner.resolveThread = { _ in XCTFail("Removed targets must not resolve a chat"); throw ScheduledMessageError.missingTask }
            runner.send = { _, _, _ in XCTFail("Removed targets must never send"); return true }
            XCTAssertEqual(runner.run(id: legacy.id), 1)
            let saved = try store.read(legacy.id)
            XCTAssertEqual(saved.state, .failed)
            XCTAssertEqual(saved.result, "new_task_removed")
            XCTAssertEqual(runner.run(id: legacy.id), 0)
            try scheduler.cancel(saved)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: legacy.id).path))
        }
    }
}

private final class RemovedTargetLaunchctl: LaunchctlControlling {
    func bootstrap(plistURL: URL) throws { XCTFail("Removed targets must not bootstrap") }
    func isLoaded(label: String) throws -> Bool { false }
    func loadedOwnedLabels() throws -> Set<String> { [] }
    func bootout(label: String) throws {}
}
