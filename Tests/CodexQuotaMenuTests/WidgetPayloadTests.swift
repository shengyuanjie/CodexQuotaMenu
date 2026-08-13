import XCTest
@testable import CodexQuotaMenu

final class WidgetPayloadTests: XCTestCase {
    func testBuildsSchemaVersionOneWithoutTaskTitlesOrPaths() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let weeklyReset = Date(timeIntervalSince1970: 200_000)
        let shortReset = Date(timeIntervalSince1970: 110_000)
        let usage = UsageSnapshot(
            windows: [
                RateLimitWindow(usedPercent: 18, durationMinutes: 10_080, resetsAt: weeklyReset),
                RateLimitWindow(usedPercent: 36, durationMinutes: 300, resetsAt: shortReset)
            ],
            plan: "plus",
            fetchedAt: now
        )
        let tasks = TaskSnapshot(
            tasks: [TaskInfo(id: "private", title: "敏感任务标题", state: .running, updatedAt: now)],
            fetchedAt: now
        )
        let forecast = ForecastDisplaySnapshot(
            status: .forecast,
            probability24h: 30,
            probability48h: 50,
            confidence: .medium,
            strongSignal: false,
            lastResetAt: Date(timeIntervalSince1970: 90_000),
            updatedAt: now,
            isCached: false
        )

        let payload = WidgetPayloadBuilder.build(
            usage: usage,
            tasks: tasks,
            forecast: forecast,
            generatedAt: now
        )
        let data = try JSONEncoder.widgetEncoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let quota = try XCTUnwrap(object["quota"] as? [String: Any])
        let taskObject = try XCTUnwrap(object["tasks"] as? [String: Any])
        let forecastObject = try XCTUnwrap(object["forecast"] as? [String: Any])
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["quotaStatus"] as? String, "fresh")
        XCTAssertEqual(object["forecastStatus"] as? String, "forecast")
        XCTAssertEqual(quota["weeklyRemainingPercent"] as? Int, 82)
        XCTAssertEqual(quota["shortRemainingPercent"] as? Int, 64)
        XCTAssertEqual(taskObject["runningCount"] as? Int, 1)
        XCTAssertEqual(forecastObject["probability24h"] as? Int, 30)
        XCTAssertEqual(forecastObject["source"] as? String, "codex-reset.com")
        XCTAssertFalse(text.contains("敏感任务标题"))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("/Users/"))
    }

    func testBuildsIndependentUnavailableStatuses() throws {
        let payload = WidgetPayloadBuilder.build(
            usage: nil,
            tasks: nil,
            forecast: .unavailable,
            generatedAt: Date(timeIntervalSince1970: 100_000)
        )
        let data = try JSONEncoder.widgetEncoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["quotaStatus"] as? String, "unavailable")
        XCTAssertEqual(object["forecastStatus"] as? String, "unavailable")
        XCTAssertTrue(object["quota"] is NSNull)
        XCTAssertTrue(object["forecast"] is NSNull)
        XCTAssertEqual((object["tasks"] as? [String: Any])?["runningCount"] as? Int, 0)
    }
}
