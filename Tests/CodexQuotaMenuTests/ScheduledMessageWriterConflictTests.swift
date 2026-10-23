import XCTest
@testable import CodexQuotaMenu

final class ScheduledMessageWriterConflictTests: XCTestCase {
    private let conflict = ScheduledMessageDeliveryError(code: "thread_writer_conflict", retryableWriterConflict: true)

    func testRediscoversDesktopDuringResumeWithoutAnotherCLIRequest() throws {
        var time = Date(timeIntervalSince1970: 0)
        var cliCalls = 0
        var desktopCalls = 0
        let sent = try ScheduledMessageRunner.deliverExisting(now: { time }, sleep: { time.addTimeInterval($0) },
            readDesktop: { _ in
                desktopCalls += 1
                return time.timeIntervalSince1970 >= 12 ? true : nil
            }, sendCLI: { _ in cliCalls += 1; throw self.conflict })
        XCTAssertTrue(sent)
        XCTAssertEqual(cliCalls, 1)
        XCTAssertGreaterThan(desktopCalls, 1)
    }

    func testRetriesCLIOnlyAfterWaitingWhenNoDesktopOwnerAppears() throws {
        var time = Date(timeIntervalSince1970: 0)
        var calls = 0
        XCTAssertTrue(try ScheduledMessageRunner.deliverExisting(now: { time }, sleep: { time.addTimeInterval($0) },
            readDesktop: { _ in nil }, sendCLI: { remaining in
                calls += 1
                if calls == 1 { throw self.conflict }
                XCTAssertGreaterThanOrEqual(time.timeIntervalSince1970, 15)
                XCTAssertLessThan(remaining, 3_600)
                return true
            }))
        XCTAssertEqual(calls, 2)
    }

    func testPersistentConflictStopsAtRecoveryDeadline() {
        var time = Date(timeIntervalSince1970: 0)
        var calls = 0
        XCTAssertThrowsError(try ScheduledMessageRunner.deliverExisting(now: { time }, sleep: { time.addTimeInterval($0) },
            readDesktop: { _ in nil }, sendCLI: { _ in calls += 1; throw self.conflict })) { error in
                XCTAssertEqual((error as? ScheduledMessageDeliveryError)?.code, "thread_writer_conflict")
            }
        XCTAssertEqual(time.timeIntervalSince1970, 60)
        XCTAssertEqual(calls, 4)
    }

    func testSlowDiscoveryDoesNotRetryCLIAfterRecoveryWindow() {
        var time = Date(timeIntervalSince1970: 0)
        var calls = 0
        XCTAssertThrowsError(try ScheduledMessageRunner.deliverExisting(now: { time }, sleep: { time.addTimeInterval($0) },
            readDesktop: { _ in
                if calls > 0 { time.addTimeInterval(60) }
                return nil
            }, sendCLI: { _ in calls += 1; throw self.conflict }))
        XCTAssertEqual(calls, 1)
    }

    func testAmbiguousFailuresAreNeverRetried() {
        for code in ["thread_writer_conflict", "completion_unverified", "cli_timeout_or_output_limit", "connection_failed"] {
            var calls = 0
            XCTAssertThrowsError(try ScheduledMessageRunner.deliverExisting(sleep: { _ in XCTFail("unexpected retry wait") },
                readDesktop: { _ in nil }, sendCLI: { _ in
                    calls += 1
                    throw ScheduledMessageDeliveryError(code: code)
                }))
            XCTAssertEqual(calls, 1)
        }
        XCTAssertThrowsError(try ScheduledMessageRunner.deliverExisting(sleep: { _ in XCTFail("unexpected retry wait") },
            readDesktop: { _ in throw self.conflict }, sendCLI: { _ in XCTFail("desktop failure must not fall back"); return true }))
    }

    func testAmbiguousOutcomeAfterRecoveryStopsFurtherAttempts() {
        var time = Date(timeIntervalSince1970: 0)
        var calls = 0
        XCTAssertThrowsError(try ScheduledMessageRunner.deliverExisting(now: { time }, sleep: { time.addTimeInterval($0) },
            readDesktop: { _ in nil }, sendCLI: { _ in
                calls += 1
                if calls == 1 { throw self.conflict }
                throw ScheduledMessageDeliveryError(code: "completion_unverified")
            })) { error in
                XCTAssertEqual((error as? ScheduledMessageDeliveryError)?.code, "completion_unverified")
            }
        XCTAssertEqual(calls, 2)
    }

    func testSubprocessLockFailureIsRetryableOnlyWithEmptyExecutionOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("codex")
        let id = UUID().uuidString.lowercased()
        let message = ScheduledMessage(fireDate: Date(), threadID: id, threadTitle: "Test", model: "test", message: "test")
        for output in ["", "{\"type\":\"thread.started\",\"thread_id\":\"\(id)\"}", "{\"type\":\"turn.started\"}", "unknown output"] {
            let printOutput = output.isEmpty ? "" : "printf '%s\\n' '\(output)'\n"
            try ("#!/bin/sh\n" + printOutput + "printf '%s\\n' 'thread already has an active writer' >&2\nexit 1\n")
                .write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            XCTAssertThrowsError(try ScheduledMessageRunner.runCodex(message, directory: root, effort: "low", executable: fake, timeout: 5)) { error in
                let failure = error as? ScheduledMessageDeliveryError
                XCTAssertEqual(failure?.code, "thread_writer_conflict")
                XCTAssertEqual(failure?.retryableWriterConflict, output.isEmpty)
            }
        }
    }
}
