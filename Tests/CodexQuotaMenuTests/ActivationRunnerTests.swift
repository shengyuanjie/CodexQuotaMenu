import XCTest
@testable import CodexQuotaMenu

final class ActivationRunnerTests: XCTestCase {
    func testRunnerPolicyAcceptsLegacyAgentForMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = URL(fileURLWithPath: "/opt/bin/codex")
        let home = URL(fileURLWithPath: "/Users/tester")
        let time = try ActivationTime(hour: 6, minute: 30)
        let old = ActivationLaunchAgentPolicy(codexURL: codex, homeDirectory: home, runnerURL: nil)
        let new = ActivationLaunchAgentPolicy(codexURL: codex, homeDirectory: home, runnerURL: URL(fileURLWithPath: "/Applications/Test.app/Contents/MacOS/Test"))
        let file = old.fileURL(for: time, in: directory)
        try old.agent(for: time).xmlData().write(to: file)
        guard case let .available(legacy) = ActivationLaunchAgentReader(policy: new, directoryURL: directory).read() else { return XCTFail("legacy rejected") }
        XCTAssertTrue(try XCTUnwrap(legacy.first).requiresSynchronization)
        try new.agent(for: time).xmlData().write(to: file)
        guard case let .available(current) = ActivationLaunchAgentReader(policy: new, directoryURL: directory).read() else { return XCTFail("runner rejected") }
        XCTAssertFalse(try XCTUnwrap(current.first).requiresSynchronization)
        let moved = ActivationLaunchAgentPolicy(codexURL: URL(fileURLWithPath: "/new/bin/codex"), homeDirectory: home, runnerURL: new.runnerURL)
        guard case let .available(stale) = ActivationLaunchAgentReader(policy: moved, directoryURL: directory).read() else { return XCTFail("stale wrapped CLI rejected") }
        XCTAssertTrue(try XCTUnwrap(stale.first).requiresSynchronization)
    }
    func testWindowVerificationDoesNotAttributeExistingOrUnknownBaseline() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(18000)
        let active = RateLimitWindow(usedPercent: 1, durationMinutes: 300, resetsAt: end)
        let expired = RateLimitWindow(usedPercent: 20, durationMinutes: 300, resetsAt: start)
        func outcome(_ before: RateLimitWindow?, _ after: RateLimitWindow?, _ confirmation: RateLimitWindow?, _ error: String? = nil) -> String {
            ActivationRunner.verifiedOutcome(before: before, after: after, confirmation: confirmation, started: start, now: start, commandError: error)
        }
        XCTAssertEqual(outcome(active, active, active), "window_already_active")
        XCTAssertEqual(outcome(nil, active, active), "active_without_baseline")
        XCTAssertEqual(outcome(expired, active, active), "window_activated")
        XCTAssertEqual(outcome(expired, nil, nil), "verification_unavailable")
        XCTAssertEqual(outcome(active, active, active, "command_failed"), "request_failed")
        let placeholder = RateLimitWindow(usedPercent: 0, durationMinutes: 300, resetsAt: end)
        let moved = RateLimitWindow(usedPercent: 0, durationMinutes: 300, resetsAt: end.addingTimeInterval(10))
        XCTAssertEqual(outcome(expired, placeholder, moved), "verification_unavailable")
        XCTAssertEqual(outcome(expired, placeholder, placeholder), "request_completed_unverified")
    }

    func testCompletedTurnRequiredEvenWithZeroExitCode() {
        XCTAssertEqual(ActivationRunner.commandError(.init(terminationStatus: 0, standardOutput: "已激活")), "turn_not_completed")
        let completed = #"{"type":"turn.completed","usage":{"output_tokens":3}}"#
        XCTAssertNil(ActivationRunner.commandError(.init(terminationStatus: 0, standardOutput: completed)))
        XCTAssertEqual(ActivationRunner.commandError(.init(terminationStatus: 1, standardOutput: completed)), "command_failed")
        XCTAssertEqual(ActivationRunner.commandError(.init(terminationStatus: 0, standardOutput: completed + "\n" + #"{"type":"turn.failed"}"#)), "command_failed")
        XCTAssertEqual(ActivationRunner.commandError(.init(terminationStatus: 1, standardError: "429 rate limit")), "rate_limit")
    }

    func testExpiryDeferralIsBoundedAndDoesNotTrustUnusedPlaceholder() {
        let now = Date()
        XCTAssertEqual(ActivationRunner.expiryDelay(.init(usedPercent: 1, durationMinutes: 300, resetsAt: now.addingTimeInterval(60)), now: now), 65)
        XCTAssertNil(ActivationRunner.expiryDelay(.init(usedPercent: 1, durationMinutes: 300, resetsAt: now.addingTimeInterval(3600)), now: now))
        XCTAssertNil(ActivationRunner.expiryDelay(.init(usedPercent: 0, durationMinutes: 300, resetsAt: now.addingTimeInterval(60)), now: now))
    }
}
