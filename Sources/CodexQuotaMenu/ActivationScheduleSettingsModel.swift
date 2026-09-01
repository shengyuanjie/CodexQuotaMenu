import Foundation

@MainActor
final class ActivationScheduleSettingsModel {
    private let store: ActivationScheduleStore
    private let readAutomations: () -> AutomationReadResult
    private var timeZoneIdentifier = TimeZone.current.identifier

    private(set) var entries: [ActivationScheduleEntry] = []
    private(set) var syncState: AutomationSyncState = .unconfigured
    private(set) var loadError: Error?

    init(
        store: ActivationScheduleStore = ActivationScheduleStore(),
        readAutomations: @escaping () -> AutomationReadResult = {
            CodexAutomationReader().readManagedAutomations()
        }
    ) {
        self.store = store
        self.readAutomations = readAutomations
    }

    func load(timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.timeZoneIdentifier = timeZoneIdentifier

        do {
            let loaded = try store.load()
            entries = loaded
            loadError = nil
            refreshActualState(timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            loadError = error
            syncState = .unavailable("stored schedule is unreadable")
        }
    }

    func add(time: ActivationTime) throws {
        try persist(entries + [ActivationScheduleEntry(time: time)])
    }

    func update(id: UUID, time: ActivationTime, isEnabled: Bool) throws {
        var value = entries
        guard let index = value.firstIndex(where: { $0.id == id }) else { return }
        value[index].time = time
        value[index].isEnabled = isEnabled
        try persist(value)
    }

    func remove(id: UUID) throws {
        try persist(entries.filter { $0.id != id })
    }

    func refreshActualState(timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.timeZoneIdentifier = timeZoneIdentifier
        syncState = AutomationReconciler.evaluate(
            entries: entries,
            readResult: readAutomations(),
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func makeSyncPrompt(timeZoneIdentifier: String = TimeZone.current.identifier) throws -> String {
        try SyncPromptBuilder.build(entries: entries, timeZoneIdentifier: timeZoneIdentifier)
    }

    private func persist(_ value: [ActivationScheduleEntry]) throws {
        let normalized = try ActivationScheduleEntry.normalized(value)
        try store.save(normalized)
        entries = normalized
        loadError = nil
        refreshActualState(timeZoneIdentifier: timeZoneIdentifier)
    }
}
