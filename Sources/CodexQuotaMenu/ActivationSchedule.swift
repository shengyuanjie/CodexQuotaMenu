import Foundation

enum ActivationScheduleError: Error, Equatable {
    case invalidTime
    case duplicateTime(ActivationTime)
    case corruptStoredData
}

struct ActivationTime: Codable, Hashable, Comparable, Sendable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw ActivationScheduleError.invalidTime
        }
        self.hour = hour
        self.minute = minute
    }

    var displayValue: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    private enum CodingKeys: String, CodingKey { case hour, minute }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            hour: values.decode(Int.self, forKey: .hour),
            minute: values.decode(Int.self, forKey: .minute)
        )
    }
}

struct ActivationScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var time: ActivationTime
    var isEnabled: Bool

    init(id: UUID = UUID(), time: ActivationTime, isEnabled: Bool = true) {
        self.id = id
        self.time = time
        self.isEnabled = isEnabled
    }

    static func normalized(_ entries: [Self]) throws -> [Self] {
        var seen = Set<ActivationTime>()
        for entry in entries where !seen.insert(entry.time).inserted {
            throw ActivationScheduleError.duplicateTime(entry.time)
        }
        return entries.sorted { $0.time < $1.time }
    }
}

enum ManagedAutomationPolicy {
    static let namePrefix = "CodexQuotaMenu · "
    static let model = "gpt-5.6-luna"
    static let reasoningEffort = "low"
    static let notificationPolicy = "failed_runs_only"
    static let activationPrompt = "这是定时激活请求。只回复“已激活”，不要读取文件、调用工具或执行其他操作。"

    static func name(for time: ActivationTime) -> String {
        namePrefix + time.displayValue
    }
}
