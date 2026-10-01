import Foundation
import Darwin

enum ScheduledMessageError: LocalizedError {
    case invalidInput, invalidDate, missingTask, alreadyStarted, invalidStoredData, collision, commandFailed

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "请填写有效的任务 ID、消息并选择模型。 / Enter a valid task ID, message, and model."
        case .invalidDate: return "请选择未来一年内的时间。 / Choose a time within the next year."
        case .missingTask: return "找不到指定任务。 / The selected task was not found."
        case .alreadyStarted: return "消息正在发送，暂时无法取消或再次启动。 / Delivery is in progress and cannot be cancelled or started again."
        case .invalidStoredData: return "定时消息记录损坏。 / The scheduled message record is invalid."
        case .collision: return "后台任务标签已被占用。 / The background job label is already in use."
        case .commandFailed: return "后台任务操作失败。 / The background job command failed."
        }
    }
}

enum ScheduledMessageState: String, Codable {
    case pending, sending, sent, failed
}

struct ScheduledMessage: Codable, Identifiable {
    let id: UUID
    let fireDate: Date
    let threadID: String
    let threadTitle: String
    let model: String
    let effort: String?
    let message: String
    // Decode old preview records so they remain visible and removable, but never deliver them.
    let targetKind: String?
    var isUnsupportedNewTask: Bool { targetKind == "newChat" }
    var attachments: [ScheduledMessageAttachment]?
    var state: ScheduledMessageState
    var result: String?

    init(id: UUID = UUID(), fireDate: Date, threadID: String, threadTitle: String, model: String,
         message: String, effort: String? = nil, attachments: [ScheduledMessageAttachment]? = nil, state: ScheduledMessageState = .pending, result: String? = nil) {
        self.id = id
        self.attachments = attachments
        self.targetKind = nil
        self.fireDate = Calendar.current.dateInterval(of: .minute, for: fireDate)?.start ?? fireDate
        self.threadID = UUID(uuidString: threadID)?.uuidString.lowercased() ?? threadID
        self.threadTitle = threadTitle
        self.model = model; self.effort = effort; self.message = message; self.state = state; self.result = result
    }

    func validate(now: Date = Date()) throws {
        guard !isUnsupportedNewTask, UUID(uuidString: threadID) != nil, (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentItems.isEmpty),
              message.utf8.count <= 64_000,
              effort == nil || ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort!),
              model.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw ScheduledMessageError.invalidInput
        }
        guard fireDate > now.addingTimeInterval(15), fireDate < now.addingTimeInterval(365 * 86_400) else {
            throw ScheduledMessageError.invalidDate
        }
    }
}

struct ScheduledMessageStore {
    let root: URL
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaMenu/ScheduledMessages", isDirectory: true)) {
        self.root = root
    }

    func url(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    func all() throws -> [ScheduledMessage] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ScheduledMessage.self, from: Data(contentsOf: $0)) }
            .sorted { $0.fireDate < $1.fireDate }
    }

    func read(_ id: UUID) throws -> ScheduledMessage {
        let item = try JSONDecoder().decode(ScheduledMessage.self, from: Data(contentsOf: url(for: id)))
        guard item.id == id, (UUID(uuidString: item.threadID) != nil || (item.isUnsupportedNewTask && item.threadID.isEmpty)) else { throw ScheduledMessageError.invalidStoredData }
        return item
    }

    // One lock spans state inspection and the complete delivery attempt in all processes.
    func withLock<T>(_ id: UUID, body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(root.appendingPathComponent(id.uuidString + ".lock").path,
                                     O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ScheduledMessageError.commandFailed }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ScheduledMessageError.alreadyStarted }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func write(_ item: ScheduledMessage) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(item)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ScheduledMessageError.commandFailed
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let destination = url(for: item.id)
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw ScheduledMessageError.commandFailed }
    }
}

struct ScheduledMessageScheduler {
    static let labelPrefix = "com.local.codexquotamenu.message."
    let store: ScheduledMessageStore
    let agentsDirectory: URL
    let executable: URL
    let controller: any LaunchctlControlling

    init(store: ScheduledMessageStore = .init(),
         agentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
         executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
         controller: any LaunchctlControlling = LaunchctlController()) {
        self.store = store; self.agentsDirectory = agentsDirectory; self.executable = executable
        self.controller = controller
    }

    func label(_ id: UUID) -> String { Self.labelPrefix + id.uuidString.lowercased() }
    func plistURL(_ id: UUID) -> URL { agentsDirectory.appendingPathComponent(label(id) + ".plist") }

    func plist(_ item: ScheduledMessage, calendar: Calendar = .current) throws -> Data {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: item.fireDate)
        guard let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else {
            throw ScheduledMessageError.invalidDate
        }
        return try PropertyListSerialization.data(fromPropertyList: [
            "Label": label(item.id),
            "ProgramArguments": [executable.path, "--send-scheduled-message", item.id.uuidString],
            "StartCalendarInterval": ["Month": month, "Day": day, "Hour": hour, "Minute": minute],
            "RunAtLoad": true,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"
        ], format: .xml, options: 0)
    }

    func schedule(_ item: ScheduledMessage) throws {
        try item.validate()
        let target = plistURL(item.id)
        guard !FileManager.default.fileExists(atPath: target.path),
              !FileManager.default.fileExists(atPath: store.url(for: item.id).path) else { throw ScheduledMessageError.collision }
        guard try !controller.isLoaded(label: label(item.id)) else { throw ScheduledMessageError.collision }
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try ScheduledMessageAttachmentStore(root: store.root).validate(item.attachmentItems, id: item.id)
        try store.write(item)
        do {
            try plist(item).write(to: target, options: .atomic)
            try controller.bootstrap(plistURL: target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: store.url(for: item.id))
            try? ScheduledMessageAttachmentStore(root: store.root).remove(item.id)
            throw error
        }
    }

    func cancel(_ item: ScheduledMessage) throws {
        try store.withLock(item.id) { try cancelLocked(item.id) }
    }

    private func cancelLocked(_ id: UUID) throws {
        let item = try store.read(id)
        try verifyOwnedPlist(id)
        if try controller.isLoaded(label: label(item.id)) {
            try controller.bootout(label: label(item.id))
        }
        let target = plistURL(item.id)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try ScheduledMessageAttachmentStore(root: store.root).remove(item.id)
        try FileManager.default.removeItem(at: store.url(for: item.id))
    }

    func retire(_ id: UUID) {
        guard (try? verifyOwnedPlist(id)) != nil else { return }
        let target = plistURL(id)
        try? FileManager.default.removeItem(at: target)
        try? controller.bootout(label: label(id))
    }

    private func verifyOwnedPlist(_ id: UUID) throws {
        let target = plistURL(id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: target), format: nil) as? [String: Any],
              raw["Label"] as? String == label(id),
              let arguments = raw["ProgramArguments"] as? [String], arguments.count == 3,
              arguments[1] == "--send-scheduled-message", UUID(uuidString: arguments[2]) == id else {
            throw ScheduledMessageError.collision
        }
    }
}
