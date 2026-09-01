import Foundation

@MainActor
final class ActivationScheduleSettingsModel {
    private let store: ActivationScheduleStore
    private let readAutomations: @Sendable () -> AutomationReadResult
    private let timeZoneIdentifierProvider: @Sendable () -> String
    private var refreshGeneration: UInt64 = 0
    private var latestReadResult: AutomationReadResult?

    private(set) var entries: [ActivationScheduleEntry] = []
    private(set) var syncState: AutomationSyncState = .unconfigured
    private(set) var loadError: Error?
    var stateDidChange: (() -> Void)?

    init(
        store: ActivationScheduleStore = ActivationScheduleStore(),
        readAutomations: @escaping @Sendable () -> AutomationReadResult = {
            CodexAutomationReader().readManagedAutomations()
        },
        timeZoneIdentifierProvider: @escaping @Sendable () -> String = {
            TimeZone.current.identifier
        }
    ) {
        self.store = store
        self.readAutomations = readAutomations
        self.timeZoneIdentifierProvider = timeZoneIdentifierProvider
    }

    func load() {
        load(timeZoneIdentifier: timeZoneIdentifierProvider())
    }

    func load(timeZoneIdentifier: String) {

        do {
            let loaded = try store.load()
            entries = loaded
            loadError = nil
            stateDidChange?()
            refreshActualState(timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            refreshGeneration &+= 1
            loadError = error
            syncState = .unavailable("stored schedule is unreadable")
            stateDidChange?()
        }
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
        refreshActualState(timeZoneIdentifier: timeZoneIdentifierProvider())
    }

    func refreshActualState(timeZoneIdentifier: String) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let reader = readAutomations
        Task.detached(priority: .utility) { [weak self] in
            let result = reader()
            await self?.applyReadResult(
                result,
                timeZoneIdentifier: timeZoneIdentifier,
                generation: generation
            )
        }
    }

    func makeSyncPrompt() throws -> String {
        try makeSyncPrompt(timeZoneIdentifier: timeZoneIdentifierProvider())
    }

    func makeSyncPrompt(timeZoneIdentifier: String) throws -> String {
        return try SyncPromptBuilder.build(entries: entries, timeZoneIdentifier: timeZoneIdentifier)
    }

    private func persist(_ value: [ActivationScheduleEntry]) throws {
        let normalized = try ActivationScheduleEntry.normalized(value)
        try store.save(normalized)
        entries = normalized
        loadError = nil
        reconcileLatestReadResult(timeZoneIdentifier: timeZoneIdentifierProvider())
        stateDidChange?()
    }

    private func ensureMutationsAreAllowed() throws {
        guard loadError == nil else {
            throw ActivationScheduleError.corruptStoredData
        }
    }

    private func applyReadResult(
        _ result: AutomationReadResult,
        timeZoneIdentifier: String,
        generation: UInt64
    ) {
        guard loadError == nil, generation == refreshGeneration else { return }
        latestReadResult = result
        syncState = AutomationReconciler.evaluate(
            entries: entries,
            readResult: result,
            timeZoneIdentifier: timeZoneIdentifier
        )
        stateDidChange?()
    }

    private func reconcileLatestReadResult(timeZoneIdentifier: String) {
        guard let latestReadResult else {
            syncState = .unavailable("automation state has not been scanned")
            return
        }
        syncState = AutomationReconciler.evaluate(
            entries: entries,
            readResult: latestReadResult,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}
