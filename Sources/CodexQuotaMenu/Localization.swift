import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    private static let preferenceKey = "interfaceLanguage"

    static func load(from defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: preferenceKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .system
        }
        return language
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> DisplayLanguage {
        switch self {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .system:
            let preferred = preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
        }
    }
}

enum DisplayLanguage: Equatable {
    case simplifiedChinese
    case english
}

struct AppText {
    let language: DisplayLanguage

    static var current: AppText {
        AppText(language: AppLanguage.load().resolved())
    }

    var appName: String {
        language == .simplifiedChinese ? "Codex 用量" : "Codex Usage"
    }

    var loadingTitle: String {
        language == .simplifiedChinese ? "读取中…" : "Loading…"
    }

    var loadingMessage: String {
        language == .simplifiedChinese ? "正在读取 Codex 用量…" : "Reading Codex usage…"
    }

    var remainingUsageHeading: String {
        language == .simplifiedChinese ? "Codex 剩余用量" : "Codex Remaining Usage"
    }

    var currentTasksHeading: String {
        language == .simplifiedChinese ? "当前任务" : "Current Tasks"
    }

    var globalResetForecastHeading: String {
        language == .simplifiedChinese ? "全局额外重置预测" : "Global Bonus Reset Forecast"
    }

    var strongSignalDescription: String {
        language == .simplifiedChinese
            ? "⚡ Tibo 强信号，可能即将重置或正在落地"
            : "⚡ Strong Tibo signal: a reset may be imminent or landing"
    }

    var refreshAction: String {
        language == .simplifiedChinese ? "立即刷新" : "Refresh Now"
    }

    var quitAction: String {
        language == .simplifiedChinese ? "退出" : "Quit"
    }

    var languageAction: String {
        language == .simplifiedChinese ? "语言" : "Language"
    }

    var languageSystem: String {
        language == .simplifiedChinese ? "跟随系统" : "Follow System"
    }

    var languageSimplifiedChinese: String {
        language == .simplifiedChinese ? "简体中文" : "Simplified Chinese"
    }

    var languageEnglish: String { "English" }

    func languageName(_ selection: AppLanguage) -> String {
        switch selection {
        case .system: languageSystem
        case .simplifiedChinese: languageSimplifiedChinese
        case .english: languageEnglish
        }
    }

    func windowName(durationMinutes: Int?) -> String {
        guard let durationMinutes else {
            return language == .simplifiedChinese ? "用量窗口" : "Usage Window"
        }
        if durationMinutes <= 360 {
            let hours = max(1, durationMinutes / 60)
            return language == .simplifiedChinese
                ? "\(hours) 小时用量"
                : "\(hours)-Hour Usage"
        }
        if durationMinutes >= 10_000 {
            return language == .simplifiedChinese ? "每周用量" : "Weekly Usage"
        }
        if durationMinutes % 1_440 == 0 {
            let days = durationMinutes / 1_440
            return language == .simplifiedChinese
                ? "\(days) 天用量"
                : "\(days)-Day Usage"
        }
        let hours = durationMinutes / 60
        return language == .simplifiedChinese
            ? "\(hours) 小时用量"
            : "\(hours)-Hour Usage"
    }

    func remainingUsage(window: RateLimitWindow) -> String {
        if language == .simplifiedChinese {
            return "\(windowName(durationMinutes: window.durationMinutes))：剩余 \(window.remainingPercent)%"
        }
        return "\(windowName(durationMinutes: window.durationMinutes)): \(window.remainingPercent)% remaining"
    }

    func resetDescription(date: Date) -> String {
        if language == .simplifiedChinese {
            return "  重置：\(fullDate(date))（\(longRemaining(until: date))）"
        }
        return "  Resets: \(fullDate(date)) (\(longRemaining(until: date)))"
    }

    func planDescription(_ plan: String) -> String {
        language == .simplifiedChinese
            ? "方案：\(plan.uppercased())"
            : "Plan: \(plan.uppercased())"
    }

    func updatedDescription(_ date: Date) -> String {
        if language == .simplifiedChinese {
            return "更新：\(updateTime(date)) · 实时连接 / 5 秒校准"
        }
        return "Updated: \(updateTime(date)) · persistent connection / 5-second refresh"
    }

    func forecast24hDescription(_ probability: Int?) -> String {
        let value = probability.map { "\($0)%" } ?? "--"
        return language == .simplifiedChinese
            ? "未来 24 小时：\(value)"
            : "Next 24 hours: \(value)"
    }

    func forecast48hDescription(_ probability: Int?) -> String {
        let value = probability.map { "\($0)%" } ?? "--"
        return language == .simplifiedChinese
            ? "未来 48 小时：\(value)"
            : "Next 48 hours: \(value)"
    }

    func forecastConfidenceDescription(_ confidence: ForecastConfidence?) -> String {
        let value: String
        switch (language, confidence) {
        case (.simplifiedChinese, .low?): value = "低"
        case (.simplifiedChinese, .medium?): value = "中"
        case (.simplifiedChinese, .high?): value = "高"
        case (.english, .low?): value = "Low"
        case (.english, .medium?): value = "Medium"
        case (.english, .high?): value = "High"
        case (_, nil): value = "--"
        }
        return language == .simplifiedChinese ? "置信度：\(value)" : "Confidence: \(value)"
    }

    func forecastStatusDescription(_ status: ForecastDisplayStatus) -> String {
        let value: String
        switch (language, status) {
        case (.simplifiedChinese, .recentlyReset): value = "最近已全局重置"
        case (.simplifiedChinese, .strongSignal): value = "Tibo 强信号"
        case (.simplifiedChinese, .forecast): value = "常规预测"
        case (.simplifiedChinese, .cached): value = "数据延迟"
        case (.simplifiedChinese, .unavailable): value = "暂无可信预测"
        case (.english, .recentlyReset): value = "Recently reset globally"
        case (.english, .strongSignal): value = "Strong Tibo signal"
        case (.english, .forecast): value = "Regular forecast"
        case (.english, .cached): value = "Delayed data"
        case (.english, .unavailable): value = "No reliable forecast"
        }
        return language == .simplifiedChinese ? "状态：\(value)" : "Status: \(value)"
    }

    func forecastUpdatedDescription(_ time: String?, isCached: Bool) -> String {
        let value = time ?? "--"
        if language == .simplifiedChinese {
            return "预测更新：\(value)" + (isCached ? " · 缓存" : "")
        }
        return "Forecast updated: \(value)" + (isCached ? " · cached" : "")
    }

    func runningDescription(_ count: Int) -> String {
        language == .simplifiedChinese
            ? "▶ 正常执行：\(count)"
            : "▶ Running: \(count)"
    }

    func failedDescription(_ count: Int) -> String {
        language == .simplifiedChinese
            ? "⚠ 异常：\(count)"
            : "⚠ Errors: \(count)"
    }

    func refreshFailed(_ message: String, preservesLastResult: Bool) -> String {
        if language == .simplifiedChinese {
            return preservesLastResult
                ? "刷新失败：\(message)\n将保留上次结果"
                : message
        }
        return preservesLastResult
            ? "Refresh failed: \(message)\nKeeping the last result"
            : message
    }

    func connectionSuccess(summary: String, running: Int) -> String {
        if language == .simplifiedChinese {
            return "连接成功：\(summary)，正在执行 \(running)"
        }
        return "Connected: \(summary); running \(running)"
    }

    func connectionFailure(_ message: String) -> String {
        language == .simplifiedChinese ? "连接失败：\(message)" : "Connection failed: \(message)"
    }

    func shortRemaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 86_400 {
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            return language == .simplifiedChinese
                ? "\(days)天\(hours)时\(minutes)分"
                : "\(days)d \(hours)h \(minutes)m"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return language == .simplifiedChinese ? "\(hours)时\(minutes)分" : "\(hours)h \(minutes)m"
        }
        let minutes = max(1, seconds / 60)
        return language == .simplifiedChinese ? "\(minutes)分" : "\(minutes)m"
    }

    func longRemaining(until date: Date, now: Date = Date()) -> String {
        let remaining = shortRemaining(until: date, now: now)
        return language == .simplifiedChinese ? "还剩 \(remaining)" : "\(remaining) remaining"
    }

    func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch language {
        case .simplifiedChinese:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
        case .english:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "MMM d, HH:mm"
        }
        return formatter.string(from: date)
    }

    func updateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    func errorDescription(_ error: Error) -> String {
        guard let usageError = error as? UsageError else {
            return error.localizedDescription
        }
        switch usageError {
        case .codexNotFound:
            return language == .simplifiedChinese
                ? "未找到 Codex。请先安装并登录 Codex 桌面版或 CLI。"
                : "Codex was not found. Install and sign in to the Codex desktop app or CLI."
        case .taskConnectionUnavailable:
            return language == .simplifiedChinese
                ? "Codex 任务连接不可用"
                : "The Codex task connection is unavailable"
        case .usageConnectionUnavailable:
            return language == .simplifiedChinese
                ? "Codex 用量连接不可用"
                : "The Codex usage connection is unavailable"
        case .cannotStartCodex(let details):
            return language == .simplifiedChinese
                ? "无法启动 Codex：\(details)"
                : "Could not start Codex: \(details)"
        case .serverError(let details):
            if let details, !details.isEmpty { return details }
            return language == .simplifiedChinese ? "Codex 查询失败" : "The Codex query failed"
        case .readFailed(let details):
            return language == .simplifiedChinese
                ? "读取 Codex 用量失败：\(details)"
                : "Failed to read Codex usage: \(details)"
        case .connectionClosed:
            return language == .simplifiedChinese
                ? "Codex 用量接口意外断开"
                : "The Codex usage connection closed unexpectedly"
        case .timedOut:
            return language == .simplifiedChinese
                ? "读取 Codex 用量超时"
                : "Reading Codex usage timed out"
        case .invalidUsageResponse:
            return language == .simplifiedChinese
                ? "Codex 返回了无法识别的数据"
                : "Codex returned unrecognized usage data"
        case .noUsageWindows:
            return language == .simplifiedChinese
                ? "账号没有返回可显示的用量窗口"
                : "The account did not return a displayable usage window"
        case .invalidTaskResponse:
            return language == .simplifiedChinese
                ? "Codex 返回了无法识别的任务列表"
                : "Codex returned an unrecognized task list"
        }
    }
}
