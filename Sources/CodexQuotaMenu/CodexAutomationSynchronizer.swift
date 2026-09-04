import Foundation

enum CodexAutomationSynchronizationError: Error, Equatable {
    case unreadableState
    case unsafeManagedTask
    case targetCollision
    case verificationFailed
    case recoveryRequired(String)
}

struct CodexAutomationSynchronizationHooks {
    var beforeInstallingTask: (String) throws -> Void
    var beforeRollback: () throws -> Void

    init(
        beforeInstallingTask: @escaping (String) throws -> Void = { _ in },
        beforeRollback: @escaping () throws -> Void = {}
    ) {
        self.beforeInstallingTask = beforeInstallingTask
        self.beforeRollback = beforeRollback
    }
}

struct CodexAutomationSynchronizer {
    let rootURL: URL
    let fileManager: FileManager
    let timestampProvider: () -> Int64
    let hooks: CodexAutomationSynchronizationHooks

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/automations", isDirectory: true),
        fileManager: FileManager = .default,
        timestampProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        hooks: CodexAutomationSynchronizationHooks = .init()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.timestampProvider = timestampProvider
        self.hooks = hooks
    }

    func synchronize(
        entries: [ActivationScheduleEntry],
        timeZoneIdentifier: String
    ) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let recovery = try existingRecoveryDirectory() {
            throw CodexAutomationSynchronizationError.recoveryRequired(recovery.path)
        }
        let initialRead = CodexAutomationReader(rootURL: rootURL, fileManager: fileManager)
            .readManagedAutomations()
        guard case .available(let existingTasks) = initialRead else {
            throw CodexAutomationSynchronizationError.unreadableState
        }
        let existingIDs = Set(existingTasks.map(\.id))
        for task in existingTasks {
            let directory = rootURL.appendingPathComponent(task.id, isDirectory: true)
            let file = directory.appendingPathComponent("automation.toml")
            guard directory.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL,
                  fileManager.fileExists(atPath: file.path) else {
                throw CodexAutomationSynchronizationError.unsafeManagedTask
            }
        }

        let desiredEntries = entries.filter(\.isEnabled)
        let desiredIDs = Set(desiredEntries.map { identifier(for: $0.time) })
        for id in desiredIDs where !existingIDs.contains(id) {
            guard !fileManager.fileExists(atPath: rootURL.appendingPathComponent(id).path) else {
                throw CodexAutomationSynchronizationError.targetCollision
            }
        }

        let transactionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAutomationSync-\(UUID().uuidString)", isDirectory: true)
        let stagedRoot = transactionRoot.appendingPathComponent("staged", isDirectory: true)
        let recoveryRoot = rootURL.appendingPathComponent(
            ".codexquotamenu-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: transactionRoot) }
        var removeRecoveryOnExit = true
        defer {
            if removeRecoveryOnExit {
                try? fileManager.removeItem(at: recoveryRoot)
            }
        }

        let timestamp = timestampProvider()
        var stagedSources: [String: Data] = [:]
        for entry in desiredEntries {
            let id = identifier(for: entry.time)
            let directory = stagedRoot.appendingPathComponent(id, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Data(source(
                for: entry.time,
                timeZoneIdentifier: timeZoneIdentifier,
                timestamp: timestamp
            ).utf8)
            try data.write(to: directory.appendingPathComponent("automation.toml"), options: .atomic)
            stagedSources[id] = data
        }
        guard isExpectedState(evaluate(
            rootURL: stagedRoot,
            entries: entries,
            timeZoneIdentifier: timeZoneIdentifier
        ), desiredEntries: desiredEntries) else {
            throw CodexAutomationSynchronizationError.verificationFailed
        }

        for task in existingTasks {
            try fileManager.copyItem(
                at: rootURL.appendingPathComponent(task.id, isDirectory: true),
                to: recoveryRoot.appendingPathComponent(task.id, isDirectory: true)
            )
        }

        var installedSources: [String: Data] = [:]
        do {
            for task in existingTasks {
                try fileManager.removeItem(at: rootURL.appendingPathComponent(task.id, isDirectory: true))
            }
            for id in desiredIDs.sorted() {
                try hooks.beforeInstallingTask(id)
                try fileManager.moveItem(
                    at: stagedRoot.appendingPathComponent(id, isDirectory: true),
                    to: rootURL.appendingPathComponent(id, isDirectory: true)
                )
                installedSources[id] = stagedSources[id]
            }

            guard isExpectedState(evaluate(
                rootURL: rootURL,
                entries: entries,
                timeZoneIdentifier: timeZoneIdentifier
            ), desiredEntries: desiredEntries) else {
                throw CodexAutomationSynchronizationError.verificationFailed
            }
        } catch let synchronizationError {
            do {
                try hooks.beforeRollback()
                try rollback(
                    installedSources: installedSources,
                    existingTasks: existingTasks,
                    recoveryRoot: recoveryRoot
                )
            } catch {
                removeRecoveryOnExit = false
                throw CodexAutomationSynchronizationError.recoveryRequired(recoveryRoot.path)
            }
            throw synchronizationError
        }
    }

    func removeAllManagedAutomations() throws {
        try synchronize(entries: [], timeZoneIdentifier: "UTC")
    }

    private func existingRecoveryDirectory() throws -> URL? {
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        return children.first {
            $0.lastPathComponent.hasPrefix(".codexquotamenu-recovery-")
        }
    }

    private func rollback(
        installedSources: [String: Data],
        existingTasks: [CodexAutomation],
        recoveryRoot: URL
    ) throws {
        for (id, expectedSource) in installedSources {
            let directory = rootURL.appendingPathComponent(id, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let file = directory.appendingPathComponent("automation.toml")
            guard try Data(contentsOf: file) == expectedSource else {
                throw RollbackError.destinationChanged
            }
            try fileManager.removeItem(at: directory)
        }

        for task in existingTasks {
            let backup = recoveryRoot.appendingPathComponent(task.id, isDirectory: true)
            let destination = rootURL.appendingPathComponent(task.id, isDirectory: true)
            guard fileManager.fileExists(atPath: backup.path) else {
                throw RollbackError.missingBackup
            }
            if fileManager.fileExists(atPath: destination.path) {
                guard try automationSource(at: destination) == automationSource(at: backup) else {
                    throw RollbackError.destinationChanged
                }
                continue
            }
            try fileManager.copyItem(at: backup, to: destination)
            guard try automationSource(at: destination) == automationSource(at: backup) else {
                throw RollbackError.restoreVerificationFailed
            }
        }
    }

    private func automationSource(at directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("automation.toml"))
    }

    private func evaluate(
        rootURL: URL,
        entries: [ActivationScheduleEntry],
        timeZoneIdentifier: String
    ) -> AutomationSyncState {
        let result = CodexAutomationReader(rootURL: rootURL, fileManager: fileManager)
            .readManagedAutomations()
        return LegacyAutomationReconciler.evaluate(
            entries: entries,
            readResult: result,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func isExpectedState(
        _ state: AutomationSyncState,
        desiredEntries: [ActivationScheduleEntry]
    ) -> Bool {
        desiredEntries.isEmpty ? state == .unconfigured : state == .synced
    }

    private func identifier(for time: ActivationTime) -> String {
        String(format: "codexquotamenu-%02d-%02d", time.hour, time.minute)
    }

    private func source(
        for time: ActivationTime,
        timeZoneIdentifier: String,
        timestamp: Int64
    ) -> String {
        let id = identifier(for: time)
        return """
        version = 1
        id = "\(id)"
        kind = "cron"
        name = "\(ManagedAutomationPolicy.name(for: time))"
        prompt = "\(ManagedAutomationPolicy.activationPrompt)"
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute);TZID=\(timeZoneIdentifier)"
        model = "\(ManagedAutomationPolicy.model)"
        reasoning_effort = "\(ManagedAutomationPolicy.reasoningEffort)"
        notification_policy = "\(ManagedAutomationPolicy.notificationPolicy)"
        execution_environment = "local"
        target = { type = "projectless" }
        cwds = ["~"]
        created_at = \(timestamp)
        updated_at = \(timestamp)

        """
    }
}

private enum RollbackError: Error {
    case destinationChanged
    case missingBackup
    case restoreVerificationFailed
}

private enum LegacyAutomationReconciler {
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
        difference.duplicate = grouped.compactMap { time, values in values.count > 1 ? time : nil }.sorted()
        difference.paused = uniqueSorted(tasks.compactMap { time, task in task.status == "ACTIVE" ? nil : time })
        difference.misconfigured = uniqueSorted(tasks.compactMap { time, task in
            guard desired.contains(time) else { return nil }
            return matchesPolicy(task, time: time, timeZoneIdentifier: timeZoneIdentifier) ? nil : time
        })
        difference.unmatchedNames = readTasks.map(\.name).filter(ManagedAutomationPolicy.isMalformedPrefixedName).sorted()

        if desired.isEmpty && tasks.isEmpty { return .unconfigured }
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

    private static func matchesDailyRRule(_ rrule: String, time: ActivationTime, timeZoneIdentifier: String) -> Bool {
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
        return Set(fields.keys).isSubset(of: allowedKeys)
            && fields["FREQ"]?.uppercased() == "DAILY"
            && fields["BYHOUR"].flatMap(Int.init) == time.hour
            && fields["BYMINUTE"].flatMap(Int.init) == time.minute
            && fields["TZID"] == timeZoneIdentifier
    }

    private static func uniqueSorted(_ values: [ActivationTime]) -> [ActivationTime] {
        Array(Set(values)).sorted()
    }
}
