import XCTest
@testable import CodexQuotaMenu

final class MenuPresentationTests: XCTestCase {
    func testChineseTitleUsesWiderSpacingAndHidesForecastBelowEightyPercent() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3时",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2天",
                forecast: forecast(79),
                resetCelebrationActive: false,
                runningCount: 2,
                language: .simplifiedChinese
            ),
            "Codex  晌81%余3时  周62%余2天  ▶2"
        )
    }

    func testEnglishTitleUsesWiderSpacingAndHidesForecastBelowEightyPercent() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3h",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2d",
                forecast: forecast(79),
                resetCelebrationActive: false,
                runningCount: 2,
                language: .english
            ),
            "Codex  5h81% left3h  W62% left2d  ▶2"
        )
    }

    func testChineseTitleReplacesQuotaDetailsAtEightyPercentForecast() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3时",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2天",
                forecast: forecast(80),
                resetCelebrationActive: true,
                runningCount: 2,
                language: .simplifiedChinese
            ),
            "Codex  冲冲冲～使劲蹬啊～  ▶2"
        )
    }

    func testEnglishTitleReplacesQuotaDetailsAtEightyPercentForecast() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3h",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2d",
                forecast: forecast(80),
                resetCelebrationActive: true,
                runningCount: 2,
                language: .english
            ),
            "Codex  Go go go~ Pedal harder~  ▶2"
        )
    }

    func testCompletedResetRestoresQuotaDetailsWhileForecastRemainsHigh() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 100,
                shortResetText: "5时",
                weeklyRemainingPercent: 100,
                weeklyResetText: "7天",
                forecast: forecast(90),
                resetCelebrationActive: false,
                runningCount: 0,
                language: .simplifiedChinese
            ),
            "Codex  晌100%余5时  周100%余7天  ▶0"
        )
    }

    func testTitleOmitsUnavailableResetTimesAndTaskCount() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: nil,
                shortResetText: nil,
                weeklyRemainingPercent: nil,
                weeklyResetText: nil,
                forecast: .unavailable,
                resetCelebrationActive: false,
                runningCount: nil,
                language: .simplifiedChinese
            ),
            "Codex  晌--  周--"
        )
    }

    private func forecast(_ probability: Int) -> ForecastDisplaySnapshot {
        ForecastDisplaySnapshot(status: .fresh, probability48h: probability, calibrationState: "experimental", updatedAt: Date(timeIntervalSince1970: 1), isCached: false)
    }
}
