import Foundation
import XCTest
@testable import CodexQuotaMenu

final class ActivationLaunchAgentReconcilerTests: XCTestCase {
    private let policy = ActivationLaunchAgentPolicy(
        codexURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    )

    func testExactEnabledAndLoadedAgentIsSyncedWhileEmptyStateIsUnconfigured() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let agent = policy.agent(for: six)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .available(agents: [agent], loadedLabels: [agent.label])
            ),
            .synced
        )
        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [],
                snapshot: .available(agents: [], loadedLabels: [])
            ),
            .unconfigured
        )
    }

    func testEnabledEntryWithoutOwnedAgentIsMissing() throws {
        let six = try ActivationTime(hour: 6, minute: 0)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .available(agents: [], loadedLabels: [])
            ),
            .pending(.init(missing: [six]))
        )
    }

    func testLoadedDisabledEntryIsExtraNotPaused() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let agent = policy.agent(for: six)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six, isEnabled: false)],
                snapshot: .available(agents: [agent], loadedLabels: [agent.label])
            ),
            .pending(.init(extra: [six]))
        )
    }

    func testExtraOwnedAgentIsReported() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 2)
        let sixAgent = policy.agent(for: six)
        let elevenAgent = policy.agent(for: eleven)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .available(
                    agents: [sixAgent, elevenAgent],
                    loadedLabels: [sixAgent.label, elevenAgent.label]
                )
            ),
            .pending(.init(extra: [eleven]))
        )
    }

    func testDuplicateOwnedAgentsAreReported() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let agent = policy.agent(for: six)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .available(agents: [agent, agent], loadedLabels: [agent.label])
            ),
            .pending(.init(duplicate: [six]))
        )
    }

    func testMalformedOwnedPlistLeavesTheSchedulerUnavailable() throws {
        let six = try ActivationTime(hour: 6, minute: 0)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .unavailable("owned LaunchAgent does not match policy")
            ),
            .unavailable("owned LaunchAgent does not match policy")
        )
    }

    func testFilePresentButUnloadedAgentIsPaused() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let agent = policy.agent(for: six)

        XCTAssertEqual(
            ActivationLaunchAgentReconciler.evaluate(
                entries: [.init(time: six)],
                snapshot: .available(agents: [agent], loadedLabels: [])
            ),
            .pending(.init(paused: [six]))
        )
    }

    func testSnapshotReadsEveryOwnedAgentAndHidesControllerDiagnostics() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let agent = policy.agent(for: six)
        let controller = SnapshotLaunchctlController(loadedLabels: [agent.label])

        XCTAssertEqual(
            ActivationSchedulerSnapshot.read(
                readResult: .available([agent]),
                controller: controller
            ),
            .available(agents: [agent], loadedLabels: [agent.label])
        )

        let failingController = SnapshotLaunchctlController(error: FixtureError.diagnostic)
        XCTAssertEqual(
            ActivationSchedulerSnapshot.read(
                readResult: .available([agent]),
                controller: failingController
            ),
            .unavailable("LaunchAgent loaded state is unavailable")
        )
    }
}

private final class SnapshotLaunchctlController: LaunchctlControlling {
    let loadedLabels: Set<String>
    let error: Error?

    init(loadedLabels: Set<String> = [], error: Error? = nil) {
        self.loadedLabels = loadedLabels
        self.error = error
    }

    func bootstrap(plistURL: URL) throws {}

    func isLoaded(label: String) throws -> Bool {
        if let error { throw error }
        return loadedLabels.contains(label)
    }

    func bootout(label: String) throws {}
}

private enum FixtureError: Error {
    case diagnostic
}
