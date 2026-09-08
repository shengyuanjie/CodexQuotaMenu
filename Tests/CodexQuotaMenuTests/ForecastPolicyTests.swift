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

    func testUsesLocalFetchTimeForFreshnessAndSourceTimeForDisplay() {
        let now = Date(timeIntervalSince1970: 100_000)
        let sourceUpdatedAt = now.addingTimeInterval(-86_400)
        let locallyFetchedAt = now.addingTimeInterval(-60)
        let forecast = ResetForecast(
            probability48h: 82,
            sourceUpdatedAt: sourceUpdatedAt,
            fetchedAt: locallyFetchedAt
        )

        let snapshot = ForecastPolicy.resolve(forecast: forecast, now: now)

        XCTAssertEqual(snapshot.status, .fresh)
        XCTAssertFalse(snapshot.isCached)
        XCTAssertEqual(snapshot.updatedAt, sourceUpdatedAt)
    }

    private func forecast(at date: Date) -> ResetForecast {
        ResetForecast(probability48h: 82, sourceUpdatedAt: date, fetchedAt: date)
    }
}
