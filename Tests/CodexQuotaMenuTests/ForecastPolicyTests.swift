import XCTest
@testable import CodexQuotaMenu

final class ForecastPolicyTests: XCTestCase {
    func testRecentResetSuppressesFastSignalWithoutChangingProbability() {
        let now = Date(timeIntervalSince1970: 10_000)
        let primary = primaryForecast(
            probability24h: 30,
            updatedAt: now,
            lastResetAt: now.addingTimeInterval(-3_600)
        )
        let fast = FastForecastSignal(
            score48h: 99,
            calibrationState: "experimental",
            fetchedAt: now
        )

        let result = ForecastPolicy.resolve(primary: primary, fast: fast, now: now)

        XCTAssertEqual(result.status, .recentlyReset)
        XCTAssertFalse(result.strongSignal)
        XCTAssertEqual(result.probability24h, 30)
    }

    func testFastSignalTriggersAfterRecentResetWindow() {
        let now = Date(timeIntervalSince1970: 100_000)
        let primary = primaryForecast(
            updatedAt: now,
            lastResetAt: now.addingTimeInterval(-(6 * 3_600 + 1))
        )
        let fast = FastForecastSignal(
            score48h: 90,
            calibrationState: "experimental",
            fetchedAt: now.addingTimeInterval(-10 * 60)
        )

        let result = ForecastPolicy.resolve(primary: primary, fast: fast, now: now)

        XCTAssertEqual(result.status, .strongSignal)
        XCTAssertTrue(result.strongSignal)
        XCTAssertEqual(result.probability24h, 30)
    }

    func testFastSignalRejectsLowStaleOrUnknownInputs() {
        let now = Date(timeIntervalSince1970: 100_000)
        let primary = primaryForecast(updatedAt: now, lastResetAt: nil)
        let inputs = [
            FastForecastSignal(score48h: 89, calibrationState: "experimental", fetchedAt: now),
            FastForecastSignal(score48h: 99, calibrationState: "unknown", fetchedAt: now),
            FastForecastSignal(score48h: 99, calibrationState: "experimental", fetchedAt: now.addingTimeInterval(-601))
        ]

        for fast in inputs {
            let result = ForecastPolicy.resolve(primary: primary, fast: fast, now: now)
            XCTAssertEqual(result.status, .forecast)
            XCTAssertFalse(result.strongSignal)
        }
    }

    func testPrimaryFreshnessTransitionsFromForecastToCachedToUnavailable() {
        let now = Date(timeIntervalSince1970: 100_000)

        let fresh = ForecastPolicy.resolve(
            primary: primaryForecast(updatedAt: now.addingTimeInterval(-15 * 60), lastResetAt: nil),
            fast: nil,
            now: now
        )
        let cached = ForecastPolicy.resolve(
            primary: primaryForecast(updatedAt: now.addingTimeInterval(-(15 * 60 + 1)), lastResetAt: nil),
            fast: nil,
            now: now
        )
        let expired = ForecastPolicy.resolve(
            primary: primaryForecast(updatedAt: now.addingTimeInterval(-(2 * 3_600 + 1)), lastResetAt: nil),
            fast: nil,
            now: now
        )

        XCTAssertEqual(fresh.status, .forecast)
        XCTAssertFalse(fresh.isCached)
        XCTAssertEqual(cached.status, .cached)
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(expired.status, .unavailable)
        XCTAssertNil(expired.probability24h)
        XCTAssertNil(expired.probability48h)
    }

    func testRejectsPrimaryTimestampTooFarInFuture() {
        let now = Date(timeIntervalSince1970: 100_000)
        let tolerated = ForecastPolicy.resolve(
            primary: primaryForecast(updatedAt: now.addingTimeInterval(5 * 60), lastResetAt: nil),
            fast: nil,
            now: now
        )
        let invalid = ForecastPolicy.resolve(
            primary: primaryForecast(updatedAt: now.addingTimeInterval(5 * 60 + 1), lastResetAt: nil),
            fast: nil,
            now: now
        )

        XCTAssertEqual(tolerated.status, .forecast)
        XCTAssertEqual(invalid.status, .unavailable)
        XCTAssertNil(invalid.updatedAt)
    }

    func testStrongSignalCanStillWarnWhenPrimaryIsUnavailable() {
        let now = Date(timeIntervalSince1970: 100_000)
        let fast = FastForecastSignal(
            score48h: 99,
            calibrationState: "experimental",
            fetchedAt: now
        )

        let result = ForecastPolicy.resolve(primary: nil, fast: fast, now: now)

        XCTAssertEqual(result.status, .strongSignal)
        XCTAssertTrue(result.strongSignal)
        XCTAssertNil(result.probability24h)
    }
}

private extension ForecastPolicyTests {
    func primaryForecast(
        probability24h: Int = 30,
        updatedAt: Date,
        lastResetAt: Date?
    ) -> PrimaryForecast {
        PrimaryForecast(
            probability24h: probability24h,
            probability48h: 50,
            confidence: .medium,
            updatedAt: updatedAt,
            lastResetAt: lastResetAt
        )
    }
}
