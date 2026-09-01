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

    func testRequiresExplicitMatchingTZIDAndRejectsDifferentTZID() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let missing = AutomationReconciler.evaluate(
            entries: [.init(time: six)],
            readResult: .available([fixture(six, rrule: "FREQ=DAILY;BYHOUR=6;BYMINUTE=0")]),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        XCTAssertEqual(missing, .pending(.init(misconfigured: [six])))

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

    func testLowercaseTZIDKeyWithMatchingValueIsSynced() throws {
        let six = try ActivationTime(hour: 6, minute: 0)

        XCTAssertEqual(
            AutomationReconciler.evaluate(
                entries: [.init(time: six)],
                readResult: .available([
                    fixture(
                        six,
                        rrule: "freq=DAILY;byhour=6;byminute=0;tzid=Asia/Shanghai"
                    )
                ]),
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            .synced
        )
    }

    func testMalformedPrefixedNamesAreDiagnosticsOnlyAndNeverOwned() throws {
        let six = try ActivationTime(hour: 6, minute: 0)
        let malformed = [
            fixture(six, name: "CodexQuotaMenu · backup"),
            fixture(six, name: "CodexQuotaMenu · 06:00 copy")
        ]

        let result = AutomationReconciler.evaluate(
            entries: [.init(time: six)],
            readResult: .available(malformed),
            timeZoneIdentifier: "Asia/Shanghai"
        )

        guard case .pending(let difference) = result else {
            return XCTFail("invalid managed name must not be synced")
        }
        XCTAssertEqual(difference.missing, [six])
        XCTAssertEqual(difference.extra, [])
        XCTAssertEqual(
            difference.unmatchedNames,
            ["CodexQuotaMenu · 06:00 copy", "CodexQuotaMenu · backup"]
        )
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
        rrule: String? = nil,
        name: String? = nil
    ) -> CodexAutomation {
        CodexAutomation(
            id: UUID().uuidString,
            version: 1,
            kind: "cron",
            name: name ?? ManagedAutomationPolicy.name(for: time),
            prompt: ManagedAutomationPolicy.activationPrompt,
            status: status,
            rrule: rrule ?? "FREQ=DAILY;BYHOUR=\(time.hour);BYMINUTE=\(time.minute);TZID=Asia/Shanghai",
            model: model,
            reasoningEffort: ManagedAutomationPolicy.reasoningEffort,
            notificationPolicy: ManagedAutomationPolicy.notificationPolicy,
            executionEnvironment: "local",
            targetType: "projectless"
        )
    }
}
