import AppKit
import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageNewChatTests: XCTestCase {
    func testNewChatPersistsIDAndNeverCreatesTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let item = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: "",
            threadTitle: "New chat", model: "test-model", message: "hello", effort: "high", newTaskDirectory: root.path)
        try item.validate()
        try store.write(item)
        XCTAssertTrue(try store.read(item.id).isNewTask)
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root, controller: NewChatLaunchctl())
        var runner = ScheduledMessageRunner(store: store, scheduler: scheduler)
        runner.now = { item.fireDate }
        runner.resolveThread = { _ in XCTFail("A new chat has no existing target"); throw ScheduledMessageError.missingTask }
        runner.resolveEffort = { _, requested, _ in try XCTUnwrap(requested) }
        let createdID = UUID().uuidString.lowercased()
        var calls = 0
        runner.sendNew = { message, target, effort, created in
            calls += 1
            XCTAssertTrue(message.threadID.isEmpty)
            XCTAssertEqual(target.directory.path, root.path)
            XCTAssertEqual(effort, "high")
            try created(createdID)
            XCTAssertEqual(try store.read(item.id).threadID, createdID)
            // A failure after creation must retain its ID and must never retry automatically.
            throw ScheduledMessageDeliveryError(code: "connection_failed")
        }
        XCTAssertEqual(runner.run(id: item.id), 1)
        let saved = try store.read(item.id)
        XCTAssertEqual(saved.threadID, createdID)
        XCTAssertEqual(saved.state, .failed)
        XCTAssertEqual(runner.run(id: item.id), 0)
        XCTAssertEqual(calls, 1)
    }

    func testNewChatCLIUsesFreshExecAndCapturesIDOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("fake-codex")
        let id = UUID().uuidString.lowercased()
        let item = ScheduledMessage(fireDate: Date().addingTimeInterval(3600), threadID: "",
            threadTitle: "New", model: "test-model", message: "hello", newTaskDirectory: root.path)
        for exitCode in [0, 1] {
            let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(root.path)/args'
            cat > '\(root.path)/prompt'
            printf '%s\\n' '{"type":"thread.started","thread_id":"\(id)"}' '{"type":"turn.completed"}'
            exit \(exitCode)
            """
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            var captured: [String] = []
            let result = Result { try ScheduledMessageRunner.runCodex(item, directory: root, effort: "high",
                executable: fake, timeout: 5, onThreadStarted: { captured.append($0) }) }
            if exitCode == 0 { XCTAssertTrue(try result.get()) }
            else { XCTAssertThrowsError(try result.get()) }
            XCTAssertEqual(captured, [id])
            let args = try String(contentsOf: root.appendingPathComponent("args")).split(separator: "\n").map(String.init)
            XCTAssertEqual(args, ["exec", "--cd", root.path, "--skip-git-repo-check", "--json", "--model",
                item.model, "--config", "model_reasoning_effort=\"high\"", "-"])
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prompt")), "hello")
        }
    }

    func testDefaultWorkspaceUsesDesktopLayoutAndAvoidsExistingChats() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ScheduledMessageWorkspace.defaultRoot(home: home)
        XCTAssertEqual(root.path, home.appendingPathComponent("Documents/Codex").path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let first = try ScheduledMessageWorkspace.create(root: root, message: "请开始", date: date, calendar: calendar)
        let second = try ScheduledMessageWorkspace.create(root: root, message: "请开始", date: date, calendar: calendar)
        XCTAssertEqual(first.path, root.appendingPathComponent("2026-10-24/new-chat").path)
        XCTAssertEqual(second.lastPathComponent, "new-chat-2")
        for folder in ["work", "outputs"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(folder).path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
        let named = try ScheduledMessageWorkspace.create(root: root, message: "Check my Swift app today please now", date: date, calendar: calendar)
        XCTAssertEqual(named.lastPathComponent, "check-my-swift-app-today-please")
    }

    @MainActor
    func testSelectingNewChatShowsDirectoryAndSwitchingBackRestoresID() throws {
        _ = NSApplication.shared
        let controller = ScheduledMessageWindowController(textProvider: { AppText(language: .simplifiedChinese) })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let views = descendants(try XCTUnwrap(controller.window?.contentView))
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("selectTask") })
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Target Codex chat ID" })
        let directory = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("chooseDirectory") })
        let id = UUID().uuidString.lowercased()
        ScheduledMessageWindowController.populateTaskMenu(picker, tasks: [(id, "Existing")], placeholder: "Choose")
        picker.selectItem(at: 1)
        picker.sendAction(picker.action!, to: picker.target)
        XCTAssertEqual(picker.titleOfSelectedItem, "新任务对话")
        XCTAssertTrue(field.isHidden)
        XCTAssertFalse(directory.isHidden)
        XCTAssertTrue(directory.title.contains("/Documents/Codex"))
        picker.selectItem(at: 2)
        picker.sendAction(picker.action!, to: picker.target)
        XCTAssertFalse(field.isHidden)
        XCTAssertTrue(directory.isHidden)
        XCTAssertEqual(field.stringValue, id)
    }
}

private final class NewChatLaunchctl: LaunchctlControlling {
    func bootstrap(plistURL: URL) throws {}
    func isLoaded(label: String) throws -> Bool { false }
    func loadedOwnedLabels() throws -> Set<String> { [] }
    func bootout(label: String) throws {}
}
