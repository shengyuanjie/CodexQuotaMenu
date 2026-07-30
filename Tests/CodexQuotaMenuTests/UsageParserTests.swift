import XCTest
@testable import CodexQuotaMenu

final class UsageParserTests: XCTestCase {
    func testParsesBothWindowsAndCalculatesRemaining() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":35,"windowDurationMins":300,"resetsAt":1785307250},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1785900000},"planType":"plus"}}}"#
        let snapshot = try UsageParser.parse(Data(json.utf8), now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.headlineWindow?.remainingPercent, 65)
        XCTAssertEqual(snapshot.headlineWindow?.name, "5 小时用量")
        XCTAssertEqual(snapshot.plan, "plus")
    }

    func testRejectsResponseWithoutWindows() {
        let json = #"{"id":2,"result":{"rateLimits":{"planType":"plus"}}}"#
        XCTAssertThrowsError(try UsageParser.parse(Data(json.utf8)))
    }

    func testParsesRunningAndCompletedTasks() throws {
        let json = #"{"id":3,"result":{"data":[{"id":"run","name":"正在整理文件","preview":"","updatedAt":2000,"status":{"type":"notLoaded"},"path":"/tmp/run.jsonl"},{"id":"done","name":"生成付款申请","preview":"","updatedAt":1900,"status":{"type":"notLoaded"},"path":"/tmp/done.jsonl"}]}}"#
        let states: [String: TaskState] = [
            "/tmp/run.jsonl": .running,
            "/tmp/done.jsonl": .completed
        ]
        let snapshot = try TaskParser.parse(
            Data(json.utf8),
            now: Date(timeIntervalSince1970: 2_100),
            fileState: { path, _ in states[path] }
        )
        XCTAssertEqual(snapshot.running.map(\.title), ["正在整理文件"])
        XCTAssertEqual(snapshot.completed.map(\.title), ["生成付款申请"])
    }

    func testOmitsOldCompletedTasks() throws {
        let json = #"{"id":3,"result":{"data":[{"id":"old","name":"旧任务","preview":"","updatedAt":1,"status":{"type":"idle"},"path":"/tmp/old.jsonl"}]}}"#
        let snapshot = try TaskParser.parse(
            Data(json.utf8),
            now: Date(timeIntervalSince1970: 100_000),
            fileState: { _, _ in .completed }
        )
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testReadsCompletedMarkerFromRealJSONLFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"response_item","payload":{"type":"message"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .completed)
    }

    func testReadsRunningMarkerFromRealJSONLFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"task_complete"}}
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"response_item","payload":{"type":"reasoning"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .running)
    }

    func testDetectsPendingManualApproval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"approval-1","name":"exec","input":"{\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"允许？\\"}"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .waiting)
    }

    func testApprovalOutputReturnsTaskToRunning() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"approval-1","name":"exec","input":"{\\"sandbox_permissions\\":\\"require_escalated\\",\\"justification\\":\\"允许？\\"}"}}
        {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"approval-1","output":"approved"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .running)
    }

    func testUsesRuntimeWaitingFlagsWhenAvailable() throws {
        let json = #"{"id":3,"result":{"data":[{"id":"wait","name":"等待选择","preview":"","updatedAt":2000,"status":{"type":"active","activeFlags":["waitingOnUserInput"]},"path":"/tmp/wait.jsonl"}]}}"#
        let snapshot = try TaskParser.parse(
            Data(json.utf8),
            now: Date(timeIntervalSince1970: 2_100),
            fileState: { _, _ in nil }
        )
        XCTAssertEqual(snapshot.waiting.map(\.title), ["等待选择"])
        XCTAssertTrue(snapshot.running.isEmpty)
    }

    func testCompletedTurnThatRequestsInformationRemainsWaiting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"请提供联系人姓名和电话号码，我收到后继续处理。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .waiting)
    }

    func testRequestInEarlierFinalAnswerFragmentRemainsWaiting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"请上传付款申请表，我收到后继续处理。"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"支持 PDF 或图片格式。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .waiting)
    }

    func testRequestWithWordsBetweenPromptAndActionRemainsWaiting() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"请在下方列出的三个方案中选择一个，然后告诉我你的决定。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .waiting)
    }

    func testOrdinaryCompletedAnswerDoesNotWaitForReply() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"处理已经完成，文件保存在输出目录。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .completed)
    }

    func testCompletedStatementContainingActionWordDoesNotWait() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"表格已经填写完成，并上传到输出目录。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .completed)
    }

    func testInformationalDescriptionOfWaitingFeatureDoesNotWait() {
        let reply = "应用会判断本轮回复是否要求你提供、填写、选择或上传信息，并据此显示状态。"
        XCTAssertFalse(ReplyIntentClassifier.isWaitingForUser(fullReply: reply))
    }

    func testOptionalSuggestionDoesNotWait() {
        let reply = "你可以在菜单中选择“立即刷新”查看最新状态。如果还需要调整，我可以继续。"
        XCTAssertFalse(ReplyIntentClassifier.isWaitingForUser(fullReply: reply))
    }

    func testQuotedExampleDoesNotWait() {
        let reply = "误判示例是 `请上传文件并回复我`，该句只是用于解释判定规则。"
        XCTAssertFalse(ReplyIntentClassifier.isWaitingForUser(fullReply: reply))
    }

    func testDirectQuestionRequiresReply() {
        let reply = "目前有两种显示方案。你希望选择哪一种？两者都不会显示完成数量。"
        XCTAssertTrue(ReplyIntentClassifier.isWaitingForUser(fullReply: reply))
    }

    func testContinuationDependencyRequiresReply() {
        let reply = "资料上传后，我会继续生成安装包。"
        XCTAssertTrue(ReplyIntentClassifier.isWaitingForUser(fullReply: reply))
    }

    func testUserReplyClearsPreviousWaitingState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"请选择一个方案并回复。"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        {"type":"event_msg","payload":{"type":"user_message"}}
        {"type":"response_item","payload":{"type":"reasoning"}}
        """
        try Data(log.utf8).write(to: url)
        XCTAssertEqual(TaskParser.stateFromLog(path: url.path, now: Date()), .running)
    }
}
