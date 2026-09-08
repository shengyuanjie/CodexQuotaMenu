import Foundation

@MainActor
final class ActivationScheduleSettingsModel {
    private let store: ActivationScheduleStore
    private let readSnapshot: @Sendable () -> ActivationSchedulerSnapshot
    private let synchronizer: any ActivationLaunchAgentSynchronizing
    private var refreshGeneration: UInt64 = 0
    private var latestSnapshot: ActivationSchedulerSnapshot?

    private(set) var entries: [ActivationScheduleEntry] = []
    private(set) var syncState: AutomationSyncState = .unconfigured
    private(set) var loadError: Error?
    var stateDidChange: (() -> Void)?

    init(
        store: ActivationScheduleStore = ActivationScheduleStore(),
        readSnapshot: @escaping @Sendable () -> ActivationSchedulerSnapshot = {
            ActivationScheduleSettingsModel.readCurrentSnapshot()
        },
        synchronizer: any ActivationLaunchAgentSynchronizing = ActivationLaunchAgentSynchronizer()
    ) {
        self.store = store
        self.readSnapshot = readSnapshot
        self.synchronizer = synchronizer
    }

    func load() {
        do {
            entries = try store.load()
            loadError = nil
            stateDidChange?()
            refreshActualState()
        } catch {
            refreshGeneration &+= 1
            loadError = error
            syncState = .unavailable("stored schedule is unreadable")
            stateDidChange?()
        }
    }

    func load(timeZoneIdentifier: String) {
        load()
    }

    func add(time: ActivationTime) throws {
        try ensureMutationsAreAllowed()
        try persist(entries + [ActivationScheduleEntry(time: time)])
    }

    func update(id: UUID, time: ActivationTime, isEnabled: Bool) throws {
        try ensureMutationsAreAllowed()
        var value = entries
        guard let index = value.firstIndex(where: { $0.id == id }) else { return }
        value[index].time = time
        value[index].isEnabled = isEnabled
        try persist(value)
    }

    func remove(id: UUID) throws {
        try ensureMutationsAreAllowed()
        try persist(entries.filter { $0.id != id })
    }

    func refreshActualState() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let reader = readSnapshot
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = reader()
            await self?.applySnapshot(snapshot, generation: generation)
        }
    }

    func refreshActualState(timeZoneIdentifier: String) {
        refreshActualState()
    }

    func synchronize() throws {
        try ensureMutationsAreAllowed()
        try synchronizer.synchronize(entries: entries)
        refreshActualState()
    }

    func synchronize(timeZoneIdentifier: String) throws {
        try synchronize()
    }

    private func persist(_ value: [ActivationScheduleEntry]) throws {
        let normalized = try ActivationScheduleEntry.normalized(value)
        try store.save(normalized)
        entries = normalized
        loadError = nil
        reconcileLatestSnapshot()
        stateDidChange?()
    }

    private func ensureMutationsAreAllowed() throws {
        guard loadError == nil else {
            throw ActivationScheduleError.corruptStoredData
        }
    }

    private func applySnapshot(_ snapshot: ActivationSchedulerSnapshot, generation: UInt64) {
        guard loadError == nil, generation == refreshGeneration else { return }
        latestSnapshot = snapshot
        syncState = ActivationLaunchAgentReconciler.evaluate(entries: entries, snapshot: snapshot)
        stateDidChange?()
    }

    private func reconcileLatestSnapshot() {
        guard let latestSnapshot else {
            syncState = .pending(.init())
            return
        }
        syncState = ActivationLaunchAgentReconciler.evaluate(entries: entries, snapshot: latestSnapshot)
        if syncState == .unconfigured {
            syncState = .pending(.init())
        }
    }

    nonisolated private static func readCurrentSnapshot() -> ActivationSchedulerSnapshot {
        do {
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let policy = ActivationLaunchAgentPolicy(
                codexURL: try CodexExecutableLocator().findExecutable(),
                homeDirectory: homeDirectory
            )
            return ActivationSchedulerSnapshot.read(
                readResult: ActivationLaunchAgentReader(policy: policy).read(),
                controller: LaunchctlController()
            )
        } catch {
            return .unavailable("LaunchAgent scheduler state is unavailable")
        }
    }
}
