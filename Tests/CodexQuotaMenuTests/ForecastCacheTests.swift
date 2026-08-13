import XCTest
@testable import CodexQuotaMenu

final class ForecastCacheTests: XCTestCase {
    func testPersistsPrimaryForecastAcrossCacheInstances() {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = PrimaryForecast(
            probability24h: 30,
            probability48h: 50,
            confidence: .medium,
            updatedAt: Date(timeIntervalSince1970: 123_456),
            lastResetAt: Date(timeIntervalSince1970: 120_000)
        )

        UserDefaultsForecastCache(defaults: defaults).save(expected)
        let loaded = UserDefaultsForecastCache(defaults: defaults).load()

        XCTAssertEqual(loaded, expected)
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
}
