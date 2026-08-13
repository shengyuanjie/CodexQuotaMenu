enum MenuPresentation {
    static func title(
        remainingPercent: Int?,
        resetText: String?,
        forecast: ForecastDisplaySnapshot,
        runningCount: Int?
    ) -> String {
        var parts = [remainingPercent.map { "Codex \($0)%" } ?? "Codex --"]
        if let resetText, !resetText.isEmpty {
            parts.append(resetText)
        }
        if let probability = forecast.probability24h {
            parts.append("↻\(probability)%" + (forecast.strongSignal ? " ⚡" : ""))
        } else {
            parts.append("↻--" + (forecast.strongSignal ? " ⚡" : ""))
        }
        if let runningCount {
            parts.append("▶ \(runningCount)")
        }
        return parts.joined(separator: " · ")
    }
}
