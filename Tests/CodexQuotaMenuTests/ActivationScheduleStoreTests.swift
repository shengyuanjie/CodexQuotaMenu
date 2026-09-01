import XCTest
@testable import CodexQuotaMenu

final class ActivationScheduleStoreTests: XCTestCase {
    func testStoreStartsEmptyAndRoundTripsSortedEntries() throws {
        let suite = "ScheduleStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivationScheduleStore(defaults: defaults)
        XCTAssertEqual(try store.load(), [])
        let later = ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 2))
        let earlier = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
        try store.save([later, earlier])
        XCTAssertEqual(try store.load(), [earlier, later])
    }

    func testCorruptDataThrowsWithoutBeingOverwritten() {
        let suite = "ScheduleStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("bad".utf8), forKey: ActivationScheduleStore.storageKey)
        XCTAssertThrowsError(try ActivationScheduleStore(defaults: defaults).load())
        XCTAssertNotNil(defaults.data(forKey: ActivationScheduleStore.storageKey))
    }

    func testNonDataPreferenceIsCorruptAndPreserved() {
        let suite = "ScheduleStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not data", forKey: ActivationScheduleStore.storageKey)

        XCTAssertThrowsError(try ActivationScheduleStore(defaults: defaults).load())
        XCTAssertEqual(
            defaults.object(forKey: ActivationScheduleStore.storageKey) as? String,
            "not data"
        )
    }

    func testDuplicateStableIDsInStoredDataAreCorruptAndPreserved() throws {
        let suite = "ScheduleStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let encoded = try JSONEncoder().encode([
            ActivationScheduleEntry(
                id: id,
                time: try ActivationTime(hour: 6, minute: 0)
            ),
            ActivationScheduleEntry(
                id: id,
                time: try ActivationTime(hour: 11, minute: 2)
            )
        ])
        defaults.set(encoded, forKey: ActivationScheduleStore.storageKey)

        XCTAssertThrowsError(try ActivationScheduleStore(defaults: defaults).load())
        XCTAssertEqual(defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data, encoded)
    }
}
