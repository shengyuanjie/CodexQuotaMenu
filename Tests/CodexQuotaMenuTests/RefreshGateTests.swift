import XCTest
@testable import CodexQuotaMenu

final class RefreshGateTests: XCTestCase {
    private let gate = RefreshGate(interval: 300, manualMinimumInterval: 30)

    func testFirstRefreshIsAlwaysAllowed() {
        XCTAssertTrue(gate.shouldRefresh(lastAttempt: nil, now: Date(timeIntervalSince1970: 100), manual: false))
    }

    func testAutomaticRefreshWaitsFiveMinutes() {
        let last = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(gate.shouldRefresh(lastAttempt: last, now: last.addingTimeInterval(299), manual: false))
        XCTAssertTrue(gate.shouldRefresh(lastAttempt: last, now: last.addingTimeInterval(300), manual: false))
    }

    func testManualRefreshUsesThirtySecondMinimum() {
        let last = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(gate.shouldRefresh(lastAttempt: last, now: last.addingTimeInterval(29), manual: true))
        XCTAssertTrue(gate.shouldRefresh(lastAttempt: last, now: last.addingTimeInterval(30), manual: true))
    }

    func testClockMovingBackDoesNotBlockRefreshIndefinitely() {
        let now = Date(timeIntervalSince1970: 100)
        let futureAttempt = now.addingTimeInterval(60)

        XCTAssertTrue(gate.shouldRefresh(lastAttempt: futureAttempt, now: now, manual: false))
    }
}
