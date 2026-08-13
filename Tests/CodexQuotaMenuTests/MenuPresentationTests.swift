import XCTest
@testable import CodexQuotaMenu

final class MenuPresentationTests: XCTestCase {
    func testTitleShowsOnlyThe48HourProbability() {
        XCTAssertEqual(
            MenuPresentation.title(remainingPercent: 97, resetText: "6天23时", forecast: forecast(82), runningCount: 2),
            "Codex 97% · 6天23时 · ↻48h 82% · ▶ 2"
        )
    }

    func testTitleShowsUnavailable48HourProbability() {
        XCTAssertEqual(
            MenuPresentation.title(remainingPercent: nil, resetText: nil, forecast: .unavailable, runningCount: nil),
            "Codex -- · ↻48h --"
        )
    }

    private func forecast(_ probability: Int) -> ForecastDisplaySnapshot {
        ForecastDisplaySnapshot(status: .fresh, probability48h: probability, calibrationState: "experimental", updatedAt: Date(timeIntervalSince1970: 1), isCached: false)
    }
}
