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
}
