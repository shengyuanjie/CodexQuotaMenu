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

    func testCompactRemainingTimeFloorsToLargestUsefulUnit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.compactRemaining(until: now.addingTimeInterval(2 * 86_400 + 4 * 3_600 + 59 * 60), now: now), "2天")
        XCTAssertEqual(chinese.compactRemaining(until: now.addingTimeInterval(3 * 3_600 + 26 * 60), now: now), "3时")
        XCTAssertEqual(chinese.compactRemaining(until: now.addingTimeInterval(42 * 60 + 59), now: now), "42分")
        XCTAssertEqual(english.compactRemaining(until: now.addingTimeInterval(2 * 86_400 + 4 * 3_600), now: now), "2d")
        XCTAssertEqual(english.compactRemaining(until: now.addingTimeInterval(3 * 3_600 + 26 * 60), now: now), "3h")
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
        XCTAssertEqual(english.forecast48hDescription(50), "Next 48 hours: 50%")
        XCTAssertEqual(chinese.forecastStatusDescription(.fresh), "状态：实时")
        XCTAssertEqual(english.forecastStatusDescription(.cached), "Status: Delayed data")
        XCTAssertEqual(chinese.forecastSourceDescription, "来源：Codex Reset Monitor")
        XCTAssertEqual(chinese.forecastUpdatedDescription("10:43:49", isCached: true), "预测更新：10:43:49 · 缓存")
        XCTAssertEqual(english.forecastUpdatedDescription("10:43:49", isCached: false), "Forecast updated: 10:43:49")
    }

    func testUnavailableForecastDescriptionsDoNotInventPercentages() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.forecast48hDescription(nil), "未来 48 小时：--")
        XCTAssertEqual(english.forecastUpdatedDescription(nil, isCached: false), "Forecast updated: --")
        XCTAssertEqual(chinese.forecastStatusDescription(.unavailable), "状态：暂不可用")
    }

    func testPhoneWidgetActionsAreLocalized() {
        let chinese = AppText(language: .simplifiedChinese)
        let english = AppText(language: .english)

        XCTAssertEqual(chinese.phoneWidgetHeading, "手机小组件")
        XCTAssertEqual(english.phoneWidgetHeading, "Phone Widget")
        XCTAssertEqual(chinese.enableWidgetServerAction, "启用只读接口")
        XCTAssertEqual(english.enableWidgetServerAction, "Enable Read-Only API")
        XCTAssertEqual(chinese.copyWidgetAddressAction, "复制小组件地址")
        XCTAssertEqual(english.copyWidgetAddressAction, "Copy Widget Address")
        XCTAssertEqual(chinese.copyWidgetTokenAction, "复制访问令牌")
        XCTAssertEqual(english.copyWidgetTokenAction, "Copy Access Token")
        XCTAssertEqual(chinese.regenerateWidgetTokenAction, "重新生成访问令牌")
        XCTAssertEqual(english.regenerateWidgetTokenAction, "Regenerate Access Token")
        XCTAssertEqual(chinese.widgetServerFailed, "服务启动失败")
        XCTAssertEqual(english.widgetServerFailed, "Service Failed to Start")
    }
}
