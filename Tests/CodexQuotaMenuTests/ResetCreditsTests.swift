import XCTest
@testable import CodexQuotaMenu

final class ResetCreditsTests: XCTestCase {
    private func summary(_ count: Int, _ rows: [ResetCredit]? = nil) -> ResetCreditsSummary {
        ResetCreditsSummary(availableCount: count, credits: rows)
    }
    private func card(_ id: String, granted: Double) -> ResetCredit {
        ResetCredit(id: id, grantedAt: Date(timeIntervalSince1970: granted), expiresAt: nil)
    }
    private func parse(_ field: String) throws -> UsageSnapshot {
        let json = """
        {"result":{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300}},"rateLimitResetCredits":\(field)}}
        """
        return try UsageParser.parse(Data(json.utf8))
    }

    func testParserDistinguishesUnknownZeroAndCountOnly() throws {
        XCTAssertNil(try parse("null").resetCredits)
        XCTAssertNil(try parse("{}").resetCredits)
        XCTAssertNil(try parse(#"{"availableCount":-1}"#).resetCredits)
        XCTAssertEqual(try parse(#"{"availableCount":0,"credits":[]}"#).resetCredits, summary(0, []))
        XCTAssertEqual(try parse(#"{"availableCount":2,"credits":null}"#).resetCredits, summary(2))
    }

    func testParserUsesAuthoritativeCountAndFiltersUnsupportedDetails() throws {
        let snapshot = try parse(#"{"availableCount":4,"credits":[{"id":"a","resetType":"codexRateLimits","status":"available","grantedAt":100,"expiresAt":200},{"id":"b","resetType":"codexRateLimits","status":"redeemed","grantedAt":90},{"id":"c","resetType":"unknown","status":"available","grantedAt":90}]}"#)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 4)
        XCTAssertEqual(snapshot.resetCredits?.credits?.count, 1)
        XCTAssertEqual(snapshot.resetCredits?.credits?.first?.expiresAt, Date(timeIntervalSince1970: 200))
    }

    func testStartupAndDelayedOldDetailsAreBaselineOnly() {
        var tracker = ResetCreditArrivalTracker()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(tracker.observe(nil, fetchedAt: now))
        XCTAssertFalse(tracker.observe(summary(2), fetchedAt: now))
        XCTAssertFalse(tracker.observe(summary(2, [card("old", granted: 50)]), fetchedAt: now.addingTimeInterval(5)))
        XCTAssertFalse(tracker.observe(summary(1, [card("old", granted: 50)]), fetchedAt: now.addingTimeInterval(10)))
        var restarted = ResetCreditArrivalTracker()
        XCTAssertFalse(restarted.observe(summary(2, [card("new", granted: 110)]), fetchedAt: now.addingTimeInterval(20)))
    }

    func testNewCardIsDetectedOnceEvenWhenCountDoesNotIncrease() {
        var tracker = ResetCreditArrivalTracker()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(tracker.observe(summary(1, [card("old", granted: 50)]), fetchedAt: now))
        let current = summary(1, [card("new", granted: 110)])
        XCTAssertTrue(tracker.observe(current, fetchedAt: now.addingTimeInterval(15)))
        XCTAssertFalse(tracker.observe(current, fetchedAt: now.addingTimeInterval(20)))
    }

    func testCountIncreaseWorksAcrossMissingDataWithoutDetails() {
        var tracker = ResetCreditArrivalTracker()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(tracker.observe(summary(1), fetchedAt: now))
        XCTAssertFalse(tracker.observe(nil, fetchedAt: now.addingTimeInterval(5)))
        XCTAssertTrue(tracker.observe(summary(2), fetchedAt: now.addingTimeInterval(10)))
        XCTAssertFalse(tracker.observe(summary(2), fetchedAt: now.addingTimeInterval(15)))
    }

    func testNewCardDismissesOnlyCurrentHighCycleAndSurvivesForecastFailure() {
        let active = ResetCelebrationPolicy.evaluate(state: .initial, probability48h: 80, observation: nil)
        let arrived = ResetCelebrationPolicy.evaluate(state: active.state, probability48h: nil, observation: nil, newlyGrantedResetCredit: true)
        XCTAssertTrue(arrived.state.dismissed)
        XCTAssertFalse(ResetCelebrationPolicy.evaluate(state: arrived.state, probability48h: 90, observation: nil).isActive)
        let low = ResetCelebrationPolicy.evaluate(state: arrived.state, probability48h: 20, observation: nil)
        XCTAssertTrue(ResetCelebrationPolicy.evaluate(state: low.state, probability48h: 80, observation: nil).isActive)
        XCTAssertFalse(ResetCelebrationPolicy.evaluate(state: .initial, probability48h: 20, observation: nil, newlyGrantedResetCredit: true).state.dismissed)
    }

    func testMenuTextIncludesExpiryAndHandlesUnavailableDetails() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)
        XCTAssertEqual(chinese.resetCreditDescriptions(nil), ["重置卡：暂时无法读取"])
        XCTAssertEqual(chinese.resetCreditDescriptions(summary(0, [])), ["重置卡：0 张可用"])
        let lines = chinese.resetCreditDescriptions(summary(2, [ResetCredit(id: "a", grantedAt: .distantPast, expiresAt: Date(timeIntervalSince1970: 200))]))
        XCTAssertEqual(lines.first, "重置卡：2 张可用")
        XCTAssertTrue(lines.contains { $0.contains("到期") })
        XCTAssertEqual(lines.last, "  部分卡片的到期时间暂不可用")
        XCTAssertEqual(english.resetCreditDescriptions(summary(2)).last, "  Expiration details unavailable")
    }
}
