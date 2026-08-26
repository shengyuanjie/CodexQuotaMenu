enum MenuPresentation {
    static func title(
        shortRemainingPercent: Int?,
        shortResetText: String?,
        weeklyRemainingPercent: Int?,
        weeklyResetText: String?,
        forecast: ForecastDisplaySnapshot,
        runningCount: Int?,
        language: DisplayLanguage
    ) -> String {
        let shortPercent = shortRemainingPercent.map { "\($0)%" } ?? "--"
        let weeklyPercent = weeklyRemainingPercent.map { "\($0)%" } ?? "--"
        let forecastPercent = forecast.probability48h.map { "\($0)%" } ?? "--"

        let shortPart: String
        let weeklyPart: String
        let forecastPart: String
        switch language {
        case .simplifiedChinese:
            shortPart = "晌\(shortPercent)" + (shortResetText.map { "余\($0)" } ?? "")
            weeklyPart = "周\(weeklyPercent)" + (weeklyResetText.map { "余\($0)" } ?? "")
            forecastPart = "重置率\(forecastPercent)"
        case .english:
            shortPart = "5h\(shortPercent)" + (shortResetText.map { " left\($0)" } ?? "")
            weeklyPart = "W\(weeklyPercent)" + (weeklyResetText.map { " left\($0)" } ?? "")
            forecastPart = "Reset\(forecastPercent)"
        }

        var parts = ["Codex", shortPart, weeklyPart, forecastPart]
        if let runningCount {
            parts.append("▶\(runningCount)")
        }
        return parts.joined(separator: " ")
    }
}
