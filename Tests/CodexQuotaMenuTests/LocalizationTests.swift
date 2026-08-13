import XCTest
@testable import CodexQuotaMenu

final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolvesChineseAndEnglish() {
        XCTAssertEqual(
            AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLanguage.system.resolved(preferredLanguages: ["en-US"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.system.resolved(preferredLanguages: ["ja-JP"]),
            .english
        )
    }

    func testLanguagePreferencePersists() {
        let suiteName = "CodexQuotaMenuTests.Language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguage.load(from: defaults), .system)
        AppLanguage.english.save(to: defaults)
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
        AppLanguage.simplifiedChinese.save(to: defaults)
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
    }

    func testUsageWindowNamesAreLocalized() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.windowName(durationMinutes: 300), "5 小时用量")
        XCTAssertEqual(english.windowName(durationMinutes: 300), "5-Hour Usage")
        XCTAssertEqual(chinese.windowName(durationMinutes: 10_080), "每周用量")
        XCTAssertEqual(english.windowName(durationMinutes: 10_080), "Weekly Usage")
    }

    func testRemainingTimeIsLocalized() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(4 * 3_600 + 25 * 60)

        XCTAssertEqual(
            AppText(language: .simplifiedChinese).shortRemaining(until: later, now: now),
            "4时25分"
        )
        XCTAssertEqual(
            AppText(language: .english).shortRemaining(until: later, now: now),
            "4h 25m"
        )
    }

    func testMultiDayRemainingTimeIncludesMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let days: TimeInterval = 6 * 86_400
        let hours: TimeInterval = 23 * 3_600
        let minutes: TimeInterval = 7 * 60
        let later = now.addingTimeInterval(days + hours + minutes)

        XCTAssertEqual(
            AppText(language: .simplifiedChinese).shortRemaining(until: later, now: now),
            "6天23时7分"
        )
        XCTAssertEqual(
            AppText(language: .english).shortRemaining(until: later, now: now),
            "6d 23h 7m"
        )
    }

    func testKnownErrorsAreLocalized() {
        XCTAssertEqual(
            AppText(language: .simplifiedChinese).errorDescription(UsageError.timedOut),
            "读取 Codex 用量超时"
        )
        XCTAssertEqual(
            AppText(language: .english).errorDescription(UsageError.timedOut),
            "Reading Codex usage timed out"
        )
    }

    func testForecastDetailsAreLocalizedWithoutConfusingScheduledReset() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.globalResetForecastHeading, "全局额外重置预测")
        XCTAssertEqual(english.globalResetForecastHeading, "Global Bonus Reset Forecast")
        XCTAssertEqual(chinese.forecast24hDescription(30), "未来 24 小时：30%")
        XCTAssertEqual(english.forecast48hDescription(50), "Next 48 hours: 50%")
        XCTAssertEqual(chinese.forecastConfidenceDescription(.medium), "置信度：中")
        XCTAssertEqual(english.forecastConfidenceDescription(.high), "Confidence: High")
        XCTAssertEqual(chinese.forecastStatusDescription(.recentlyReset), "状态：最近已全局重置")
        XCTAssertEqual(english.forecastStatusDescription(.cached), "Status: Delayed data")
        XCTAssertEqual(chinese.strongSignalDescription, "⚡ Tibo 强信号，可能即将重置或正在落地")
        XCTAssertEqual(english.strongSignalDescription, "⚡ Strong Tibo signal: a reset may be imminent or landing")
    }

    func testUnavailableForecastDescriptionsDoNotInventPercentages() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.forecast24hDescription(nil), "未来 24 小时：--")
        XCTAssertEqual(english.forecastConfidenceDescription(nil), "Confidence: --")
        XCTAssertEqual(chinese.forecastStatusDescription(.unavailable), "状态：暂无可信预测")
    }
}
