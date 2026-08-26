import Foundation

struct RateLimitWindow: Equatable {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    var name: String {
        guard let durationMinutes else { return "用量窗口" }
        if durationMinutes <= 360 { return "\(max(1, durationMinutes / 60)) 小时用量" }
        if durationMinutes >= 10_000 { return "每周用量" }
        if durationMinutes % 1_440 == 0 { return "\(durationMinutes / 1_440) 天用量" }
        return "\(durationMinutes / 60) 小时用量"
    }
}

struct UsageSnapshot: Equatable {
    let windows: [RateLimitWindow]
    let plan: String?
    let fetchedAt: Date

    var headlineWindow: RateLimitWindow? {
        shortWindow
    }

    var shortWindow: RateLimitWindow? {
        windows
            .filter { duration in
                guard let minutes = duration.durationMinutes else { return false }
                return minutes < 10_000
            }
            .min { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) }
    }

    var weeklyWindow: RateLimitWindow? {
        windows
            .filter { ($0.durationMinutes ?? 0) >= 10_000 }
            .max { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
    }
}

enum TaskState: Equatable {
    case running
    case completed
    case failed
}

struct TaskInfo: Equatable {
    let id: String
    let title: String
    let state: TaskState
    let updatedAt: Date
}

struct TaskSnapshot: Equatable {
    let tasks: [TaskInfo]
    let fetchedAt: Date

    var running: [TaskInfo] { tasks.filter { $0.state == .running } }
    var completed: [TaskInfo] { tasks.filter { $0.state == .completed } }
    var failed: [TaskInfo] { tasks.filter { $0.state == .failed } }
}

enum UsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let result = object["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else {
            throw UsageError.invalidUsageResponse
        }

        var windows: [RateLimitWindow] = []
        for key in ["secondary", "primary"] {
            guard let raw = limits[key] as? [String: Any],
                  let used = raw["usedPercent"] as? Int else { continue }
            let duration = raw["windowDurationMins"] as? Int
            let resetTimestamp = raw["resetsAt"] as? TimeInterval
            windows.append(RateLimitWindow(
                usedPercent: used,
                durationMinutes: duration,
                resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
            ))
        }

        guard !windows.isEmpty else {
            throw UsageError.noUsageWindows
        }
        return UsageSnapshot(windows: windows, plan: limits["planType"] as? String, fetchedAt: now)
    }
}

enum TaskParser {
    static func parse(
        _ data: Data,
        now: Date = Date(),
        fileState: (String, Date) -> TaskState? = stateFromLog
    ) throws -> TaskSnapshot {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]] else {
            throw UsageError.invalidTaskResponse
        }

        let recentCutoff = now.addingTimeInterval(-86_400)
        var tasks: [TaskInfo] = []
        for row in rows {
            guard let id = row["id"] as? String,
                  let updatedTimestamp = row["updatedAt"] as? TimeInterval else { continue }
            let updatedAt = Date(timeIntervalSince1970: updatedTimestamp)
            let runtimeType = (row["status"] as? [String: Any])?["type"] as? String
            let state: TaskState?
            switch runtimeType {
            case "active":
                state = .running
            case "systemError": state = .failed
            default:
                state = (row["path"] as? String).flatMap { fileState($0, now) }
            }

            guard let state else { continue }
            if (state == .completed || state == .failed) && updatedAt < recentCutoff { continue }
            let rawTitle = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["preview"] as? String)
                ?? "未命名任务"
            tasks.append(TaskInfo(
                id: id,
                title: compactTitle(rawTitle),
                state: state,
                updatedAt: updatedAt
            ))
        }
        return TaskSnapshot(tasks: tasks, fetchedAt: now)
    }

    static func stateFromLog(path: String, now: Date) -> TaskState? {
        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let tailSize: UInt64 = 512 * 1_024
        try? handle.seek(toOffset: size > tailSize ? size - tailSize : 0)
        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { return nil }
        let text = String(decoding: data, as: UTF8.self)

        let signals = logSignals(from: text)
        if let lifecycleState = signals.lifecycleState {
            if lifecycleState == .running,
               now.timeIntervalSince(modifiedAt) > 1_800 {
                // 过久未更新的未完成日志视为中断，不误报为运行中。
                return nil
            }
            return lifecycleState
        }
        // 长任务可能让生命周期标志落在 512 KB 读取窗口之外；只要日志近期仍在
        // 写入且末尾存在活动记录，就视为运行中。
        if now.timeIntervalSince(modifiedAt) <= 1_800,
           signals.hasActivity {
            return .running
        }
        return nil
    }
}

private extension TaskParser {
    struct LogSignals {
        var lifecycleState: TaskState?
        var hasActivity = false
    }

    static func logSignals(from text: String) -> LogSignals {
        var signals = LogSignals()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recordType = record["type"] as? String else { continue }
            if recordType == "event_msg" || recordType == "response_item" {
                signals.hasActivity = true
            }
            guard recordType == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }
            switch eventType {
            case "user_message", "task_started":
                signals.lifecycleState = .running
            case "task_complete":
                signals.lifecycleState = .completed
            default:
                break
            }
        }
        return signals
    }

    static func compactTitle(_ title: String) -> String {
        let singleLine = title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.count > 36 ? String(singleLine.prefix(35)) + "…" : singleLine
    }
}

enum UsageError: LocalizedError {
    case codexNotFound
    case taskConnectionUnavailable
    case usageConnectionUnavailable
    case cannotStartCodex(String)
    case serverError(String?)
    case readFailed(String)
    case connectionClosed
    case timedOut
    case invalidUsageResponse
    case noUsageWindows
    case invalidTaskResponse

    var errorDescription: String? {
        AppText.current.errorDescription(self)
    }
}
