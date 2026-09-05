import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ActivationScheduleSettingsModelTests: XCTestCase {
    func testUpdateMarksCachedStatePendingWithoutSynchronizingUntilApply() async throws {
        let defaults = makeDefaults()
        let store = ActivationScheduleStore(defaults: defaults)
        let entry = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        try store.save([entry])
        let synchronizer = RecordingSynchronizer()
        let agent = fixtureAgent(for: entry.time)
        let snapshot = ActivationSchedulerSnapshot.available(
            agents: [agent],
            loadedLabels: [agent.label]
        )
        let model = ActivationScheduleSettingsModel(
            store: store,
            readSnapshot: { snapshot },
            synchronizer: synchronizer
        )
        model.load()
        let initialSnapshotApplied = await waitUntil { model.syncState == .synced }
        XCTAssertTrue(initialSnapshotApplied)

        try model.update(id: entry.id, time: entry.time, isEnabled: false)

        XCTAssertEqual(synchronizer.callCount, 0)
        XCTAssertEqual(model.syncState, .pending(.init(extra: [entry.time])))
        XCTAssertEqual(try store.load(), [ActivationScheduleEntry(id: entry.id, time: entry.time, isEnabled: false)])

        try model.synchronize()

        XCTAssertEqual(synchronizer.callCount, 1)
        XCTAssertEqual(synchronizer.entries, [[ActivationScheduleEntry(id: entry.id, time: entry.time, isEnabled: false)]])
    }

    func testLoadReturnsPromptlyWhileSnapshotReaderIsBlocked() {
        let defaults = makeDefaults()
        let readerStarted = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readSnapshot: {
                readerStarted.signal()
                _ = releaseReader.wait(timeout: .now() + 0.5)
                return .available(agents: [], loadedLabels: [])
            }
        )

        let start = Date()
        model.load()

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertEqual(readerStarted.wait(timeout: .now() + 1), .success)
        releaseReader.signal()
    }

    func testOlderSnapshotCannotOverwriteNewerSnapshot() async {
        let reader = ControlledSnapshotReader(results: [
            .unavailable("stale result"),
            .available(agents: [], loadedLabels: [])
        ])
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: makeDefaults()),
            readSnapshot: { reader.read() }
        )

        model.load()
        XCTAssertEqual(reader.waitUntilStarted(index: 0), .success)
        model.refreshActualState()
        XCTAssertEqual(reader.waitUntilStarted(index: 1), .success)

        reader.release(index: 1)
        let newerSnapshotApplied = await waitUntil { model.syncState == .unconfigured }
        XCTAssertTrue(newerSnapshotApplied)
        reader.release(index: 0)
        XCTAssertEqual(reader.waitUntilReturned(index: 0), .success)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(model.syncState, .unconfigured)
    }

    func testMutationWithoutSnapshotRemainsPending() throws {
        let defaults = makeDefaults()
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: defaults),
            readSnapshot: { .available(agents: [], loadedLabels: []) }
        )
        model.load()

        try model.add(time: ActivationTime(hour: 11, minute: 2))

        guard case .pending = model.syncState else {
            return XCTFail("editing before the first snapshot must remain pending")
        }
    }

    func testUnavailableSnapshotCannotReportSynced() async {
        let model = ActivationScheduleSettingsModel(
            store: ActivationScheduleStore(defaults: makeDefaults()),
            readSnapshot: { .unavailable("fixture unavailable") }
        )

        model.load()

        let unavailableApplied = await waitUntil { model.syncState == .unavailable("fixture unavailable") }
        XCTAssertTrue(unavailableApplied)
    }

    func testStaleCodexPathSurfacesAsPendingMisconfiguredInModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ActivationScheduleSettingsModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let time = try ActivationTime(hour: 6, minute: 30)
        let entry = ActivationScheduleEntry(time: time)
        let currentPolicy = ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/Applications/Codex B.app/Contents/Resources/codex"),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let stalePolicy = ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/Applications/Codex A.app/Contents/Resources/codex"),
            homeDirectory: currentPolicy.homeDirectory
        )
        try stalePolicy.agent(for: time).xmlData().write(
            to: directory.appendingPathComponent(currentPolicy.fileName(for: time))
        )
        let readResult = ActivationLaunchAgentReader(
            policy: currentPolicy,
            directoryURL: directory
        ).read()
        let snapshot: ActivationSchedulerSnapshot
        switch readResult {
        case .available(let agents):
            snapshot = .available(agents: agents, loadedLabels: [currentPolicy.label(for: time)])
        case .unavailable(let reason):
            snapshot = .unavailable(reason)
        }
        let store = ActivationScheduleStore(defaults: makeDefaults())
        try store.save([entry])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readSnapshot: { snapshot }
        )

        model.load()

        let pendingApplied = await waitUntil {
            model.syncState == .pending(.init(misconfigured: [time]))
        }
        XCTAssertTrue(pendingApplied)
    }

    func testCorruptStorageRejectsEveryModelMutationWithoutSaving() throws {
        let defaults = makeDefaults()
        let original = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
        let corruptData = Data("not-json".utf8)
        let store = ActivationScheduleStore(defaults: defaults)
        try store.save([original])
        let model = ActivationScheduleSettingsModel(
            store: store,
            readSnapshot: { .available(agents: [], loadedLabels: []) }
        )
        model.load()
        defaults.set(corruptData, forKey: ActivationScheduleStore.storageKey)
        model.load()

        XCTAssertThrowsError(try model.add(time: ActivationTime(hour: 7, minute: 30)))
        XCTAssertThrowsError(try model.update(id: original.id, time: original.time, isEnabled: false))
        XCTAssertThrowsError(try model.remove(id: original.id))
        XCTAssertEqual(defaults.data(forKey: ActivationScheduleStore.storageKey), corruptData)
        XCTAssertEqual(model.entries, [original])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func fixtureAgent(for time: ActivationTime) -> ActivationLaunchAgent {
        ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/tmp/codex"),
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        ).agent(for: time)
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

private final class RecordingSynchronizer: ActivationLaunchAgentSynchronizing, @unchecked Sendable {
    private(set) var entries: [[ActivationScheduleEntry]] = []

    var callCount: Int { entries.count }

    func synchronize(entries: [ActivationScheduleEntry]) throws {
        self.entries.append(entries)
    }
}

private final class ControlledSnapshotReader: @unchecked Sendable {
    private let results: [ActivationSchedulerSnapshot]
    private let lock = NSLock()
    private var nextIndex = 0
    private let started: [DispatchSemaphore]
    private let released: [DispatchSemaphore]
    private let returned: [DispatchSemaphore]

    init(results: [ActivationSchedulerSnapshot]) {
        self.results = results
        started = results.map { _ in DispatchSemaphore(value: 0) }
        released = results.map { _ in DispatchSemaphore(value: 0) }
        returned = results.map { _ in DispatchSemaphore(value: 0) }
    }

    func read() -> ActivationSchedulerSnapshot {
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        lock.unlock()
        started[index].signal()
        _ = released[index].wait(timeout: .now() + 2)
        returned[index].signal()
        return results[index]
    }

    func waitUntilStarted(index: Int) -> DispatchTimeoutResult { started[index].wait(timeout: .now() + 1) }
    func waitUntilReturned(index: Int) -> DispatchTimeoutResult { returned[index].wait(timeout: .now() + 1) }
    func release(index: Int) { released[index].signal() }
}
