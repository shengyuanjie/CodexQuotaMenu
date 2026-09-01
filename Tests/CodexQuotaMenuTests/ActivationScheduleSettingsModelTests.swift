import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ActivationScheduleSettingsModelTests: XCTestCase {
    func testLoadReturnsPromptlyWhileAutomationReaderIsBlocked() {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let readerStarted = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: {
                readerStarted.signal()
                _ = releaseReader.wait(timeout: .now() + 0.5)
                return .available([])
            }
        )

        let start = Date()
        model.load()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertEqual(readerStarted.wait(timeout: .now() + 1), .success)
        releaseReader.signal()
    }

    func testOlderScanResultCannotOverwriteNewerResult() async {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = ControlledAutomationReader(results: [
            .unavailable("stale result"),
            .available([])
        ])
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { reader.read() }
        )

        model.load(timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(reader.waitUntilStarted(index: 0), .success)
        model.refreshActualState(timeZoneIdentifier: "Asia/Shanghai")
        XCTAssertEqual(reader.waitUntilStarted(index: 1), .success)

        reader.release(index: 1)
        XCTAssertEqual(reader.waitUntilReturned(index: 1), .success)
        let newerResultApplied = await waitUntil { model.syncState == .unconfigured }
        XCTAssertTrue(newerResultApplied)

        reader.release(index: 0)
        XCTAssertEqual(reader.waitUntilReturned(index: 0), .success)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(model.syncState, .unconfigured)
    }

    func testProviderChangeAffectsPromptAndMutationWithoutAnotherDiskRead() async throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 2)
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([ActivationScheduleEntry(time: six)])
        let timeZoneIdentifier = LockedValue("America/Los_Angeles")
        let readCount = LockedValue(0)
        let existingAutomation = fixture(
            six,
            timeZoneIdentifier: "America/Los_Angeles"
        )
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: {
                readCount.withValue { $0 += 1 }
                return .available([existingAutomation])
            },
            timeZoneIdentifierProvider: { timeZoneIdentifier.value }
        )

        model.load()
        let initialScanApplied = await waitUntil { model.syncState == .synced }
        XCTAssertTrue(initialScanApplied)
        XCTAssertEqual(readCount.value, 1)

        timeZoneIdentifier.value = "Asia/Shanghai"
        let prompt = try model.makeSyncPrompt()
        XCTAssertTrue(prompt.contains("时区为 Asia/Shanghai"))

        try model.add(time: eleven)
        XCTAssertEqual(readCount.value, 1)
        guard case .pending(let difference) = model.syncState else {
            return XCTFail("expected cached snapshot to be reconciled in the current time zone")
        }
        XCTAssertEqual(difference.missing, [eleven])
        XCTAssertEqual(difference.misconfigured, [six])
    }

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

    func testUnavailableReaderCannotReportSynced() async throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readAutomations: { .unavailable("unsupported") }
        )

        model.load(timeZoneIdentifier: "Asia/Shanghai")

        let unavailableApplied = await waitUntil {
            model.syncState == .unavailable("unsupported")
        }
        XCTAssertTrue(unavailableApplied)
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

    func testCorruptStorageRejectsEveryModelMutationWithoutSaving() throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
        let corruptData = Data("not-json".utf8)
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([original])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: { .available([]) }
        )
        model.load()

        func reloadCorruptState() {
            defaults.set(corruptData, forKey: ActivationScheduleStore.storageKey)
            model.load()
            XCTAssertNotNil(model.loadError)
        }

        reloadCorruptState()
        XCTAssertThrowsError(
            try model.add(time: ActivationTime(hour: 7, minute: 30))
        )
        XCTAssertEqual(defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data, corruptData)

        reloadCorruptState()
        XCTAssertThrowsError(
            try model.update(
                id: original.id,
                time: try ActivationTime(hour: 8, minute: 15),
                isEnabled: false
            )
        )
        XCTAssertEqual(defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data, corruptData)

        reloadCorruptState()
        XCTAssertThrowsError(try model.remove(id: original.id))
        XCTAssertEqual(defaults.object(forKey: ActivationScheduleStore.storageKey) as? Data, corruptData)
        XCTAssertEqual(model.entries, [original])
        XCTAssertNotNil(model.loadError)
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
        XCTAssertFalse(prompt.contains("- CodexQuotaMenu · 06:00：每天 06:00"))
        XCTAssertTrue(prompt.contains("Asia/Shanghai"))
    }

    func testExplicitRefreshUsesItsZoneAndMutationUsesLatestSnapshot() async throws {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let time = try ActivationTime(hour: 6, minute: 0)
        let readerResult = AutomationReadResult.available([
            fixture(time, timeZoneIdentifier: "America/Los_Angeles")
        ])
        let readCount = LockedValue(0)
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([ActivationScheduleEntry(time: time)])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readAutomations: {
                readCount.withValue { $0 += 1 }
                return readerResult
            },
            timeZoneIdentifierProvider: { "America/Los_Angeles" }
        )

        model.load(timeZoneIdentifier: "America/Los_Angeles")
        let initialScanApplied = await waitUntil { model.syncState == .synced }
        XCTAssertTrue(initialScanApplied)
        XCTAssertEqual(model.syncState, .synced)

        model.refreshActualState(timeZoneIdentifier: "America/Los_Angeles")
        let secondScanCompleted = await waitUntil { readCount.value == 2 }
        XCTAssertTrue(secondScanCompleted)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.syncState, .synced)

        try model.add(time: try ActivationTime(hour: 11, minute: 2))
        guard case .pending(let difference) = model.syncState else {
            return XCTFail("expected one missing task after adding a second time")
        }
        XCTAssertEqual(difference.missing, [try ActivationTime(hour: 11, minute: 2)])
        XCTAssertEqual(difference.misconfigured, [])

        let prompt = try model.makeSyncPrompt()
        XCTAssertTrue(prompt.contains("时区为 America/Los_Angeles"))
    }

    private func fixture(_ time: ActivationTime, timeZoneIdentifier: String) -> CodexAutomation {
        CodexAutomation(
            id: UUID().uuidString,
            version: 1,
            kind: "cron",
            name: ManagedAutomationPolicy.name(for: time),
            prompt: ManagedAutomationPolicy.activationPrompt,
            status: "ACTIVE",
            rrule: "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute);TZID=\(timeZoneIdentifier)",
            model: ManagedAutomationPolicy.model,
            reasoningEffort: ManagedAutomationPolicy.reasoningEffort,
            notificationPolicy: ManagedAutomationPolicy.notificationPolicy,
            executionEnvironment: "local",
            targetType: "projectless"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate()
    }
}

private final class ControlledAutomationReader: @unchecked Sendable {
    private let results: [AutomationReadResult]
    private let lock = NSLock()
    private var nextIndex = 0
    private let started: [DispatchSemaphore]
    private let released: [DispatchSemaphore]
    private let returned: [DispatchSemaphore]

    init(results: [AutomationReadResult]) {
        self.results = results
        started = results.map { _ in DispatchSemaphore(value: 0) }
        released = results.map { _ in DispatchSemaphore(value: 0) }
        returned = results.map { _ in DispatchSemaphore(value: 0) }
    }

    func read() -> AutomationReadResult {
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        lock.unlock()
        precondition(results.indices.contains(index), "unexpected automation reader call")
        started[index].signal()
        _ = released[index].wait(timeout: .now() + 2)
        returned[index].signal()
        return results[index]
    }

    func waitUntilStarted(index: Int) -> DispatchTimeoutResult {
        started[index].wait(timeout: .now() + 1)
    }

    func waitUntilReturned(index: Int) -> DispatchTimeoutResult {
        returned[index].wait(timeout: .now() + 1)
    }

    func release(index: Int) {
        released[index].signal()
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { withValue { $0 } }
        set { withValue { $0 = newValue } }
    }

    @discardableResult
    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&storedValue)
    }
}
