import CryptoKit
import Darwin
import Foundation

/// Refresh launchd's cached executable constraints after replacing an ad-hoc signed app.
/// Only installed schedules are reloaded; saved, unapplied edits are never applied here.
struct ActivationLaunchRegistration {
    private static let refreshLock = NSLock()
    static let storageKey = "activationSchedule.verifiedRegistration.v1"
    static let probeFlag = "--activation-launch-probe"

    let defaults: UserDefaults
    let controller: any LaunchctlControlling
    let runner: any LaunchctlCommandRunning

    init(defaults: UserDefaults = .standard,
         controller: any LaunchctlControlling = LaunchctlController(),
         runner: any LaunchctlCommandRunning = LaunchctlProcessRunner()) {
        self.defaults = defaults
        self.controller = controller
        self.runner = runner
    }

    func refresh(policy: ActivationLaunchAgentPolicy, directory: URL) throws {
        Self.refreshLock.lock()
        defer { Self.refreshLock.unlock() }
        guard let executable = policy.runnerURL else { return }
        guard case .available(let agents) = ActivationLaunchAgentReader(
            policy: policy, directoryURL: directory
        ).read() else { throw ActivationLaunchAgentSynchronizationError.unreadableState }
        let installed = agents.filter { $0.programArguments.first == executable.path }
        guard !installed.isEmpty else { return }
        let binary = try Data(contentsOf: executable)
        var fingerprints: [String: String] = [:]
        for agent in installed {
            let file = policy.fileURL(for: agent.time, in: directory)
            fingerprints[agent.label] = Self.fingerprint(
                executablePath: executable.path, binary: binary, plist: try Data(contentsOf: file)
            )
        }
        try refresh(agents: installed, fingerprints: fingerprints,
                    fileURL: { policy.fileURL(for: $0.time, in: directory) },
                    verify: { try verifyLaunch(executable: executable, home: policy.homeDirectory) })
    }

    static func fingerprint(executablePath: String, binary: Data, plist: Data) -> String {
        var hash = SHA256()
        hash.update(data: Data(executablePath.utf8))
        hash.update(data: binary)
        hash.update(data: plist)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Kept separate so update detection and failure handling can be tested without launchd.
    func refresh(agents: [ActivationLaunchAgent], fingerprints: [String: String],
                 fileURL: (ActivationLaunchAgent) -> URL, verify: () throws -> Void) throws {
        let previous = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        var changed = false
        for agent in agents {
            let loaded = try controller.isLoaded(label: agent.label)
            guard previous[agent.label] != fingerprints[agent.label] || !loaded else { continue }
            if loaded {
                let result = try runner.run(arguments: ["print", "gui/\(getuid())/\(agent.label)"])
                guard result.terminationStatus == 0, !result.standardOutputWasTruncated else {
                    throw ActivationLaunchAgentSynchronizationError.unreadableState
                }
                // Never interrupt an activation that is already executing.
                guard !result.standardOutput.split(separator: "\n").contains(where: {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ")
                }) else { throw ActivationLaunchAgentSynchronizationError.verificationFailed }
                try controller.bootout(label: agent.label)
            }
            try controller.bootstrap(plistURL: fileURL(agent))
            guard try controller.isLoaded(label: agent.label) else {
                throw ActivationLaunchAgentSynchronizationError.verificationFailed
            }
            changed = true
        }
        guard changed else { return }
        try verify()
        // A failed registration or launch must be retried, not cached as successful.
        defaults.set(fingerprints, forKey: Self.storageKey)
    }

    func verifyLaunch(executable: URL, home: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexActivationProbe-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let label = "com.local.codexquotamenu.activation-probe.\(UUID().uuidString)"
        let file = directory.appendingPathComponent("probe.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": label, "ProgramArguments": [executable.path, Self.probeFlag],
            "RunAtLoad": true, "WorkingDirectory": home.path,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"
        ], format: .xml, options: 0)
        try data.write(to: file, options: .atomic)
        try controller.bootstrap(plistURL: file)
        let outcome = Result { try waitForProbe(label: label) }
        // Report cleanup failures too, rather than leaving a hidden registered probe.
        try controller.bootout(label: label)
        try outcome.get()
    }

    private func waitForProbe(label: String) throws {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let result = try runner.run(arguments: ["print", "gui/\(getuid())/\(label)"])
            guard result.terminationStatus == 0, !result.standardOutputWasTruncated else {
                throw ActivationLaunchAgentSynchronizationError.verificationFailed
            }
            let lines = result.standardOutput.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if lines.contains("last exit code = 0") { return }
            if lines.contains(where: { $0.hasPrefix("last exit code = ") || $0.hasPrefix("last exit reason = ") }) {
                throw ActivationLaunchAgentSynchronizationError.verificationFailed
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw ActivationLaunchAgentSynchronizationError.verificationFailed
    }
}
