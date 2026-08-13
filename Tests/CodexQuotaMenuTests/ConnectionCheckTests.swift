import Foundation
import XCTest
@testable import CodexQuotaMenu

final class ConnectionCheckTests: XCTestCase {
    func testFormatsSuccessfulConnectionSummaryWithoutAppKitState() {
        let usage = UsageSnapshot(
            windows: [RateLimitWindow(usedPercent: 10, durationMinutes: 300, resetsAt: nil)],
            plan: "plus",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
        let tasks = TaskSnapshot(
            tasks: [TaskInfo(
                id: "1",
                title: "测试",
                state: .running,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )],
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(
            ConnectionCheck.successMessage(
                usage: usage,
                tasks: tasks,
                text: AppText(language: .simplifiedChinese)
            ),
            "连接成功：5 小时用量：剩余 90%，正在执行 1"
        )
    }
}
