import XCTest
@testable import CodexQuotaMenu

final class ForecastCacheTests: XCTestCase {
    func testIgnoresV2CacheWithoutDeletingItAndRoundTripsV3Forecast() throws {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let v2Key = "globalReset.resetMonitorForecast.v2"
        let legacy = ResetForecast(
            probability48h: 70,
            sourceUpdatedAt: Date(timeIntervalSince1970: 12_345),
            fetchedAt: Date(timeIntervalSince1970: 12_345)
        )
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: v2Key)

        let sourceUpdatedAt = Date(timeIntervalSince1970: 123_456)
        let expected = ResetForecast(
            probability48h: 82,
            sourceUpdatedAt: sourceUpdatedAt,
            fetchedAt: sourceUpdatedAt.addingTimeInterval(60)
        )

        let cache = UserDefaultsForecastCache(defaults: defaults)
        XCTAssertNil(cache.load())
        XCTAssertEqual(defaults.data(forKey: v2Key), legacyData)

        cache.save(expected)

        XCTAssertEqual(UserDefaultsForecastCache.storageKey, "globalReset.willCodexResetForecast.v3")
        XCTAssertEqual(UserDefaultsForecastCache(defaults: defaults).load(), expected)
        XCTAssertEqual(defaults.data(forKey: v2Key), legacyData)
    }

    func testReturnsNilForMissingOrCorruptedCache() {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsForecastCache(defaults: defaults)
        XCTAssertNil(cache.load())
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsForecastCache.storageKey)
        XCTAssertNil(cache.load())
    }

    func testRemovesOversizedOrInvalidLegacyForecastCache() throws {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsForecastCache(defaults: defaults)
        let invalid = ResetForecast(
            probability48h: 101,
            sourceUpdatedAt: Date(timeIntervalSince1970: 123_456),
            fetchedAt: Date(timeIntervalSince1970: 123_456)
        )
        defaults.set(try JSONEncoder().encode(invalid), forKey: UserDefaultsForecastCache.storageKey)

        XCTAssertNil(cache.load())
        XCTAssertNil(defaults.data(forKey: UserDefaultsForecastCache.storageKey))

        defaults.set(Data(repeating: 0x41, count: 65_537), forKey: UserDefaultsForecastCache.storageKey)
        XCTAssertNil(cache.load())
        XCTAssertNil(defaults.data(forKey: UserDefaultsForecastCache.storageKey))
    }

    func testDoesNotPersistInvalidForecast() {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsForecastCache(defaults: defaults)

        cache.save(ResetForecast(
            probability48h: 101,
            sourceUpdatedAt: Date(timeIntervalSince1970: 123_456),
            fetchedAt: Date(timeIntervalSince1970: 123_456)
        ))

        XCTAssertNil(defaults.data(forKey: UserDefaultsForecastCache.storageKey))
    }
}
