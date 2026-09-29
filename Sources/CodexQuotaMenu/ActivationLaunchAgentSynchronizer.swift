import CryptoKit
import Darwin
import Foundation

protocol ActivationLaunchAgentSynchronizing {
    func synchronize(entries: [ActivationScheduleEntry]) throws
}

enum LegacyAutomationMigrationError: LocalizedError {
    case pauseRequired

    var errorDescription: String? {
        "请先在 Codex 的定时任务页面暂停旧的 CodexQuotaMenu 任务，再同步。Please pause the old CodexQuotaMenu automations in Codex before syncing."
    }
}

struct LegacyAutomationMigrationCheck {
    static func verify(rootURL: URL, fileManager: FileManager = .default) throws {
        guard case .available(let tasks) = CodexAutomationReader(
            rootURL: rootURL, fileManager: fileManager
        ).readManagedAutomations() else {
            throw ActivationLaunchAgentSynchronizationError.unreadableState
        }
        // Removing TOML files does not acknowledge cancellation in the app scheduler.
        // Leave paused records intact; cancellation belongs to Codex's task manager.
        guard tasks.allSatisfy({ $0.status == "PAUSED" }) else {
            throw LegacyAutomationMigrationError.pauseRequired
        }
    }
}

enum ActivationLaunchAgentSynchronizationError: Error, Equatable, Sendable {
    case codexExecutableUnavailable
    case capabilityProbeFailed
    case unsupportedCodexCLI
    case unreadableState
    case targetCollision
    case verificationFailed
    case recoveryRequired([String])
}

struct CodexCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool

    init(
        terminationStatus: Int32,
        standardOutput: String = "",
        standardError: String = "",
        timedOut: Bool = false
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

protocol CodexCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CodexCommandResult
}

struct CodexProcessRunner: CodexCommandRunning {
    private static let maximumCapturedBytes = 1_048_576

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CodexCommandResult {
        let fileManager = FileManager.default
        let captureRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexCapabilityProbe-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: captureRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: captureRoot) }

        let outputURL = captureRoot.appendingPathComponent("stdout")
        let errorURL = captureRoot.appendingPathComponent("stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw ActivationLaunchAgentSynchronizationError.capabilityProbeFailed
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        let deadline = DispatchTime.now() + .milliseconds(max(1, Int(timeout * 1_000)))
        let timedOut = completion.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .seconds(1)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                completion.wait()
            }
        }
        try outputHandle.synchronize()
        try errorHandle.synchronize()

        return CodexCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: capturedString(at: outputURL),
            standardError: capturedString(at: errorURL),
            timedOut: timedOut
        )
    }

    private func capturedString(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "" }
        return String(decoding: data.prefix(Self.maximumCapturedBytes), as: UTF8.self)
    }
}

struct ActivationLaunchAgentSynchronizationHooks {
    var beforeInstallingAgent: (URL) throws -> Void
    var afterInstallingAgent: (URL) throws -> Void
    var beforeIsolatingExistingAgent: (URL) throws -> Void
    var beforeIsolatingInstalledAgentDuringRollback: (URL) throws -> Void
    var beforeRollback: () throws -> Void

    init(
        beforeInstallingAgent: @escaping (URL) throws -> Void = { _ in },
        afterInstallingAgent: @escaping (URL) throws -> Void = { _ in },
        beforeIsolatingExistingAgent: @escaping (URL) throws -> Void = { _ in },
        beforeIsolatingInstalledAgentDuringRollback: @escaping (URL) throws -> Void = { _ in },
        beforeRollback: @escaping () throws -> Void = {}
    ) {
        self.beforeInstallingAgent = beforeInstallingAgent
        self.afterInstallingAgent = afterInstallingAgent
        self.beforeIsolatingExistingAgent = beforeIsolatingExistingAgent
        self.beforeIsolatingInstalledAgentDuringRollback = beforeIsolatingInstalledAgentDuringRollback
        self.beforeRollback = beforeRollback
    }
}

struct ActivationLaunchAgentSynchronizer: ActivationLaunchAgentSynchronizing {
    static let capabilityProbeTimeout: TimeInterval = 5
    private static let recoveryPrefix = ".codexquotamenu-launchagent-recovery-"
    private static let stagingPrefix = ".codexquotamenu-launchagent-staging-"
    private static let requiredSafetyOptions: Set<String> = [
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules"
    ]

    let launchAgentsURL: URL
    let legacyAutomationsRootURL: URL
    let homeDirectory: URL
    let fileManager: FileManager
    let executableLocator: any CodexExecutableLocating
    let commandRunner: any CodexCommandRunning
    let controller: any LaunchctlControlling
    let hooks: ActivationLaunchAgentSynchronizationHooks
    private let legacyAutomationRemover: () throws -> Void

    init(
        launchAgentsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        legacyAutomationsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/automations", isDirectory: true),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        executableLocator: any CodexExecutableLocating = CodexExecutableLocator(),
        commandRunner: any CodexCommandRunning = CodexProcessRunner(),
        controller: any LaunchctlControlling = LaunchctlController(),
        hooks: ActivationLaunchAgentSynchronizationHooks = .init(),
        legacyAutomationRemover: (() throws -> Void)? = nil
    ) {
        self.launchAgentsURL = launchAgentsURL
        self.legacyAutomationsRootURL = legacyAutomationsRootURL
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.executableLocator = executableLocator
        self.commandRunner = commandRunner
        self.controller = controller
        self.hooks = hooks
        self.legacyAutomationRemover = legacyAutomationRemover ?? {
            try LegacyAutomationMigrationCheck.verify(
                rootURL: legacyAutomationsRootURL,
                fileManager: fileManager
            )
        }
    }

    func synchronize(entries: [ActivationScheduleEntry]) throws {
        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        if let recovery = try existingRecoveryDirectory() {
            throw ActivationLaunchAgentSynchronizationError.recoveryRequired([recovery.path])
        }

        let normalizedEntries = try ActivationScheduleEntry.normalized(entries)
        let codexURL: URL
        do {
            codexURL = try executableLocator.findExecutable()
        } catch {
            throw ActivationLaunchAgentSynchronizationError.codexExecutableUnavailable
        }
        try verifyCapabilities(of: codexURL)

        guard case .available = CodexAutomationReader(
            rootURL: legacyAutomationsRootURL,
            fileManager: fileManager
        ).readManagedAutomations() else {
            throw ActivationLaunchAgentSynchronizationError.unreadableState
        }

        let policy = ActivationLaunchAgentPolicy(codexURL: codexURL, homeDirectory: homeDirectory)
        let initialAgents: [ActivationLaunchAgent]
        switch ActivationLaunchAgentReader(
            policy: policy,
            directoryURL: launchAgentsURL,
            fileManager: fileManager
        ).read() {
        case .available(let agents):
            initialAgents = agents
        case .unavailable:
            throw ActivationLaunchAgentSynchronizationError.unreadableState
        }
        let initialLoadedLabels: Set<String>
        do {
            initialLoadedLabels = try controller.loadedOwnedLabels()
        } catch {
            throw ActivationLaunchAgentSynchronizationError.unreadableState
        }

        let desiredAgents = normalizedEntries.filter(\.isEnabled).map { policy.agent(for: $0.time) }
        let stagingRoot = launchAgentsURL.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try stageAndVerify(desiredAgents, policy: policy, at: stagingRoot)

        let existingURLs = Set(initialAgents.map { policy.fileURL(for: $0.time, in: launchAgentsURL) })
        for agent in desiredAgents {
            let destination = policy.fileURL(for: agent.time, in: launchAgentsURL)
            if !existingURLs.contains(destination), fileManager.fileExists(atPath: destination.path) {
                throw ActivationLaunchAgentSynchronizationError.targetCollision
            }
        }

        let recoveryRoot = launchAgentsURL.appendingPathComponent(
            Self.recoveryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: false)
        let isolatedExistingRoot = recoveryRoot.appendingPathComponent(
            "isolated-existing",
            isDirectory: true
        )
        let isolatedInstalledRoot = recoveryRoot.appendingPathComponent(
            "isolated-installed",
            isDirectory: true
        )
        let restoreStagingRoot = recoveryRoot.appendingPathComponent(
            "restore-staging",
            isDirectory: true
        )
        let backups: [LaunchAgentBackup]
        do {
            for directory in [isolatedExistingRoot, isolatedInstalledRoot, restoreStagingRoot] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            backups = try createVerifiedBackups(
                of: initialAgents,
                policy: policy,
                recoveryRoot: recoveryRoot
            )
        } catch {
            try removeRecoveryOrThrow(recoveryRoot)
            throw error
        }

        var installedFingerprints: [URL: FileFingerprint] = [:]
        var successfullyBootstrappedLabels = Set<String>()
        do {
            for label in initialLoadedLabels.sorted() {
                try controller.bootout(label: label)
            }
            for backup in backups {
                try hooks.beforeIsolatingExistingAgent(backup.destinationURL)
                try isolateExpectedFile(
                    at: backup.destinationURL,
                    to: isolatedExistingRoot.appendingPathComponent(
                        backup.destinationURL.lastPathComponent
                    ),
                    expectedFingerprint: backup.originalFingerprint,
                    missingIsAcceptable: false
                )
            }
            for agent in desiredAgents {
                let destination = policy.fileURL(for: agent.time, in: launchAgentsURL)
                try hooks.beforeInstallingAgent(destination)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ActivationLaunchAgentSynchronizationError.targetCollision
                }
                let staged = policy.fileURL(for: agent.time, in: stagingRoot)
                let expectedFingerprint = try fileFingerprint(at: staged)
                try installExclusively(staged, at: destination)
                try hooks.afterInstallingAgent(destination)
                installedFingerprints[destination] = expectedFingerprint
                try controller.bootstrap(plistURL: destination)
                successfullyBootstrappedLabels.insert(agent.label)
            }

            let finalSnapshot = ActivationSchedulerSnapshot.read(
                readResult: ActivationLaunchAgentReader(
                    policy: policy,
                    directoryURL: launchAgentsURL,
                    fileManager: fileManager
                ).read(),
                controller: controller
            )
            let finalState = ActivationLaunchAgentReconciler.evaluate(
                entries: normalizedEntries,
                snapshot: finalSnapshot
            )
            let expectedFinalState: AutomationSyncState = desiredAgents.isEmpty ? .unconfigured : .synced
            guard finalState == expectedFinalState else {
                throw ActivationLaunchAgentSynchronizationError.verificationFailed
            }

            try legacyAutomationRemover()
        } catch let synchronizationError {
            let mustRetainRecovery = synchronizationError is LaunchAgentIsolationError
            let inheritedRecoveryPaths = recoveryPaths(from: synchronizationError)
            do {
                try hooks.beforeRollback()
                try rollback(
                    initialLoadedLabels: initialLoadedLabels,
                    successfullyBootstrappedLabels: successfullyBootstrappedLabels,
                    installedFingerprints: installedFingerprints,
                    backups: backups,
                    isolatedInstalledRoot: isolatedInstalledRoot,
                    restoreStagingRoot: restoreStagingRoot,
                    recoveryRoot: recoveryRoot,
                    removeRecoveryOnSuccess: !mustRetainRecovery
                )
            } catch {
                throw ActivationLaunchAgentSynchronizationError.recoveryRequired(
                    uniquePaths(inheritedRecoveryPaths + [recoveryRoot.path])
                )
            }
            if mustRetainRecovery {
                throw ActivationLaunchAgentSynchronizationError.recoveryRequired(
                    uniquePaths(inheritedRecoveryPaths + [recoveryRoot.path])
                )
            }
            if !inheritedRecoveryPaths.isEmpty {
                throw ActivationLaunchAgentSynchronizationError.recoveryRequired(
                    inheritedRecoveryPaths
                )
            }
            throw synchronizationError
        }

        try removeRecoveryOrThrow(recoveryRoot)
    }

    private func verifyCapabilities(of codexURL: URL) throws {
        let result: CodexCommandResult
        do {
            result = try commandRunner.run(
                executableURL: codexURL,
                arguments: ["exec", "--help"],
                timeout: Self.capabilityProbeTimeout
            )
        } catch {
            throw ActivationLaunchAgentSynchronizationError.capabilityProbeFailed
        }
        guard !result.timedOut, result.terminationStatus == 0 else {
            throw ActivationLaunchAgentSynchronizationError.capabilityProbeFailed
        }
        let optionCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let optionTokens = Set(
            (result.standardOutput + "\n" + result.standardError)
                .components(separatedBy: optionCharacters.inverted)
                .filter { $0.hasPrefix("--") }
        )
        guard Self.requiredSafetyOptions.isSubset(of: optionTokens) else {
            throw ActivationLaunchAgentSynchronizationError.unsupportedCodexCLI
        }
    }

    private func stageAndVerify(
        _ agents: [ActivationLaunchAgent],
        policy: ActivationLaunchAgentPolicy,
        at stagingRoot: URL
    ) throws {
        for agent in agents {
            try agent.xmlData().write(
                to: policy.fileURL(for: agent.time, in: stagingRoot),
                options: .atomic
            )
        }
        guard case .available(let stagedAgents) = ActivationLaunchAgentReader(
            policy: policy,
            directoryURL: stagingRoot,
            fileManager: fileManager
        ).read(), stagedAgents == agents else {
            throw ActivationLaunchAgentSynchronizationError.verificationFailed
        }
    }

    private func createVerifiedBackups(
        of agents: [ActivationLaunchAgent],
        policy: ActivationLaunchAgentPolicy,
        recoveryRoot: URL
    ) throws -> [LaunchAgentBackup] {
        try agents.map { agent in
            let source = policy.fileURL(for: agent.time, in: launchAgentsURL)
            let backup = policy.fileURL(for: agent.time, in: recoveryRoot)
            let originalFingerprint = try fileFingerprint(at: source)
            try fileManager.copyItem(at: source, to: backup)
            guard try fileHash(at: backup) == originalFingerprint.hash else {
                throw LaunchAgentRollbackError.backupVerificationFailed
            }
            return LaunchAgentBackup(
                agent: agent,
                destinationURL: source,
                backupURL: backup,
                originalFingerprint: originalFingerprint
            )
        }
    }

    private func rollback(
        initialLoadedLabels: Set<String>,
        successfullyBootstrappedLabels: Set<String>,
        installedFingerprints: [URL: FileFingerprint],
        backups: [LaunchAgentBackup],
        isolatedInstalledRoot: URL,
        restoreStagingRoot: URL,
        recoveryRoot: URL,
        removeRecoveryOnSuccess: Bool
    ) throws {
        let currentlyLoaded = try controller.loadedOwnedLabels()
        for label in successfullyBootstrappedLabels.intersection(currentlyLoaded).sorted() {
            try controller.bootout(label: label)
        }

        for (file, expectedFingerprint) in installedFingerprints.sorted(
            by: { $0.key.path < $1.key.path }
        ) {
            try hooks.beforeIsolatingInstalledAgentDuringRollback(file)
            try isolateExpectedFile(
                at: file,
                to: isolatedInstalledRoot.appendingPathComponent(file.lastPathComponent),
                expectedFingerprint: expectedFingerprint,
                missingIsAcceptable: true
            )
        }

        for backup in backups {
            if fileManager.fileExists(atPath: backup.destinationURL.path) {
                guard try fileHash(at: backup.destinationURL) == backup.originalFingerprint.hash else {
                    throw LaunchAgentRollbackError.destinationChanged
                }
            } else {
                let stagedRestore = restoreStagingRoot.appendingPathComponent(
                    UUID().uuidString + "-" + backup.destinationURL.lastPathComponent
                )
                try fileManager.copyItem(at: backup.backupURL, to: stagedRestore)
                guard try fileHash(at: stagedRestore) == backup.originalFingerprint.hash else {
                    throw LaunchAgentRollbackError.restoreVerificationFailed
                }
                try installExclusively(stagedRestore, at: backup.destinationURL)
            }
            guard try fileHash(at: backup.destinationURL) == backup.originalFingerprint.hash else {
                throw LaunchAgentRollbackError.restoreVerificationFailed
            }
        }

        let loadedAfterFileRestore = try controller.loadedOwnedLabels()
        for label in initialLoadedLabels.subtracting(loadedAfterFileRestore).sorted() {
            guard let backup = backups.first(where: { $0.agent.label == label }) else {
                throw LaunchAgentRollbackError.missingLoadableBackup
            }
            try controller.bootstrap(plistURL: backup.destinationURL)
        }

        guard try controller.loadedOwnedLabels() == initialLoadedLabels else {
            throw LaunchAgentRollbackError.restoreVerificationFailed
        }

        if removeRecoveryOnSuccess {
            try fileManager.removeItem(at: recoveryRoot)
        }
    }

    private func existingRecoveryDirectory() throws -> URL? {
        try fileManager.contentsOfDirectory(
            at: launchAgentsURL,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            $0.lastPathComponent.hasPrefix(Self.recoveryPrefix)
        }
    }

    private func fileHash(at url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private func fileFingerprint(at url: URL) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
            throw LaunchAgentRollbackError.unverifiableFileIdentity
        }
        return FileFingerprint(
            hash: try fileHash(at: url),
            systemNumber: systemNumber.uint64Value,
            fileNumber: fileNumber.uint64Value
        )
    }

    private func isolateExpectedFile(
        at source: URL,
        to isolated: URL,
        expectedFingerprint: FileFingerprint,
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
            throw LaunchAgentIsolationError.ownershipChanged
        }

        do {
            guard try fileFingerprint(at: isolated) == expectedFingerprint else {
                throw LaunchAgentIsolationError.ownershipChanged
            }
        } catch {
            do {
                try installExclusively(isolated, at: source)
            } catch {
                // The isolated object remains in recovery when the public path is occupied.
            }
            throw LaunchAgentIsolationError.ownershipChanged
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
                throw ActivationLaunchAgentSynchronizationError.targetCollision
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func removeRecoveryOrThrow(_ recoveryRoot: URL) throws {
        do {
            try fileManager.removeItem(at: recoveryRoot)
        } catch {
            throw ActivationLaunchAgentSynchronizationError.recoveryRequired([recoveryRoot.path])
        }
    }

    private func recoveryPaths(from error: Error) -> [String] {
        if case CodexAutomationSynchronizationError.recoveryRequired(let path) = error {
            return [path]
        }
        if case ActivationLaunchAgentSynchronizationError.recoveryRequired(let paths) = error {
            return uniquePaths(paths)
        }
        return []
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

private struct LaunchAgentBackup {
    let agent: ActivationLaunchAgent
    let destinationURL: URL
    let backupURL: URL
    let originalFingerprint: FileFingerprint
}

private struct FileFingerprint: Equatable {
    let hash: Data
    let systemNumber: UInt64
    let fileNumber: UInt64
}

private enum LaunchAgentRollbackError: Error {
    case backupVerificationFailed
    case destinationChanged
    case missingLoadableBackup
    case restoreVerificationFailed
    case unverifiableFileIdentity
}

private enum LaunchAgentIsolationError: Error {
    case ownershipChanged
}
