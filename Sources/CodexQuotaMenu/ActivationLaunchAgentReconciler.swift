import Foundation

struct AutomationDifference: Equatable, Sendable {
    var missing: [ActivationTime] = []
    var extra: [ActivationTime] = []
    var duplicate: [ActivationTime] = []
    var paused: [ActivationTime] = []
    var misconfigured: [ActivationTime] = []
    var unmatchedNames: [String] = []

    var isEmpty: Bool {
        missing.isEmpty && extra.isEmpty && duplicate.isEmpty && paused.isEmpty
            && misconfigured.isEmpty
    }
}

enum AutomationSyncState: Equatable, Sendable {
    case unconfigured
    case synced
    case pending(AutomationDifference)
    case unavailable(String)
}

enum ActivationSchedulerSnapshot: Equatable, Sendable {
    case available(agents: [ActivationLaunchAgent], loadedLabels: Set<String>)
    case unavailable(String)

    static func read(
        readResult: ActivationLaunchAgentReadResult,
        controller: LaunchctlControlling
    ) -> Self {
        switch readResult {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let agents):
            do {
                let loadedLabels = try controller.loadedOwnedLabels()
                return .available(agents: agents, loadedLabels: loadedLabels)
            } catch {
                return .unavailable("LaunchAgent loaded state is unavailable")
            }
        }
    }
}

enum ActivationLaunchAgentReconciler {
    static func evaluate(
        entries: [ActivationScheduleEntry],
        snapshot: ActivationSchedulerSnapshot
    ) -> AutomationSyncState {
        guard case .available(let agents, let loadedLabels) = snapshot else {
            if case .unavailable(let reason) = snapshot {
                return .unavailable(reason)
            }
            return .unavailable("LaunchAgent scheduler state is unavailable")
        }

        let desired = Set(entries.filter(\.isEnabled).map(\.time))
        let groupedAgents = Dictionary(grouping: agents, by: \.time)
        let configuredTimes = Set(groupedAgents.keys)
        let loadedTimes = Set(loadedLabels.compactMap(time(forOwnedLabel:)))
        let actualTimes = configuredTimes.union(loadedTimes)
        var difference = AutomationDifference()

        difference.missing = desired.subtracting(configuredTimes).sorted()
        difference.extra = actualTimes.subtracting(desired).sorted()
        difference.duplicate = groupedAgents.compactMap { time, values in
            values.count > 1 ? time : nil
        }.sorted()
        difference.paused = desired
            .intersection(configuredTimes)
            .subtracting(loadedTimes)
            .sorted()
        difference.misconfigured = desired.compactMap { time in
            groupedAgents[time]?.contains(where: { $0.requiresSynchronization }) == true
                ? time
                : nil
        }.sorted()

        if desired.isEmpty && actualTimes.isEmpty {
            return .unconfigured
        }
        return difference.isEmpty ? .synced : .pending(difference)
    }

    private static func time(forOwnedLabel label: String) -> ActivationTime? {
        guard label.hasPrefix(ActivationLaunchAgentPolicy.labelPrefix) else { return nil }
        let suffix = label.dropFirst(ActivationLaunchAgentPolicy.labelPrefix.count)
        let bytes = Array(suffix.utf8)
        guard bytes.count == 4,
              bytes.allSatisfy({ (48...57).contains($0) }),
              let hour = Int(suffix.prefix(2)),
              let minute = Int(suffix.suffix(2)) else {
            return nil
        }
        return try? ActivationTime(hour: hour, minute: minute)
    }
}
