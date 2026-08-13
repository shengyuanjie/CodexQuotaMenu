enum MenuPresentation {
    static func title(
        remainingPercent: Int,
        resetText: String?,
        forecast: ForecastDisplaySnapshot,
        runningCount: Int
    ) -> String {
        var parts = ["Codex \(remainingPercent)%"]
        if let resetText, !resetText.isEmpty {
            parts.append(resetText)
        }
        if let probability = forecast.probability24h {
            parts.append("↻\(probability)%" + (forecast.strongSignal ? " ⚡" : ""))
        } else {
            parts.append("↻--" + (forecast.strongSignal ? " ⚡" : ""))
        }
        parts.append("▶ \(runningCount)")
        return parts.joined(separator: " · ")
    }
}
