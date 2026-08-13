import XCTest
@testable import CodexQuotaMenu

final class ForecastCacheTests: XCTestCase {
    func testPersistsResetMonitorForecastAndRemovesLegacyCache() {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("legacy".utf8), forKey: UserDefaultsForecastCache.legacyStorageKey)
        let expected = ResetForecast(probability48h: 82, calibrationState: "experimental", fetchedAt: Date(timeIntervalSince1970: 123_456))

        let cache = UserDefaultsForecastCache(defaults: defaults)
        cache.save(expected)

        XCTAssertNil(defaults.data(forKey: UserDefaultsForecastCache.legacyStorageKey))
        XCTAssertEqual(UserDefaultsForecastCache(defaults: defaults).load(), expected)
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
