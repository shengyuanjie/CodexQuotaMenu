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

    func testRemovesOversizedOrInvalidLegacyForecastCache() throws {
        let suiteName = "CodexQuotaMenuTests.ForecastCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = UserDefaultsForecastCache(defaults: defaults)
        let invalid = ResetForecast(
            probability48h: 82,
            calibrationState: String(repeating: "a", count: 65),
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
            calibrationState: "experimental",
            fetchedAt: Date(timeIntervalSince1970: 123_456)
        ))

        XCTAssertNil(defaults.data(forKey: UserDefaultsForecastCache.storageKey))
    }
}
