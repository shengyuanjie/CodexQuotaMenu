import CryptoKit
import Darwin
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
    var beforeIsolatingExistingTask: (URL) throws -> Void
    var beforeRollback: () throws -> Void

    init(
        beforeInstallingTask: @escaping (String) throws -> Void = { _ in },
        beforeIsolatingExistingTask: @escaping (URL) throws -> Void = { _ in },
        beforeRollback: @escaping () throws -> Void = {}
    ) {
        self.beforeInstallingTask = beforeInstallingTask
        self.beforeIsolatingExistingTask = beforeIsolatingExistingTask
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
        try fileManager.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transactionRoot) }

        let timestamp = timestampProvider()
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
        }
        guard isExpectedState(evaluate(
            rootURL: stagedRoot,
            entries: entries,
            timeZoneIdentifier: timeZoneIdentifier
        ), desiredEntries: desiredEntries) else {
            throw CodexAutomationSynchronizationError.verificationFailed
        }

        let recoveryRoot = rootURL.appendingPathComponent(
            ".codexquotamenu-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let isolatedExistingRoot = recoveryRoot.appendingPathComponent(
            "isolated-existing",
            isDirectory: true
        )
        let isolatedInstalledRoot = recoveryRoot.appendingPathComponent(
            "isolated-installed",
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        do {
            try fileManager.createDirectory(
                at: isolatedExistingRoot,
                withIntermediateDirectories: false
            )
            try fileManager.createDirectory(
                at: isolatedInstalledRoot,
                withIntermediateDirectories: false
            )
        } catch {
            try removeRecoveryOrThrow(recoveryRoot)
            throw error
        }

        let backups: [AutomationBackup]
        do {
            backups = try prepareBackups(
                for: existingTasks,
                isolatedExistingRoot: isolatedExistingRoot
            )
        } catch {
            try removeRecoveryOrThrow(recoveryRoot)
            throw error
        }

        var installedFingerprints: [URL: AutomationDirectoryFingerprint] = [:]
        do {
            for backup in backups {
                try hooks.beforeIsolatingExistingTask(backup.destinationURL)
                try isolateExpectedDirectory(
                    at: backup.destinationURL,
                    to: backup.isolatedURL,
                    expectedFingerprint: backup.originalFingerprint,
                    expectedTask: backup.task,
                    validationRoot: isolatedExistingRoot,
                    missingIsAcceptable: false
                )
            }
            for id in desiredIDs.sorted() {
                try hooks.beforeInstallingTask(id)
                let staged = stagedRoot.appendingPathComponent(id, isDirectory: true)
                let destination = rootURL.appendingPathComponent(id, isDirectory: true)
                let expectedFingerprint = try directoryFingerprint(at: staged)
                try installExclusively(staged, at: destination)
                installedFingerprints[destination] = expectedFingerprint
            }

            guard isExpectedState(evaluate(
                rootURL: rootURL,
                entries: entries,
                timeZoneIdentifier: timeZoneIdentifier
            ), desiredEntries: desiredEntries) else {
                throw CodexAutomationSynchronizationError.verificationFailed
            }
        } catch let synchronizationError {
            let mustRetainRecovery = synchronizationError is AutomationIsolationError
            do {
                try hooks.beforeRollback()
                try rollback(
                    installedFingerprints: installedFingerprints,
                    backups: backups,
                    isolatedInstalledRoot: isolatedInstalledRoot,
                    recoveryRoot: recoveryRoot,
                    removeRecoveryOnSuccess: !mustRetainRecovery
                )
            } catch {
                throw CodexAutomationSynchronizationError.recoveryRequired(recoveryRoot.path)
            }
            if mustRetainRecovery {
                throw CodexAutomationSynchronizationError.recoveryRequired(recoveryRoot.path)
            }
            throw synchronizationError
        }

        do {
            try verifyIsolatedBackups(backups, validationRoot: isolatedExistingRoot)
            try fileManager.removeItem(at: recoveryRoot)
        } catch {
            throw CodexAutomationSynchronizationError.recoveryRequired(recoveryRoot.path)
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

    private func prepareBackups(
        for tasks: [CodexAutomation],
        isolatedExistingRoot: URL
    ) throws -> [AutomationBackup] {
        let backups = try tasks.map { task in
            let destination = rootURL.appendingPathComponent(task.id, isDirectory: true)
            return AutomationBackup(
                task: task,
                destinationURL: destination,
                isolatedURL: isolatedExistingRoot.appendingPathComponent(
                    task.id,
                    isDirectory: true
                ),
                originalFingerprint: try directoryFingerprint(at: destination)
            )
        }
        guard CodexAutomationReader(rootURL: rootURL, fileManager: fileManager)
            .readManagedAutomations() == .available(tasks) else {
            throw CodexAutomationSynchronizationError.unsafeManagedTask
        }
        return backups
    }

    private func verifyIsolatedBackups(
        _ backups: [AutomationBackup],
        validationRoot: URL
    ) throws {
        for backup in backups {
            guard try directoryFingerprint(at: backup.isolatedURL) == backup.originalFingerprint,
                  isExpectedManagedTask(backup.task, in: validationRoot) else {
                throw RollbackError.restoreVerificationFailed
            }
        }
    }

    private func isExpectedManagedTask(_ task: CodexAutomation, in root: URL) -> Bool {
        guard ManagedAutomationPolicy.managedTime(from: task.name) != nil,
              case .available(let tasks) = CodexAutomationReader(
                rootURL: root,
                fileManager: fileManager
              ).readManagedAutomations() else {
            return false
        }
        return tasks.contains(task)
    }

    private func isolateExpectedDirectory(
        at source: URL,
        to isolated: URL,
        expectedFingerprint: AutomationDirectoryFingerprint,
        expectedTask: CodexAutomation?,
        validationRoot: URL?,
        missingIsAcceptable: Bool
    ) throws {
        let result = source.path.withCString { sourcePath in
            isolated.path.withCString { isolatedPath in
                renamex_np(sourcePath, isolatedPath, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            if errno == ENOENT, missingIsAcceptable {
                return
            }
            throw AutomationIsolationError.ownershipChanged
        }

        do {
            guard try directoryFingerprint(at: isolated) == expectedFingerprint else {
                throw AutomationIsolationError.ownershipChanged
            }
            if let expectedTask {
                guard let validationRoot,
                      isExpectedManagedTask(expectedTask, in: validationRoot) else {
                    throw AutomationIsolationError.ownershipChanged
                }
            }
        } catch {
            do {
                try installExclusively(isolated, at: source)
            } catch {
                // A concurrently occupied public path is never overwritten.
            }
            throw AutomationIsolationError.ownershipChanged
        }
    }

    private func installExclusively(_ staged: URL, at destination: URL) throws {
        let result = staged.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY {
                throw CodexAutomationSynchronizationError.targetCollision
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func directoryFingerprint(at root: URL) throws -> AutomationDirectoryFingerprint {
        var entries: [AutomationTreeEntryFingerprint] = []
        try appendFingerprintEntry(at: root, relativePath: ".", to: &entries)
        return AutomationDirectoryFingerprint(entries: entries)
    }

    private func appendFingerprintEntry(
        at url: URL,
        relativePath: String,
        to entries: inout [AutomationTreeEntryFingerprint]
    ) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
            throw RollbackError.unverifiableIdentity
        }
        let kind: AutomationTreeEntryFingerprint.Kind
        let hash: Data?
        switch type {
        case .typeDirectory:
            kind = .directory
            hash = nil
        case .typeRegular:
            kind = .regularFile
            hash = Data(SHA256.hash(data: try Data(contentsOf: url)))
        default:
            throw RollbackError.unverifiableIdentity
        }
        entries.append(.init(
            relativePath: relativePath,
            kind: kind,
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value,
            hash: hash
        ))
        guard kind == .directory else { return }
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let childPath = relativePath == "."
                ? child.lastPathComponent
                : relativePath + "/" + child.lastPathComponent
            try appendFingerprintEntry(at: child, relativePath: childPath, to: &entries)
        }
    }

    private func removeRecoveryOrThrow(_ recoveryRoot: URL) throws {
        do {
            try fileManager.removeItem(at: recoveryRoot)
        } catch {
            throw CodexAutomationSynchronizationError.recoveryRequired(recoveryRoot.path)
        }
    }

    private func rollback(
        installedFingerprints: [URL: AutomationDirectoryFingerprint],
        backups: [AutomationBackup],
        isolatedInstalledRoot: URL,
        recoveryRoot: URL,
        removeRecoveryOnSuccess: Bool
    ) throws {
        for (directory, expectedFingerprint) in installedFingerprints.sorted(
            by: { $0.key.path < $1.key.path }
        ) {
            try isolateExpectedDirectory(
                at: directory,
                to: isolatedInstalledRoot.appendingPathComponent(directory.lastPathComponent),
                expectedFingerprint: expectedFingerprint,
                expectedTask: nil,
                validationRoot: nil,
                missingIsAcceptable: true
            )
        }

        for backup in backups {
            guard fileManager.fileExists(atPath: backup.isolatedURL.path) else {
                throw RollbackError.missingBackup
            }
            guard try directoryFingerprint(at: backup.isolatedURL) == backup.originalFingerprint,
                  isExpectedManagedTask(
                    backup.task,
                    in: backup.isolatedURL.deletingLastPathComponent()
                  ) else {
                throw RollbackError.restoreVerificationFailed
            }
            guard !fileManager.fileExists(atPath: backup.destinationURL.path) else {
                throw RollbackError.destinationChanged
            }
            try installExclusively(backup.isolatedURL, at: backup.destinationURL)
            guard try directoryFingerprint(at: backup.destinationURL) == backup.originalFingerprint else {
                throw RollbackError.restoreVerificationFailed
            }
        }

        if removeRecoveryOnSuccess {
            try fileManager.removeItem(at: recoveryRoot)
        }
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
    case unverifiableIdentity
}

private struct AutomationBackup {
    let task: CodexAutomation
    let destinationURL: URL
    let isolatedURL: URL
    let originalFingerprint: AutomationDirectoryFingerprint
}

private struct AutomationDirectoryFingerprint: Equatable {
    let entries: [AutomationTreeEntryFingerprint]
}

private struct AutomationTreeEntryFingerprint: Equatable {
    enum Kind: Equatable {
        case directory
        case regularFile
    }

    let relativePath: String
    let kind: Kind
    let systemNumber: UInt64
    let fileNumber: UInt64
    let hash: Data?
}

private enum AutomationIsolationError: Error {
    case ownershipChanged
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
