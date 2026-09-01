import XCTest
@testable import CodexQuotaMenu

final class AutomationReconcilerTests: XCTestCase {
    func testExactTaskIsSyncedAndEmptyIsUnconfigured() throws {
        let time = try ActivationTime(hour: 6, minute: 0)

        XCTAssertEqual(
            AutomationReconciler.evaluate(
                entries: [],
                readResult: .available([]),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            .unconfigured
        )
        XCTAssertEqual(
            AutomationReconciler.evaluate(
                entries: [.init(time: time)],
                readResult: .available([fixture(time)]),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            .synced
        )
    }

    func testReportsMissingExtraDuplicatePausedAndMisconfigured() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let eleven = try ActivationTime(hour: 11, minute: 2)
        let extra = try ActivationTime(hour: 15, minute: 30)

        let state = AutomationReconciler.evaluate(
            entries: [.init(time: six), .init(time: eleven)],
            readResult: .available([
                fixture(six, status: "PAUSED"),
                fixture(six, model: "gpt-5.6-sol"),
                fixture(extra)
            ]),
            timeZoneIdentifier: "Asia/Shanghai"
        )

        guard case .pending(let difference) = state else {
            return XCTFail("expected pending")
        }
        XCTAssertEqual(difference.missing, [eleven])
        XCTAssertEqual(difference.extra, [extra])
        XCTAssertEqual(difference.duplicate, [six])
        XCTAssertEqual(difference.paused, [six])
        XCTAssertEqual(difference.misconfigured, [six])
    }

    func testAcceptsLocalDailyRRuleWithoutTZIDButRejectsDifferentTZID() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let local = AutomationReconciler.evaluate(
            entries: [.init(time: six)],
            readResult: .available([fixture(six, rrule: "FREQ=DAILY;BYHOUR=6;BYMINUTE=0")]),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertEqual(local, .synced)

        let foreign = AutomationReconciler.evaluate(
            entries: [.init(time: six)],
            readResult: .available([
                fixture(six, rrule: "FREQ=DAILY;BYHOUR=6;BYMINUTE=0;TZID=UTC")
            ]),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertEqual(
            foreign,
            .pending(.init(misconfigured: [six]))
        )
    }

    func testManagedPrefixWithExtraNameTextIsNeverSynced() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let malformed = CodexAutomation(
            id: "malformed",
            version: 1,
            kind: "cron",
            name: "CodexQuotaMenu · 06:00 extra",
            prompt: ManagedAutomationPolicy.activationPrompt,
            status: "ACTIVE",
            rrule: "FREQ=DAILY;BYHOUR=6;BYMINUTE=0",
            model: ManagedAutomationPolicy.model,
            reasoningEffort: ManagedAutomationPolicy.reasoningEffort,
            notificationPolicy: ManagedAutomationPolicy.notificationPolicy,
            executionEnvironment: "local",
            targetType: "projectless"
        )

        let result = AutomationReconciler.evaluate(
            entries: [.init(time: six)],
            readResult: .available([malformed]),
            timeZoneIdentifier: "Asia/Shanghai"
        )

        guard case .pending(let difference) = result else {
            return XCTFail("invalid managed name must not be synced")
        }
        XCTAssertEqual(difference.missing, [six])
        XCTAssertEqual(difference.extra, [six])
    }

    func testUnavailableReadStaysUnavailable() throws {
        let six = try ActivationTime(hour: 6, minute: 0)

        XCTAssertEqual(
            AutomationReconciler.evaluate(
                entries: [.init(time: six)],
                readResult: .unavailable("cannot read"),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            .unavailable("cannot read")
        )
    }

    private func fixture(
        _ time: ActivationTime,
        status: String = "ACTIVE",
        model: String? = ManagedAutomationPolicy.model,
        rrule: String? = nil
    ) -> CodexAutomation {
        CodexAutomation(
            id: UUID().uuidString,
            version: 1,
            kind: "cron",
            name: ManagedAutomationPolicy.name(for: time),
            prompt: ManagedAutomationPolicy.activationPrompt,
            status: status,
            rrule: rrule ?? "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute)",
            model: model,
            reasoningEffort: ManagedAutomationPolicy.reasoningEffort,
            notificationPolicy: ManagedAutomationPolicy.notificationPolicy,
            executionEnvironment: "local",
            targetType: "projectless"
        )
    }
}
