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
        parts.append(forecast.probability48h.map { "↻48h \($0)%" } ?? "↻48h --")
        if let runningCount {
            parts.append("▶ \(runningCount)")
        }
        return parts.joined(separator: " · ")
    }
}
