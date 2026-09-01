import XCTest
@testable import CodexQuotaMenu

final class SyncPromptBuilderTests: XCTestCase {
    func testPromptIsSortedScopedAndUsesFixedConfiguration() throws {
        let entries = [
            ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 2)),
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0)),
            ActivationScheduleEntry(time: try ActivationTime(hour: 7, minute: 30), isEnabled: false)
        ]

        let prompt = try SyncPromptBuilder.build(
            entries: entries,
            timeZoneIdentifier: "Asia/Shanghai"
        )

        XCTAssertLessThan(
            prompt.range(of: "CodexQuotaMenu · 06:00")!.lowerBound,
            prompt.range(of: "CodexQuotaMenu · 11:02")!.lowerBound
        )
        XCTAssertFalse(prompt.contains("CodexQuotaMenu · 07:30"))
        XCTAssertTrue(prompt.contains("failed_runs_only"))
        XCTAssertTrue(prompt.contains("不要修改任何其他计划任务"))
        XCTAssertTrue(prompt.contains("standalone cron"))
        XCTAssertTrue(prompt.contains(ManagedAutomationPolicy.activationPrompt))
        XCTAssertTrue(prompt.contains("状态必须为 ACTIVE（启用）"))
        XCTAssertTrue(prompt.contains("将暂停任务恢复为 ACTIVE（启用）"))
        XCTAssertTrue(prompt.contains("CodexQuotaMenu · HH:mm"))
        XCTAssertTrue(prompt.contains("CodexQuotaMenu · backup"))
        XCTAssertTrue(prompt.contains("CodexQuotaMenu · 06:00 copy"))
        XCTAssertTrue(prompt.contains("保持不变"))
    }

    func testEmptyPromptDeletesManagedTasksOnly() throws {
        let prompt = try SyncPromptBuilder.build(entries: [], timeZoneIdentifier: "Asia/Shanghai")

        XCTAssertTrue(prompt.contains("期望时间列表为空"))
        XCTAssertTrue(prompt.contains("删除全部受管任务"))
        XCTAssertTrue(prompt.contains("仅删除名称完整且严格匹配"))
        XCTAssertTrue(prompt.contains("CodexQuotaMenu · backup"))
        XCTAssertTrue(prompt.contains("CodexQuotaMenu · 06:00 copy"))
        XCTAssertTrue(prompt.contains("不得删除、修改或合并"))
        XCTAssertFalse(prompt.contains("6点激活 Codex 用量窗口"))
    }
}
