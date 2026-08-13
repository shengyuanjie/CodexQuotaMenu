import XCTest
@testable import CodexQuotaMenu

final class ForecastPolicyTests: XCTestCase {
    func testFreshnessTransitionsAtExactBoundaries() {
        let now = Date(timeIntervalSince1970: 100_000)
        let fresh = ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(-900)), now: now)
        let cached = ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(-901)), now: now)
        let lastCached = ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(-7_200)), now: now)
        let expired = ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(-7_201)), now: now)

        XCTAssertEqual(fresh.status, .fresh)
        XCTAssertFalse(fresh.isCached)
        XCTAssertEqual(cached.status, .cached)
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(lastCached.probability48h, 82)
        XCTAssertEqual(expired, .unavailable)
    }

    func testRejectsTimestampMoreThanFiveMinutesInFuture() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(
            ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(300)), now: now).status,
            .fresh
        )
        XCTAssertEqual(
            ForecastPolicy.resolve(forecast: forecast(at: now.addingTimeInterval(301)), now: now),
            .unavailable
        )
    }

    private func forecast(at date: Date) -> ResetForecast {
        ResetForecast(probability48h: 82, calibrationState: "experimental", fetchedAt: date)
    }
}
