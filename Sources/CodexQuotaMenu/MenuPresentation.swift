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
        let encouragement: String
        switch language {
        case .simplifiedChinese:
            shortPart = "晌\(shortPercent)" + (shortResetText.map { "余\($0)" } ?? "")
            weeklyPart = "周\(weeklyPercent)" + (weeklyResetText.map { "余\($0)" } ?? "")
            encouragement = "冲冲冲～使劲蹬啊～"
        case .english:
            shortPart = "5h\(shortPercent)" + (shortResetText.map { " left\($0)" } ?? "")
            weeklyPart = "W\(weeklyPercent)" + (weeklyResetText.map { " left\($0)" } ?? "")
            encouragement = "Go go go~ Pedal harder~"
        }

        let showEncouragement = resetCelebrationActive
            ?? (forecast.probability48h.map { $0 >= 80 } == true)
        let quotaParts = showEncouragement
            ? [encouragement]
            : [shortPart, weeklyPart]
        var parts = ["Codex"] + quotaParts
        if let runningCount {
            parts.append("▶\(runningCount)")
        }
        return parts.joined(separator: "  ")
    }
}
