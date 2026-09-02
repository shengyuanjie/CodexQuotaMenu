import Foundation

enum ActivationScheduleError: Error, Equatable {
    case invalidTime
    case duplicateTime(ActivationTime)
    case duplicateID(UUID)
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
        var seenIDs = Set<UUID>()
        for entry in entries where !seenIDs.insert(entry.id).inserted {
            throw ActivationScheduleError.duplicateID(entry.id)
        }
        for entry in entries where !seen.insert(entry.time).inserted {
            throw ActivationScheduleError.duplicateTime(entry.time)
        }
        return entries.sorted { $0.time < $1.time }
    }
}

enum ManagedAutomationPolicy {
    static let namePrefix = "CodexQuotaMenu · "
    static let exactNameFormat = "CodexQuotaMenu · HH:mm"
    static let model = "gpt-5.6-luna"
    static let reasoningEffort = "low"
    static let notificationPolicy = "failed_runs_only"
    static let activationPrompt = "这是定时激活请求。只回复“已激活”，不要读取文件、调用工具或执行其他操作。"

    static func name(for time: ActivationTime) -> String {
        namePrefix + time.displayValue
    }

    static func managedTime(from name: String) -> ActivationTime? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let suffix = String(name.dropFirst(namePrefix.count))
        let bytes = Array(suffix.utf8)
        guard bytes.count == 5,
              bytes[2] == 58,
              bytes[0...1].allSatisfy(isASCIIDigit),
              bytes[3...4].allSatisfy(isASCIIDigit),
              let hour = Int(suffix.prefix(2)),
              let minute = Int(suffix.suffix(2)) else {
            return nil
        }
        return try? ActivationTime(hour: hour, minute: minute)
    }

    static func isMalformedPrefixedName(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && managedTime(from: name) == nil
    }

    static var promptOwnershipRule: String {
        """
        只管理名称完整且严格匹配“\(exactNameFormat)”的计划任务（HH 为 00–23，mm 为 00–59）。仅共享“\(namePrefix)”前缀但不完整匹配该格式的名称不是受管任务，例如“CodexQuotaMenu · backup”和“CodexQuotaMenu · 06:00 copy”；这些任务必须保持不变，不得删除、修改或合并。不要修改任何其他计划任务。
        """
    }

    private static func isASCIIDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
    }
}
