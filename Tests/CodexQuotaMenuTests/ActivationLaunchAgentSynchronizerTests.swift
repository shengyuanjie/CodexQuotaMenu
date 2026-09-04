import Foundation
import XCTest
@testable import CodexQuotaMenu

final class ActivationLaunchAgentSynchronizerTests: XCTestCase {
    private let codexURL = URL(fileURLWithPath: "/fixtures/codex")
    private let homeURL = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testEnabledDisabledAndDeletedEntriesReconcileWithoutChangingUnownedFiles() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let unrelated = fixture.launchAgentsURL.appendingPathComponent("personal.agent.plist")
        let malformedPrefix = fixture.launchAgentsURL.appendingPathComponent(
            "com.local.codexquotamenu.activation.backup.plist"
        )
        let unrelatedData = Data("personal".utf8)
        let malformedData = Data("malformed prefix peer".utf8)
        try unrelatedData.write(to: unrelated)
        try malformedData.write(to: malformedPrefix)
        let six = try ActivationScheduleEntry(time: .init(hour: 6, minute: 0))
        let elevenDisabled = try ActivationScheduleEntry(
            time: .init(hour: 11, minute: 0),
            isEnabled: false
        )
        let synchronizer = fixture.synchronizer()

        try synchronizer.synchronize(entries: [six, elevenDisabled])

        XCTAssertTrue(fixture.fileExists(for: six.time))
        XCTAssertFalse(fixture.fileExists(for: elevenDisabled.time))
        XCTAssertEqual(fixture.controller.loadedLabels, [fixture.label(for: six.time)])

        let elevenEnabled = ActivationScheduleEntry(
            id: elevenDisabled.id,
            time: elevenDisabled.time,
            isEnabled: true
        )
        try synchronizer.synchronize(entries: [six, elevenEnabled])
        XCTAssertTrue(fixture.fileExists(for: elevenEnabled.time))
        XCTAssertEqual(
            fixture.controller.loadedLabels,
            [fixture.label(for: six.time), fixture.label(for: elevenEnabled.time)]
        )

        try synchronizer.synchronize(entries: [elevenEnabled])
        XCTAssertFalse(fixture.fileExists(for: six.time))
        XCTAssertTrue(fixture.fileExists(for: elevenEnabled.time))
        XCTAssertEqual(fixture.controller.loadedLabels, [fixture.label(for: elevenEnabled.time)])
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedData)
        XCTAssertEqual(try Data(contentsOf: malformedPrefix), malformedData)
    }

    func testDisablingEveryEntryAndThenDeletingItLeavesNoConfiguredOrLoadedAgent() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let six = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 0))
        let synchronizer = fixture.synchronizer()
        try synchronizer.synchronize(entries: [six])

        try synchronizer.synchronize(entries: [
            .init(id: six.id, time: six.time, isEnabled: false)
        ])

        XCTAssertFalse(fixture.fileExists(for: six.time))
        XCTAssertEqual(fixture.controller.loadedLabels, [])

        try synchronizer.synchronize(entries: [])

        XCTAssertFalse(fixture.fileExists(for: six.time))
        XCTAssertEqual(fixture.controller.loadedLabels, [])
        XCTAssertEqual(try fixture.recoveryDirectories(), [])
    }

    func testVerifiesNewLaunchAgentsBeforeRemovingExactLegacyAutomations() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let time = try ActivationTime(hour: 6, minute: 0)
        let legacyFile = try fixture.writeLegacyAutomation(id: "legacy-six", time: time)
        var stateObservedByLegacyRemoval: AutomationSyncState?
        let synchronizer = fixture.synchronizer(legacyAutomationRemover: {
            let policy = fixture.policy
            let readResult = ActivationLaunchAgentReader(
                policy: policy,
                directoryURL: fixture.launchAgentsURL
            ).read()
            stateObservedByLegacyRemoval = ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: time)],
                snapshot: ActivationSchedulerSnapshot.read(
                    readResult: readResult,
                    controller: fixture.controller
                )
            )
            try CodexAutomationSynchronizer(rootURL: fixture.automationsURL)
                .removeAllManagedAutomations()
        })

        try synchronizer.synchronize(entries: [.init(time: time)])

        XCTAssertEqual(stateObservedByLegacyRemoval, .synced)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    func testFailureBeforeLaunchAgentVerificationLeavesLegacyAutomationsUntouched() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let time = try ActivationTime(hour: 6, minute: 0)
        let legacyFile = try fixture.writeLegacyAutomation(id: "legacy-six", time: time)
        let legacySource = try Data(contentsOf: legacyFile)
        fixture.controller.bootstrapHandler = { _ in throw FixtureError.injected }

        XCTAssertThrowsError(try fixture.synchronizer().synchronize(entries: [.init(time: time)]))

        XCTAssertEqual(try Data(contentsOf: legacyFile), legacySource)
        XCTAssertFalse(fixture.fileExists(for: time))
        XCTAssertEqual(fixture.controller.loadedLabels, [])
    }

    func testLegacyRemovalFailureRollsBackAndVerifiesPreviousLaunchAgentState() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 0)
        let oldFile = fixture.policy.fileURL(for: six, in: fixture.launchAgentsURL)
        let oldData = try fixture.policy.agent(for: six).xmlData()
        try oldData.write(to: oldFile)
        fixture.controller.loadedLabels = [fixture.label(for: six)]
        let synchronizer = fixture.synchronizer(legacyAutomationRemover: {
            throw FixtureError.injected
        })

        XCTAssertThrowsError(try synchronizer.synchronize(entries: [.init(time: eleven)])) { error in
            guard case FixtureError.injected = error else {
                return XCTFail("expected injected legacy removal error, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: oldFile), oldData)
        XCTAssertFalse(fixture.fileExists(for: eleven))
        XCTAssertEqual(fixture.controller.loadedLabels, [fixture.label(for: six)])
        XCTAssertEqual(try fixture.recoveryDirectories(), [])
    }

    func testConcurrentTargetCreationIsNeverOverwrittenOrDeleted() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let six = try ActivationTime(hour: 6, minute: 0)
        let destination = fixture.policy.fileURL(for: six, in: fixture.launchAgentsURL)
        let concurrentData = Data("concurrent owner".utf8)
        let synchronizer = fixture.synchronizer(
            hooks: .init(beforeInstallingAgent: { url in
                XCTAssertEqual(url, destination)
                try concurrentData.write(to: url)
            })
        )

        XCTAssertThrowsError(try synchronizer.synchronize(entries: [.init(time: six)])) { error in
            XCTAssertEqual(error as? ActivationLaunchAgentSynchronizationError, .targetCollision)
        }

        XCTAssertEqual(try Data(contentsOf: destination), concurrentData)
        XCTAssertEqual(fixture.controller.loadedLabels, [])
        XCTAssertEqual(try fixture.recoveryDirectories(), [])
    }

    func testChangedInstalledFileIsRetainedWithRecoveryPathWhenRollbackCannotVerifyOwnership() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 0)
        let sixFile = fixture.policy.fileURL(for: six, in: fixture.launchAgentsURL)
        let changedData = Data("concurrent replacement".utf8)
        let synchronizer = fixture.synchronizer(
            hooks: .init(beforeInstallingAgent: { url in
                guard url == fixture.policy.fileURL(for: eleven, in: fixture.launchAgentsURL) else {
                    return
                }
                try changedData.write(to: sixFile, options: .atomic)
                throw FixtureError.injected
            })
        )
        var recoveryPath: String?

        XCTAssertThrowsError(try synchronizer.synchronize(entries: [
            .init(time: six),
            .init(time: eleven)
        ])) { error in
            guard case ActivationLaunchAgentSynchronizationError.recoveryRequired(let path) = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
            recoveryPath = path
        }

        XCTAssertEqual(try Data(contentsOf: sixFile), changedData)
        let path = try XCTUnwrap(recoveryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(URL(fileURLWithPath: path).lastPathComponent.hasPrefix(
            ".codexquotamenu-launchagent-recovery-"
        ))
    }

    func testExistingRecoveryDirectoryBlocksSynchronizationBeforeCapabilityProbe() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        let recovery = fixture.launchAgentsURL.appendingPathComponent(
            ".codexquotamenu-launchagent-recovery-existing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)

        XCTAssertThrowsError(try fixture.synchronizer().synchronize(entries: [])) { error in
            guard case ActivationLaunchAgentSynchronizationError.recoveryRequired(let path) = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
            XCTAssertEqual(
                URL(fileURLWithPath: path).resolvingSymlinksInPath(),
                recovery.resolvingSymlinksInPath()
            )
        }

        XCTAssertEqual(fixture.commandRunner.calls, [])
        XCTAssertEqual(fixture.locator.callCount, 0)
    }

    func testCapabilityProbeRequiresIndependentSafetyOptionTokens() throws {
        let fixture = try Fixture(
            codexURL: codexURL,
            homeURL: homeURL,
            helpOutput: "--ephemeral-mode --ignore-user-config --ignore-rules"
        )
        defer { fixture.remove() }

        XCTAssertThrowsError(try fixture.synchronizer().synchronize(entries: [])) { error in
            XCTAssertEqual(error as? ActivationLaunchAgentSynchronizationError, .unsupportedCodexCLI)
        }

        XCTAssertEqual(fixture.commandRunner.calls.count, 1)
        XCTAssertEqual(fixture.commandRunner.calls.first?.executableURL, codexURL)
        XCTAssertEqual(fixture.commandRunner.calls.first?.arguments, ["exec", "--help"])
        XCTAssertEqual(fixture.commandRunner.calls.first?.timeout, 5)
        XCTAssertEqual(try fixture.recoveryDirectories(), [])
    }

    func testCapabilityProbeTimeoutRejectsSynchronizationWithoutWriting() throws {
        let fixture = try Fixture(codexURL: codexURL, homeURL: homeURL)
        defer { fixture.remove() }
        fixture.commandRunner.result = .init(
            terminationStatus: 0,
            standardOutput: "--ephemeral --ignore-user-config --ignore-rules",
            standardError: "",
            timedOut: true
        )
        let six = try ActivationTime(hour: 6, minute: 0)

        XCTAssertThrowsError(try fixture.synchronizer().synchronize(entries: [.init(time: six)])) {
            error in
            XCTAssertEqual(error as? ActivationLaunchAgentSynchronizationError, .capabilityProbeFailed)
        }

        XCTAssertFalse(fixture.fileExists(for: six))
        XCTAssertEqual(fixture.controller.loadedLabels, [])
    }
}

private final class Fixture {
    let rootURL: URL
    let launchAgentsURL: URL
    let automationsURL: URL
    let policy: ActivationLaunchAgentPolicy
    let locator: FakeCodexExecutableLocator
    let commandRunner: FakeCodexCommandRunner
    let controller = FakeLaunchctlController()
    private let homeURL: URL

    init(
        codexURL: URL,
        homeURL: URL,
        helpOutput: String = "--ephemeral --ignore-user-config --ignore-rules"
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ActivationLaunchAgentSynchronizerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        launchAgentsURL = rootURL.appendingPathComponent("LaunchAgents", isDirectory: true)
        automationsURL = rootURL.appendingPathComponent("automations", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: automationsURL, withIntermediateDirectories: true)
        policy = ActivationLaunchAgentPolicy(codexURL: codexURL, homeDirectory: homeURL)
        locator = FakeCodexExecutableLocator(url: codexURL)
        commandRunner = FakeCodexCommandRunner(result: .init(
            terminationStatus: 0,
            standardOutput: helpOutput,
            standardError: ""
        ))
        self.homeURL = homeURL
    }

    func synchronizer(
        hooks: ActivationLaunchAgentSynchronizationHooks = .init(),
        legacyAutomationRemover: (() throws -> Void)? = nil
    ) -> ActivationLaunchAgentSynchronizer {
        ActivationLaunchAgentSynchronizer(
            launchAgentsURL: launchAgentsURL,
            legacyAutomationsRootURL: automationsURL,
            homeDirectory: homeURL,
            executableLocator: locator,
            commandRunner: commandRunner,
            controller: controller,
            hooks: hooks,
            legacyAutomationRemover: legacyAutomationRemover
        )
    }

    func label(for time: ActivationTime) -> String {
        policy.label(for: time)
    }

    func fileExists(for time: ActivationTime) -> Bool {
        FileManager.default.fileExists(atPath: policy.fileURL(for: time, in: launchAgentsURL).path)
    }

    func recoveryDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: launchAgentsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".codexquotamenu-launchagent-recovery-") }
    }

    func writeLegacyAutomation(id: String, time: ActivationTime) throws -> URL {
        let directory = automationsURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("automation.toml")
        try Data("""
        version = 1
        id = "\(id)"
        kind = "cron"
        name = "\(ManagedAutomationPolicy.name(for: time))"
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute);TZID=Asia/Shanghai"

        """.utf8).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class FakeCodexExecutableLocator: CodexExecutableLocating {
    let url: URL
    private(set) var callCount = 0

    init(url: URL) {
        self.url = url
    }

    func findExecutable() throws -> URL {
        callCount += 1
        return url
    }
}

private final class FakeCodexCommandRunner: CodexCommandRunning {
    struct Call: Equatable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    var result: CodexCommandResult
    private(set) var calls: [Call] = []

    init(result: CodexCommandResult) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CodexCommandResult {
        calls.append(.init(executableURL: executableURL, arguments: arguments, timeout: timeout))
        return result
    }
}

private final class FakeLaunchctlController: LaunchctlControlling {
    var loadedLabels: Set<String> = []
    var bootstrapHandler: ((URL) throws -> Void)?
    var bootoutHandler: ((String) throws -> Void)?
    var inventoryHandler: (() throws -> Set<String>)?

    func bootstrap(plistURL: URL) throws {
        try bootstrapHandler?(plistURL)
        loadedLabels.insert(try label(in: plistURL))
    }

    func isLoaded(label: String) throws -> Bool {
        loadedLabels.contains(label)
    }

    func loadedOwnedLabels() throws -> Set<String> {
        if let inventoryHandler {
            return try inventoryHandler()
        }
        return loadedLabels
    }

    func bootout(label: String) throws {
        try bootoutHandler?(label)
        loadedLabels.remove(label)
    }

    private func label(in file: URL) throws -> String {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: file),
            format: nil
        ) as? [String: Any]
        return try XCTUnwrap(plist?["Label"] as? String)
    }
}

private enum FixtureError: Error {
    case injected
}
