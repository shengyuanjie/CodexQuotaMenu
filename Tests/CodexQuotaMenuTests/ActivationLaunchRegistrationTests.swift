import XCTest
@testable import CodexQuotaMenu

final class ActivationLaunchRegistrationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ActivationRegistrationTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func agent() throws -> ActivationLaunchAgent {
        ActivationLaunchAgentPolicy(codexURL: URL(fileURLWithPath: "/tmp/codex"),
            homeDirectory: URL(fileURLWithPath: "/tmp"),
            runnerURL: URL(fileURLWithPath: "/tmp/app")).agent(for: try ActivationTime(hour: 4, minute: 30))
    }

    func testChangedBinaryReloadsEvenWhenVersionAndPlistAreUnchanged() throws {
        let d = defaults(), c = RegistrationController()
        let a = try agent()
        let before = ActivationLaunchRegistration.fingerprint(executablePath: "/tmp/app", binary: Data("old".utf8), plist: Data("same".utf8))
        let after = ActivationLaunchRegistration.fingerprint(executablePath: "/tmp/app", binary: Data("new".utf8), plist: Data("same".utf8))
        XCTAssertNotEqual(before, after)
        d.set([a.label: before], forKey: ActivationLaunchRegistration.storageKey)
        var verified = false
        try ActivationLaunchRegistration(defaults: d, controller: c, runner: RegistrationRunner()).refresh(
            agents: [a], fingerprints: [a.label: after], fileURL: { _ in URL(fileURLWithPath: "/tmp/0430.plist") },
            verify: { verified = true })
        XCTAssertEqual(c.operations, ["bootout:\(a.label)", "bootstrap:/tmp/0430.plist"])
        XCTAssertTrue(verified)
        XCTAssertEqual(d.dictionary(forKey: ActivationLaunchRegistration.storageKey) as? [String: String], [a.label: after])
    }

    func testUnchangedVerifiedRegistrationDoesNotReload() throws {
        let d = defaults(), c = RegistrationController(), a = try agent()
        d.set([a.label: "same"], forKey: ActivationLaunchRegistration.storageKey)
        try ActivationLaunchRegistration(defaults: d, controller: c, runner: RegistrationRunner()).refresh(
            agents: [a], fingerprints: [a.label: "same"], fileURL: { _ in URL(fileURLWithPath: "/tmp/a") },
            verify: { XCTFail("should not launch a probe") })
        XCTAssertTrue(c.operations.isEmpty)
    }

    func testProbeFailureIsNotCachedAndNextRefreshRetries() throws {
        let d = defaults(), c = RegistrationController(), a = try agent()
        let registration = ActivationLaunchRegistration(defaults: d, controller: c, runner: RegistrationRunner())
        XCTAssertThrowsError(try registration.refresh(agents: [a], fingerprints: [a.label: "new"],
            fileURL: { _ in URL(fileURLWithPath: "/tmp/a") },
            verify: { throw ActivationLaunchAgentSynchronizationError.verificationFailed }))
        XCTAssertNil(d.object(forKey: ActivationLaunchRegistration.storageKey))
        try registration.refresh(agents: [a], fingerprints: [a.label: "new"],
            fileURL: { _ in URL(fileURLWithPath: "/tmp/a") }, verify: {})
        XCTAssertEqual(c.operations.count, 4)
    }

    func testRunningActivationIsNeverInterrupted() throws {
        let d = defaults(), c = RegistrationController(), a = try agent()
        XCTAssertThrowsError(try ActivationLaunchRegistration(defaults: d, controller: c,
            runner: RegistrationRunner(output: "state = running\n pid = 123\n")).refresh(
                agents: [a], fingerprints: [a.label: "new"],
                fileURL: { _ in URL(fileURLWithPath: "/tmp/a") }, verify: { XCTFail() }))
        XCTAssertTrue(c.operations.isEmpty)
        XCTAssertNil(d.object(forKey: ActivationLaunchRegistration.storageKey))
    }

    func testMissingJobIsReloadedDespiteMatchingFingerprint() throws {
        let d = defaults(), c = RegistrationController(), a = try agent()
        c.loaded = false
        d.set([a.label: "same"], forKey: ActivationLaunchRegistration.storageKey)
        try ActivationLaunchRegistration(defaults: d, controller: c, runner: RegistrationRunner()).refresh(
            agents: [a], fingerprints: [a.label: "same"],
            fileURL: { _ in URL(fileURLWithPath: "/tmp/a") }, verify: {})
        XCTAssertEqual(c.operations, ["bootstrap:/tmp/a"])
    }

    func testProbeUsesSeparateJobAndCleansItUpOnFailure() throws {
        let c = RegistrationController()
        let r = RegistrationRunner(output: "last exit reason = OS_REASON_CODESIGNING\n")
        XCTAssertThrowsError(try ActivationLaunchRegistration(defaults: defaults(), controller: c, runner: r)
            .verifyLaunch(executable: URL(fileURLWithPath: "/tmp/app"), home: URL(fileURLWithPath: "/tmp")))
        XCTAssertEqual(c.probeArguments, ["/tmp/app", "--activation-launch-probe"])
        XCTAssertEqual(c.operations.count, 2)
        XCTAssertTrue(c.operations[1].hasPrefix("bootout:com.local.codexquotamenu.activation-probe."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.probeFile!))
    }
}

private final class RegistrationController: LaunchctlControlling {
    var loaded = true
    var operations: [String] = []
    var probeArguments: [String]?
    var probeFile: String?
    func isLoaded(label: String) throws -> Bool { loaded }
    func loadedOwnedLabels() throws -> Set<String> { [] }
    func bootout(label: String) throws { operations.append("bootout:\(label)"); loaded = false }
    func bootstrap(plistURL: URL) throws {
        operations.append("bootstrap:\(plistURL.path)"); loaded = true
        if plistURL.lastPathComponent == "probe.plist" {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
            probeArguments = plist["ProgramArguments"] as? [String]
            probeFile = plistURL.path
        }
    }
}

private struct RegistrationRunner: LaunchctlCommandRunning {
    var output = "state = not running\n"
    func run(arguments: [String]) throws -> LaunchctlCommandResult {
        LaunchctlCommandResult(terminationStatus: 0, standardOutput: output, standardError: "")
    }
}
