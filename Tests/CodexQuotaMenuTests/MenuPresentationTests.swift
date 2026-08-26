import XCTest
@testable import CodexQuotaMenu

final class MenuPresentationTests: XCTestCase {
    func testChineseTitleShowsShortWindowBeforeWeeklyWindowInCompactFormat() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3时",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2天",
                forecast: forecast(27),
                runningCount: 2,
                language: .simplifiedChinese
            ),
            "Codex 晌81%余3时 周62%余2天 重置率27% ▶2"
        )
    }

    func testEnglishTitleUsesCompactLocalizedLabels() {
        XCTAssertEqual(
            MenuPresentation.title(
                shortRemainingPercent: 81,
                shortResetText: "3h",
                weeklyRemainingPercent: 62,
                weeklyResetText: "2d",
                forecast: forecast(27),
                runningCount: 2,
                language: .english
            ),
            "Codex 5h81% left3h W62% left2d Reset27% ▶2"
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
                runningCount: nil,
                language: .simplifiedChinese
            ),
            "Codex 晌-- 周-- 重置率--"
        )
    }

    private func forecast(_ probability: Int) -> ForecastDisplaySnapshot {
        ForecastDisplaySnapshot(status: .fresh, probability48h: probability, calibrationState: "experimental", updatedAt: Date(timeIntervalSince1970: 1), isCached: false)
    }
}
