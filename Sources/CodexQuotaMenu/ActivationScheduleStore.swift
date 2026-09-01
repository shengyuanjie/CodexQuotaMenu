import Foundation

struct ActivationScheduleStore {
    static let storageKey = "activationSchedule.entries.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [ActivationScheduleEntry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        guard let value = try? JSONDecoder().decode([ActivationScheduleEntry].self, from: data),
              let normalized = try? ActivationScheduleEntry.normalized(value) else {
            throw ActivationScheduleError.corruptStoredData
        }
        return normalized
    }

    func save(_ entries: [ActivationScheduleEntry]) throws {
        defaults.set(
            try JSONEncoder().encode(ActivationScheduleEntry.normalized(entries)),
            forKey: Self.storageKey
        )
    }
}
