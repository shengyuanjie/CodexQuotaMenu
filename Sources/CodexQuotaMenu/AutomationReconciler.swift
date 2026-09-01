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
            && misconfigured.isEmpty && unmatchedNames.isEmpty
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
        let tasks = readTasks.filter { $0.name.hasPrefix(ManagedAutomationPolicy.namePrefix) }
        let grouped = Dictionary(grouping: tasks.compactMap { task -> (ActivationTime, CodexAutomation)? in
            guard let time = managedTime(task) else { return nil }
            return (time, task)
        }, by: \.0)
        let actual = Set(grouped.keys)
        var difference = AutomationDifference()

        difference.missing = desired.subtracting(actual).sorted()
        difference.extra = actual.subtracting(desired).sorted()
        difference.extra = uniqueSorted(
            difference.extra + tasks.compactMap { task in
                guard managedTime(task) == nil else { return nil }
                return malformedManagedTime(task.name)
            }
        )
        difference.duplicate = grouped.compactMap { time, values in
            values.count > 1 ? time : nil
        }.sorted()
        difference.paused = uniqueSorted(tasks.compactMap { task in
            guard let time = managedTime(task), task.status != "ACTIVE" else { return nil }
            return time
        })
        difference.misconfigured = uniqueSorted(tasks.compactMap { task in
            guard let time = managedTime(task), desired.contains(time) else { return nil }
            return matchesPolicy(task, time: time, timeZoneIdentifier: timeZoneIdentifier) ? nil : time
        })
        difference.unmatchedNames = tasks.compactMap { task in
            managedTime(task) == nil && malformedManagedTime(task.name) == nil ? task.name : nil
        }.sorted()

        if desired.isEmpty && tasks.isEmpty {
            return .unconfigured
        }
        return difference.isEmpty ? .synced : .pending(difference)
    }

    private static func managedTime(_ task: CodexAutomation) -> ActivationTime? {
        let suffix = task.name.dropFirst(ManagedAutomationPolicy.namePrefix.count)
        guard suffix.count == 5 else { return nil }
        return parseTime(String(suffix))
    }

    private static func malformedManagedTime(_ name: String) -> ActivationTime? {
        guard name.hasPrefix(ManagedAutomationPolicy.namePrefix) else { return nil }
        let suffix = name.dropFirst(ManagedAutomationPolicy.namePrefix.count)
        guard suffix.count > 5 else { return nil }
        return parseTime(String(suffix.prefix(5)))
    }

    private static func parseTime(_ text: String) -> ActivationTime? {
        let characters = Array(text.utf8)
        guard characters.count == 5,
              characters[2] == 58,
              characters[0...1].allSatisfy(isASCIIDigit),
              characters[3...4].allSatisfy(isASCIIDigit),
              let hour = Int(text.prefix(2)),
              let minute = Int(text.suffix(2)) else {
            return nil
        }
        return try? ActivationTime(hour: hour, minute: minute)
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

        return fields["TZID"].map { $0 == timeZoneIdentifier } ?? true
    }

    private static func uniqueSorted(_ values: [ActivationTime]) -> [ActivationTime] {
        Array(Set(values)).sorted()
    }

    private static func isASCIIDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
    }
}
