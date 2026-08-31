import XCTest
@testable import CodexQuotaMenu

final class ResetCelebrationPolicyTests: XCTestCase {
    private let shortReset = Date(timeIntervalSince1970: 10_000)
    private let weeklyReset = Date(timeIntervalSince1970: 20_000)

    func testHighForecastStartsCelebrationAndOrdinaryUpdatesKeepItActive() {
        let first = ResetCelebrationPolicy.evaluate(
            state: .initial,
            probability48h: 80,
            observation: observation(short: 40, weekly: 30)
        )
        XCTAssertTrue(first.isActive)

        let second = ResetCelebrationPolicy.evaluate(
            state: first.state,
            probability48h: 95,
            observation: observation(short: 35, weekly: 29)
        )
        XCTAssertTrue(second.isActive)
    }

    func testCompletedResetDismissesCelebrationForRestOfHighForecastCycle() {
        let active = ResetCelebrationPolicy.evaluate(
            state: .initial,
            probability48h: 85,
            observation: observation(short: 25, weekly: 10)
        )
        let completed = ResetCelebrationPolicy.evaluate(
            state: active.state,
            probability48h: 90,
            observation: observation(
                short: 100,
                weekly: 100,
                shortReset: shortReset.addingTimeInterval(18_000),
                weeklyReset: weeklyReset.addingTimeInterval(604_800)
            )
        )
        XCTAssertFalse(completed.isActive)

        let usedAfterReset = ResetCelebrationPolicy.evaluate(
            state: completed.state,
            probability48h: 82,
            observation: observation(
                short: 98,
                weekly: 99,
                shortReset: shortReset.addingTimeInterval(18_000),
                weeklyReset: weeklyReset.addingTimeInterval(604_800)
            )
        )
        XCTAssertFalse(usedAfterReset.isActive)
    }

    func testBothAdvancedCyclesDismissEvenIfRefreshMissedExactFullValues() {
        let active = ResetCelebrationPolicy.evaluate(
            state: .initial,
            probability48h: 80,
            observation: observation(short: 20, weekly: 15)
        )
        let completed = ResetCelebrationPolicy.evaluate(
            state: active.state,
            probability48h: 88,
            observation: observation(
                short: 96,
                weekly: 97,
                shortReset: shortReset.addingTimeInterval(18_000),
                weeklyReset: weeklyReset.addingTimeInterval(604_800)
            )
        )
        XCTAssertFalse(completed.isActive)
    }

    func testLowForecastRearmsNextHighForecastCycle() {
        let active = ResetCelebrationPolicy.evaluate(
            state: .initial,
            probability48h: 80,
            observation: observation(short: 20, weekly: 15)
        )
        let completed = ResetCelebrationPolicy.evaluate(
            state: active.state,
            probability48h: 90,
            observation: observation(
                short: 100,
                weekly: 100,
                shortReset: shortReset.addingTimeInterval(18_000),
                weeklyReset: weeklyReset.addingTimeInterval(604_800)
            )
        )
        let low = ResetCelebrationPolicy.evaluate(
            state: completed.state,
            probability48h: 79,
            observation: observation(short: 95, weekly: 99)
        )
        XCTAssertFalse(low.isActive)

        let nextHigh = ResetCelebrationPolicy.evaluate(
            state: low.state,
            probability48h: 80,
            observation: observation(short: 94, weekly: 98)
        )
        XCTAssertTrue(nextHigh.isActive)
    }

    func testUnavailableForecastDoesNotRearmDismissedCycle() {
        let dismissed = ResetCelebrationState(
            wasHigh: true,
            dismissed: true,
            observation: observation(short: 100, weekly: 100)
        )
        let unavailable = ResetCelebrationPolicy.evaluate(
            state: dismissed,
            probability48h: nil,
            observation: observation(short: 99, weekly: 99)
        )
        XCTAssertFalse(unavailable.isActive)
        XCTAssertEqual(unavailable.state, dismissed)
    }

    func testStateStoreSurvivesApplicationRestart() {
        let suite = "ResetCelebrationPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsResetCelebrationStateStore(defaults: defaults)
        let expected = ResetCelebrationState(
            wasHigh: true,
            dismissed: true,
            observation: observation(short: 100, weekly: 100)
        )

        store.save(expected)

        XCTAssertEqual(UserDefaultsResetCelebrationStateStore(defaults: defaults).load(), expected)
    }

    private func observation(
        short: Int,
        weekly: Int,
        shortReset: Date? = nil,
        weeklyReset: Date? = nil
    ) -> ResetQuotaObservation {
        ResetQuotaObservation(
            shortRemainingPercent: short,
            shortResetsAt: shortReset ?? self.shortReset,
            weeklyRemainingPercent: weekly,
            weeklyResetsAt: weeklyReset ?? self.weeklyReset
        )
    }
}
