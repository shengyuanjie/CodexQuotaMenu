import CryptoKit
import Darwin
import Foundation

protocol ActivationLaunchAgentSynchronizing {
    func synchronize(entries: [ActivationScheduleEntry]) throws
}

enum ActivationLaunchAgentSynchronizationError: Error, Equatable, Sendable {
    case codexExecutableUnavailable
    case capabilityProbeFailed
    case unsupportedCodexCLI
    case unreadableState
    case targetCollision
    case verificationFailed
    case recoveryRequired(String)
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
        try fileManager.createDirectory(at: captureRoot, withIntermediateDirectories: false)
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
    var beforeRollback: () throws -> Void

    init(
        beforeInstallingAgent: @escaping (URL) throws -> Void = { _ in },
        beforeRollback: @escaping () throws -> Void = {}
    ) {
        self.beforeInstallingAgent = beforeInstallingAgent
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
            try CodexAutomationSynchronizer(
                rootURL: legacyAutomationsRootURL,
                fileManager: fileManager
            ).removeAllManagedAutomations()
        }
    }

    func synchronize(entries: [ActivationScheduleEntry]) throws {
        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        if let recovery = try existingRecoveryDirectory() {
            throw ActivationLaunchAgentSynchronizationError.recoveryRequired(recovery.path)
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
        let backups: [LaunchAgentBackup]
        do {
            backups = try createVerifiedBackups(
                of: initialAgents,
                policy: policy,
                recoveryRoot: recoveryRoot
            )
        } catch {
            try removeRecoveryOrThrow(recoveryRoot)
            throw error
        }

        var installedHashes: [URL: Data] = [:]
        var attemptedBootstrapLabels = Set<String>()
        do {
            for label in initialLoadedLabels.sorted() {
                try controller.bootout(label: label)
            }
            for backup in backups {
                guard try fileHash(at: backup.destinationURL) == backup.hash else {
                    throw ActivationLaunchAgentSynchronizationError.targetCollision
                }
                try fileManager.removeItem(at: backup.destinationURL)
            }
            for agent in desiredAgents {
                let destination = policy.fileURL(for: agent.time, in: launchAgentsURL)
                try hooks.beforeInstallingAgent(destination)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ActivationLaunchAgentSynchronizationError.targetCollision
                }
                let staged = policy.fileURL(for: agent.time, in: stagingRoot)
                try installExclusively(staged, at: destination)
                installedHashes[destination] = try fileHash(at: destination)
                attemptedBootstrapLabels.insert(agent.label)
                try controller.bootstrap(plistURL: destination)
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
            do {
                try hooks.beforeRollback()
                try rollback(
                    initialLoadedLabels: initialLoadedLabels,
                    attemptedBootstrapLabels: attemptedBootstrapLabels,
                    installedHashes: installedHashes,
                    backups: backups,
                    recoveryRoot: recoveryRoot
                )
            } catch {
                throw ActivationLaunchAgentSynchronizationError.recoveryRequired(recoveryRoot.path)
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
            let hash = try fileHash(at: source)
            try fileManager.copyItem(at: source, to: backup)
            guard try fileHash(at: backup) == hash else {
                throw LaunchAgentRollbackError.backupVerificationFailed
            }
            return LaunchAgentBackup(
                agent: agent,
                destinationURL: source,
                backupURL: backup,
                hash: hash
            )
        }
    }

    private func rollback(
        initialLoadedLabels: Set<String>,
        attemptedBootstrapLabels: Set<String>,
        installedHashes: [URL: Data],
        backups: [LaunchAgentBackup],
        recoveryRoot: URL
    ) throws {
        let currentlyLoaded = try controller.loadedOwnedLabels()
        for label in attemptedBootstrapLabels.intersection(currentlyLoaded).sorted() {
            try controller.bootout(label: label)
        }

        for (file, expectedHash) in installedHashes.sorted(by: { $0.key.path < $1.key.path }) {
            guard fileManager.fileExists(atPath: file.path) else { continue }
            guard try fileHash(at: file) == expectedHash else {
                throw LaunchAgentRollbackError.destinationChanged
            }
            try fileManager.removeItem(at: file)
        }

        for backup in backups {
            if fileManager.fileExists(atPath: backup.destinationURL.path) {
                guard try fileHash(at: backup.destinationURL) == backup.hash else {
                    throw LaunchAgentRollbackError.destinationChanged
                }
            } else {
                try fileManager.copyItem(at: backup.backupURL, to: backup.destinationURL)
            }
            guard try fileHash(at: backup.destinationURL) == backup.hash else {
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

        try fileManager.removeItem(at: recoveryRoot)
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
            throw ActivationLaunchAgentSynchronizationError.recoveryRequired(recoveryRoot.path)
        }
    }
}

private struct LaunchAgentBackup {
    let agent: ActivationLaunchAgent
    let destinationURL: URL
    let backupURL: URL
    let hash: Data
}

private enum LaunchAgentRollbackError: Error {
    case backupVerificationFailed
    case destinationChanged
    case missingLoadableBackup
    case restoreVerificationFailed
}
