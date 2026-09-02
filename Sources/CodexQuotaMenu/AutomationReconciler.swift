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

enum AutomationReconciler {
    static func evaluate(
        entries: [ActivationScheduleEntry],
        readResult: AutomationReadResult,
        timeZoneIdentifier: String
    ) -> AutomationSyncState {
        guard case .available(let readTasks) = readResult else {
            if case .unavailable(let reason) = readResult {
                return .unavailable(reason)
            }
            return .unavailable("automation state is unavailable")
        }

        let desired = Set(entries.filter(\.isEnabled).map(\.time))
        let tasks = readTasks.compactMap { task -> (ActivationTime, CodexAutomation)? in
            guard let time = ManagedAutomationPolicy.managedTime(from: task.name) else { return nil }
            return (time, task)
        }
        let grouped = Dictionary(grouping: tasks, by: \.0)
        let actual = Set(grouped.keys)
        var difference = AutomationDifference()

        difference.missing = desired.subtracting(actual).sorted()
        difference.extra = actual.subtracting(desired).sorted()
        difference.duplicate = grouped.compactMap { time, values in
            values.count > 1 ? time : nil
        }.sorted()
        difference.paused = uniqueSorted(tasks.compactMap { time, task in
            guard task.status != "ACTIVE" else { return nil }
            return time
        })
        difference.misconfigured = uniqueSorted(tasks.compactMap { time, task in
            guard desired.contains(time) else { return nil }
            return matchesPolicy(task, time: time, timeZoneIdentifier: timeZoneIdentifier) ? nil : time
        })
        difference.unmatchedNames = readTasks
            .map(\.name)
            .filter(ManagedAutomationPolicy.isMalformedPrefixedName)
            .sorted()

        if desired.isEmpty && tasks.isEmpty {
            return .unconfigured
        }
        return difference.isEmpty ? .synced : .pending(difference)
    }

    private static func matchesPolicy(
        _ task: CodexAutomation,
        time: ActivationTime,
        timeZoneIdentifier: String
    ) -> Bool {
        task.kind == "cron"
            && task.name == ManagedAutomationPolicy.name(for: time)
            && task.prompt == ManagedAutomationPolicy.activationPrompt
            && task.status == "ACTIVE"
            && task.model == ManagedAutomationPolicy.model
            && task.reasoningEffort == ManagedAutomationPolicy.reasoningEffort
            && task.notificationPolicy == ManagedAutomationPolicy.notificationPolicy
            && task.executionEnvironment == "local"
            && task.targetType == "projectless"
            && matchesDailyRRule(task.rrule, time: time, timeZoneIdentifier: timeZoneIdentifier)
    }

    private static func matchesDailyRRule(
        _ rrule: String,
        time: ActivationTime,
        timeZoneIdentifier: String
    ) -> Bool {
        var fields: [String: String] = [:]

        for component in rrule.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }

            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, fields[key] == nil else { return false }
            fields[key] = value
        }

        let allowedKeys: Set<String> = ["FREQ", "BYHOUR", "BYMINUTE", "TZID"]
        guard Set(fields.keys).isSubset(of: allowedKeys),
              fields["FREQ"]?.uppercased() == "DAILY",
              fields["BYHOUR"].flatMap(Int.init) == time.hour,
              fields["BYMINUTE"].flatMap(Int.init) == time.minute else {
            return false
        }

        return fields["TZID"] == timeZoneIdentifier
    }

    private static func uniqueSorted(_ values: [ActivationTime]) -> [ActivationTime] {
        Array(Set(values)).sorted()
    }
}
