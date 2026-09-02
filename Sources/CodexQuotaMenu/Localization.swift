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

    var phoneWidgetHeading: String {
        language == .simplifiedChinese ? "手机小组件" : "Phone Widget"
    }

    var enableWidgetServerAction: String {
        language == .simplifiedChinese ? "启用只读接口" : "Enable Read-Only API"
    }

    var copyWidgetAddressAction: String {
        language == .simplifiedChinese ? "复制小组件地址" : "Copy Widget Address"
    }

    var copyWidgetTokenAction: String {
        language == .simplifiedChinese ? "复制访问令牌" : "Copy Access Token"
    }

    var regenerateWidgetTokenAction: String {
        language == .simplifiedChinese ? "重新生成访问令牌" : "Regenerate Access Token"
    }

    var widgetServerFailed: String {
        language == .simplifiedChinese ? "服务启动失败" : "Service Failed to Start"
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

    var activationScheduleAction: String {
        language == .simplifiedChinese ? "激活时间设置…" : "Activation Times…"
    }

    var activationScheduleWindowTitle: String {
        language == .simplifiedChinese ? "激活时间设置" : "Activation Times"
    }

    var activationScheduleHeading: String {
        language == .simplifiedChinese ? "每日自动激活时间" : "Daily Activation Times"
    }

    var addActivationTimeAction: String {
        language == .simplifiedChinese ? "添加时间" : "Add Time"
    }

    var deleteActivationTimeAction: String {
        language == .simplifiedChinese ? "删除" : "Delete"
    }

    var activationEnabledLabel: String {
        language == .simplifiedChinese ? "启用" : "Enabled"
    }

    var refreshActivationStatusAction: String {
        language == .simplifiedChinese ? "重试检测" : "Retry Check"
    }

    var syncToCodexAction: String {
        language == .simplifiedChinese ? "应用到 Codex" : "Apply to Codex"
    }

    var activationUnconfiguredStatus: String {
        language == .simplifiedChinese ? "未配置" : "Not Configured"
    }

    var activationSyncedStatus: String {
        language == .simplifiedChinese ? "已同步" : "Synced"
    }

    var activationPendingStatus: String {
        language == .simplifiedChinese ? "待同步" : "Pending"
    }

    var activationUnavailableStatus: String {
        language == .simplifiedChinese ? "状态不可用" : "Unavailable"
    }

    var activationUnavailableDescription: String {
        language == .simplifiedChinese
            ? "无法读取 Codex 计划任务状态。请稍后重试。"
            : "Could not read Codex automation status. Try again later."
    }

    var activationEmptyListDescription: String {
        language == .simplifiedChinese
            ? "尚未设置激活时间。同步可清理全部受管任务。"
            : "No activation times yet. Syncing can remove all managed tasks."
    }

    var activationTasksAppliedStatus: String {
        language == .simplifiedChinese
            ? "已应用到 Codex，状态将自动检测。"
            : "Applied to Codex. Status will be checked automatically."
    }

    var activationDirectSyncFailedStatus: String {
        language == .simplifiedChinese
            ? "无法安全应用。Codex 计划任务可能未更改，或已恢复原状。"
            : "Could not apply safely. Codex automations may be unchanged or already restored."
    }

    func activationRecoveryRequiredError(path: String) -> String {
        language == .simplifiedChinese
            ? "无法确认计划任务已恢复。请勿删除恢复副本：\(path)"
            : "Recovery could not be verified. Do not delete the recovery copy at: \(path)"
    }

    var activationCorruptStorageStatus: String {
        language == .simplifiedChinese
            ? "设置存储已损坏；编辑和同步已禁用。"
            : "The stored settings are corrupt; editing and sync are disabled."
    }

    var duplicateActivationTimeError: String {
        language == .simplifiedChinese ? "激活时间不能重复。" : "Activation times cannot be duplicated."
    }

    var activationSaveFailedError: String {
        language == .simplifiedChinese ? "无法保存激活时间。" : "Could not save the activation time."
    }

    var activationScheduleFullError: String {
        language == .simplifiedChinese
            ? "一天的 1,440 个分钟时间均已占用。"
            : "All 1,440 daily minutes are already in use."
    }

    var activationMissingDifferenceLabel: String {
        language == .simplifiedChinese ? "缺少" : "Missing"
    }

    var activationExtraDifferenceLabel: String {
        language == .simplifiedChinese ? "多余" : "Extra"
    }

    var activationDuplicateDifferenceLabel: String {
        language == .simplifiedChinese ? "重复" : "Duplicate"
    }

    var activationPausedDifferenceLabel: String {
        language == .simplifiedChinese ? "已暂停" : "Paused"
    }

    var activationMisconfiguredDifferenceLabel: String {
        language == .simplifiedChinese ? "配置不一致" : "Misconfigured"
    }

    var activationUnmatchedNamesDifferenceLabel: String {
        language == .simplifiedChinese ? "无法识别的受管名称" : "Unrecognized managed names"
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

    func forecast48hDescription(_ probability: Int?) -> String {
        let value = probability.map { "\($0)%" } ?? "--"
        return language == .simplifiedChinese
            ? "未来 48 小时：\(value)"
            : "Next 48 hours: \(value)"
    }

    func forecastStatusDescription(_ status: ForecastDisplayStatus) -> String {
        let value: String
        switch (language, status) {
        case (.simplifiedChinese, .fresh): value = "实时"
        case (.simplifiedChinese, .cached): value = "数据延迟"
        case (.simplifiedChinese, .unavailable): value = "暂不可用"
        case (.english, .fresh): value = "Fresh"
        case (.english, .cached): value = "Delayed data"
        case (.english, .unavailable): value = "Unavailable"
        }
        return language == .simplifiedChinese ? "状态：\(value)" : "Status: \(value)"
    }

    var forecastSourceDescription: String {
        language == .simplifiedChinese ? "来源：Codex Reset Monitor" : "Source: Codex Reset Monitor"
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

    func compactRemaining(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 86_400 {
            let days = seconds / 86_400
            return language == .simplifiedChinese ? "\(days)天" : "\(days)d"
        }
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            return language == .simplifiedChinese ? "\(hours)时" : "\(hours)h"
        }
        let minutes = seconds / 60
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
