import XCTest
@testable import CodexQuotaMenu

final class WidgetPayloadTests: XCTestCase {
    func testBuildsSchemaVersionTwoWithOnlyTheSingleForecast() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let forecast = ForecastDisplaySnapshot(status: .fresh, probability48h: 82, calibrationState: "experimental", updatedAt: now, isCached: false)
        let payload = WidgetPayloadBuilder.build(
            usage: nil,
            tasks: nil,
            forecast: forecast,
            resetCelebrationActive: true,
            generatedAt: now
        )
        let data = try JSONEncoder.widgetEncoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try XCTUnwrap(object["forecast"] as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["resetCelebrationActive"] as? Bool, true)
        XCTAssertEqual(value["probability48h"] as? Int, 82)
        XCTAssertEqual(value["calibrationState"] as? String, "experimental")
        XCTAssertEqual(value["source"] as? String, "codexreset.org")
        XCTAssertNil(value["probability24h"])
        XCTAssertNil(value["confidence"])
        XCTAssertNil(value["strongSignal"])
        XCTAssertNil(value["lastResetAt"])
    }

    func testUnavailableForecastRemainsIndependentFromQuota() throws {
        let payload = WidgetPayloadBuilder.build(
            usage: nil,
            tasks: nil,
            forecast: .unavailable,
            resetCelebrationActive: false,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder.widgetEncoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["forecastStatus"] as? String, "unavailable")
        XCTAssertTrue(object["forecast"] is NSNull)
    }
}
