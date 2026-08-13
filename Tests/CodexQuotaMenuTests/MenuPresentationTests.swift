import XCTest
@testable import CodexQuotaMenu

final class MenuPresentationTests: XCTestCase {
    func testTitleAdds24HourForecastBeforeTaskCount() {
        let title = MenuPresentation.title(
            remainingPercent: 82,
            resetText: "6天23时",
            forecast: forecast(probability24h: 30),
            runningCount: 1
        )

        XCTAssertEqual(title, "Codex 82% · 6天23时 · ↻30% · ▶ 1")
    }

    func testTitleMarksStrongSignalWithoutReplacingProbability() {
        let title = MenuPresentation.title(
            remainingPercent: 82,
            resetText: "6d 23h",
            forecast: forecast(probability24h: 30, status: .strongSignal, strongSignal: true),
            runningCount: 0
        )

        XCTAssertEqual(title, "Codex 82% · 6d 23h · ↻30% ⚡ · ▶ 0")
    }

    func testTitleShowsUnavailableForecastAndOmitsMissingResetText() {
        let title = MenuPresentation.title(
            remainingPercent: 82,
            resetText: nil,
            forecast: .unavailable,
            runningCount: 2
        )

        XCTAssertEqual(title, "Codex 82% · ↻-- · ▶ 2")
    }

    func testTitleStillShowsForecastWhenLocalUsageIsUnavailable() {
        let title = MenuPresentation.title(
            remainingPercent: nil,
            resetText: nil,
            forecast: forecast(probability24h: 30),
            runningCount: nil
        )

        XCTAssertEqual(title, "Codex -- · ↻30%")
    }
}

private extension MenuPresentationTests {
    func forecast(
        probability24h: Int,
        status: ForecastDisplayStatus = .forecast,
        strongSignal: Bool = false
    ) -> ForecastDisplaySnapshot {
        ForecastDisplaySnapshot(
            status: status,
            probability24h: probability24h,
            probability48h: 50,
            confidence: .medium,
            strongSignal: strongSignal,
            lastResetAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1),
            isCached: false
        )
    }
}
