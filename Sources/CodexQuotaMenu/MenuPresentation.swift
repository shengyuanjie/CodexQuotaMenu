enum MenuPresentation {
    static func title(
        shortRemainingPercent: Int?,
        shortResetText: String?,
        weeklyRemainingPercent: Int?,
        weeklyResetText: String?,
        forecast: ForecastDisplaySnapshot,
        resetCelebrationActive: Bool? = nil,
        runningCount: Int?,
        language: DisplayLanguage
    ) -> String {
        let shortPercent = shortRemainingPercent.map { "\($0)%" } ?? "--"
        let weeklyPercent = weeklyRemainingPercent.map { "\($0)%" } ?? "--"
        let shortPart: String
        let weeklyPart: String
        let highForecastWeeklyPart: String
        switch language {
        case .simplifiedChinese:
            shortPart = "晌\(shortPercent)" + (shortResetText.map { "余\($0)" } ?? "")
            weeklyPart = "周\(weeklyPercent)" + (weeklyResetText.map { "余\($0)" } ?? "")
            highForecastWeeklyPart = "周\(weeklyPercent)冲冲冲"
        case .english:
            shortPart = "5h\(shortPercent)" + (shortResetText.map { " left\($0)" } ?? "")
            weeklyPart = "W\(weeklyPercent)" + (weeklyResetText.map { " left\($0)" } ?? "")
            highForecastWeeklyPart = "W\(weeklyPercent) Go go go"
        }

        let showEncouragement = resetCelebrationActive
            ?? (forecast.probability48h.map { $0 >= ResetCelebrationPolicy.threshold } == true)
        let quotaParts = showEncouragement
            ? [shortPart, highForecastWeeklyPart]
            : [shortPart, weeklyPart]
        var parts = ["Codex"] + quotaParts
        if let runningCount {
            parts.append("▶\(runningCount)")
        }
        return parts.joined(separator: "  ")
    }
}
