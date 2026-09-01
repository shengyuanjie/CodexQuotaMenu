import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ActivationScheduleSettingsModelTests: XCTestCase {
    func testMutationsPersistSortAndPreserveOnDuplicate() throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ActivationScheduleStore(defaults: defaults)
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()

        try model.add(time: try ActivationTime(hour: 11, minute: 2))
        try model.add(time: try ActivationTime(hour: 6, minute: 0))
        XCTAssertEqual(model.entries.map(\.time.displayValue), ["06:00", "11:02"])

        XCTAssertThrowsError(try model.add(time: try ActivationTime(hour: 6, minute: 0)))
        XCTAssertEqual(try store.load().count, 2)
        XCTAssertEqual(model.entries.map(\.time.displayValue), ["06:00", "11:02"])
    }

    func testUnavailableReaderCannotReportSynced() throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { .unavailable("unsupported") }
        )

        model.load(timeZoneIdentifier: "Asia/Shanghai")

        XCTAssertEqual(model.syncState, .unavailable("unsupported"))
    }

    func testCorruptStorageKeepsLoadErrorAndDoesNotClearCurrentEntries() throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let time = try ActivationTime(hour: 6, minute: 0)
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([ActivationScheduleEntry(time: time)])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()
        defaults.set(Data("not-json".utf8), forKey: ActivationScheduleStore.storageKey)

        model.load()

        XCTAssertEqual(model.entries.map(\.time.displayValue), ["06:00"])
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(model.syncState, .unavailable("stored schedule is unreadable"))
        XCTAssertEqual(defaults.data(forKey: ActivationScheduleStore.storageKey), Data("not-json".utf8))
    }

    func testPromptUsesOnlyCurrentExpectedEntries() throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { .available([]) }
        )
        model.load()
        try model.add(time: try ActivationTime(hour: 11, minute: 2))
        let disabled = try ActivationTime(hour: 6, minute: 0)
        try model.add(time: disabled)
        let entry = try XCTUnwrap(model.entries.first(where: { $0.time == disabled }))
        try model.update(id: entry.id, time: disabled, isEnabled: false)

        let prompt = try model.makeSyncPrompt(timeZoneIdentifier: "Asia/Shanghai")

        XCTAssertTrue(prompt.contains("CodexQuotaMenu · 11:02"))
        XCTAssertFalse(prompt.contains("CodexQuotaMenu · 06:00"))
        XCTAssertTrue(prompt.contains("Asia/Shanghai"))
    }
}
