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
        windows.min { ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max) }
    }
}

enum TaskState: Equatable {
    case running
    case waiting
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
    var waiting: [TaskInfo] { tasks.filter { $0.state == .waiting } }
    var completed: [TaskInfo] { tasks.filter { $0.state == .completed } }
    var failed: [TaskInfo] { tasks.filter { $0.state == .failed } }
}

enum UsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
              let result = object["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else {
            throw UsageError.invalidResponse("Codex 返回了无法识别的数据")
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
            throw UsageError.invalidResponse("账号没有返回可显示的用量窗口")
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
            throw UsageError.invalidResponse("Codex 返回了无法识别的任务列表")
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
                let flags = (row["status"] as? [String: Any])?["activeFlags"] as? [String] ?? []
                state = flags.isEmpty ? .running : .waiting
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
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let lastUser = text.range(of: #""type":"user_message""#, options: .backwards)?.lowerBound
        let lastComplete = text.range(of: #""type":"task_complete""#, options: .backwards)?.lowerBound
        if let lastUser, lastComplete == nil || lastUser > lastComplete! {
            // 正在执行的日志会持续写入；过久未更新的未完成日志视为中断，不误报为运行中。
            guard now.timeIntervalSince(modifiedAt) <= 1_800 else { return nil }
            return hasPendingManualAction(in: data) ? .waiting : .running
        }
        if lastComplete != nil {
            return waitsForExplicitReply(in: data) ? .waiting : .completed
        }
        // 长任务可能让本次 user_message 落在 512 KB 读取窗口之外；只要日志近期仍在
        // 写入且末尾没有 task_complete，就视为运行中。
        if now.timeIntervalSince(modifiedAt) <= 1_800,
           text.contains(#""type":"response_item""#) || text.contains(#""type":"event_msg""#) {
            return hasPendingManualAction(in: data) ? .waiting : .running
        }
        return nil
    }

    private static func hasPendingManualAction(in data: Data) -> Bool {
        var pending = Set<String>()
        for rawLine in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: rawLine) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }

            if type == "custom_tool_call" || type == "function_call" {
                guard let callID = payload["call_id"] as? String else { continue }
                let name = payload["name"] as? String ?? ""
                let input = payload["input"] as? String ?? ""
                let asksForInput = name == "request_user_input" || name.contains("user_input")
                let asksForApproval = input.contains("require_escalated") || input.contains("justification")
                if asksForInput || asksForApproval { pending.insert(callID) }
            } else if type == "custom_tool_call_output" || type == "function_call_output" {
                if let callID = payload["call_id"] as? String { pending.remove(callID) }
            }
        }
        return !pending.isEmpty
    }

    private static func waitsForExplicitReply(in data: Data) -> Bool {
        var lastUserIndex = -1
        var lastCompleteIndex = -1
        var finalMessages: [(index: Int, message: String)] = []

        for (index, rawLine) in data.split(separator: 0x0A).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: rawLine) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "user_message":
                lastUserIndex = index
                finalMessages.removeAll(keepingCapacity: true)
            case "task_complete":
                lastCompleteIndex = index
            case "agent_message":
                if payload["phase"] as? String == "final_answer" {
                    finalMessages.append((index, payload["message"] as? String ?? ""))
                }
            default:
                break
            }
        }

        guard lastCompleteIndex > lastUserIndex else { return false }
        let message = finalMessages
            .filter { $0.index > lastUserIndex && $0.index <= lastCompleteIndex }
            .map(\.message)
            .joined(separator: "\n")
        return ReplyIntentClassifier.isWaitingForUser(fullReply: message)
    }
}

enum ReplyIntentClassifier {
    private static let action = "(提供|填写|选择|上传|回复|确认|补充|回答|输入|勾选|告诉|发送|提交)"

    static func isWaitingForUser(fullReply: String) -> Bool {
        let message = removingQuotedExamplesAndCode(from: fullReply).lowercased()
        guard !message.isEmpty else { return false }

        // 先按完整回复识别“确实仍依赖用户下一步”的意图。单独出现动作词、
        // 已完成的动作、可选建议或对功能的说明都不会触发等待。
        let waitingPatterns = [
            "(请你|请您|麻烦你|麻烦您|烦请|还请|劳烦|请)[^。！？\\n；;]{0,24}\(action)",
            "(需要|等待)(你|您)[^。！？\\n；;]{0,24}\(action)",
            "\(action)[^。！？\\n；;]{0,20}(后|以后|之后)[^。！？\\n；;]{0,30}(我|我们)[^。！？\\n；;]{0,16}(继续|开始|处理)",
            "(你|您)[^。！？\\n]{0,36}(选哪|哪一个|哪一种|哪种|是否|能否|可以吗|想要什么|希望什么)[^。！\\n]{0,16}[？?]",
            "please[^.!?\\n]{0,36}(provide|reply|confirm|choose|select|enter|fill|upload|answer|send|submit)",
            "(need|waiting for) you to[^.!?\\n]{0,36}(provide|reply|confirm|choose|select|enter|fill|upload|answer|send|submit)"
        ]

        for clause in message.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n；;")) {
            let text = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if isNegatedOrInformational(text) { continue }
            if waitingPatterns.prefix(3).contains(where: { matches($0, in: text) }) {
                return true
            }
        }
        return waitingPatterns.dropFirst(3).contains { matches($0, in: message) }
    }

    private static func isNegatedOrInformational(_ text: String) -> Bool {
        let nonWaitingPatterns = [
            "(无需|不需要|不用|不必|请勿)[^。！？\\n]{0,20}\(action)",
            "(已经|已|刚刚|成功)[^。！？\\n]{0,12}\(action)[^。！？\\n]{0,12}(完成|完毕|成功|到)",
            "\(action)[^。！？\\n]{0,10}(完成|完毕|成功)(了|，|,|$)",
            "^(如果|如有).{0,24}(需要|想要).{0,24}(我|我们)(可以|能)",
            "^(你|您)(可以|可)[^。！？\\n]{0,28}\(action)",
            "^(应用|程序|软件|系统|功能|规则|回复)[^。！？\\n]{0,32}(要求|支持|允许|判断|检测)[^。！？\\n]{0,20}\(action)",
            "^请(注意|知悉|放心)[，,:： ]"
        ]
        return nonWaitingPatterns.contains { matches($0, in: text) }
    }

    private static func removingQuotedExamplesAndCode(from text: String) -> String {
        text
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`\n]*`"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*>\s.*$"#, with: " ", options: .regularExpression)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension TaskParser {
    static func compactTitle(_ title: String) -> String {
        let singleLine = title.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.count > 36 ? String(singleLine.prefix(35)) + "…" : singleLine
    }
}

enum UsageError: LocalizedError {
    case codexNotFound
    case processFailed(String)
    case timedOut
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex。请先安装并登录 Codex 桌面版或 CLI。"
        case .processFailed(let message), .invalidResponse(let message):
            return message
        case .timedOut:
            return "读取 Codex 用量超时"
        }
    }
}
