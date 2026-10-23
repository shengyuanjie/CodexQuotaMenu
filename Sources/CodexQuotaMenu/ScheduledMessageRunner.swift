import Foundation
import Darwin

struct ScheduledMessageDeliveryError: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "desktop_visibility_unverified": return "对话可能已创建或消息已发送，但无法核验 Codex 任务列表可见性。请检查任务 ID，不要直接重发。 / The chat may exist or delivery may have completed, but desktop visibility could not be verified. Check the chat ID before resending."
        case "new_chat_creation_unverified": return "新对话创建未通过核验，消息未发送。请检查任务 ID。 / New chat creation could not be verified. The message was not sent. Check the chat ID."
        case "new_task_removed": return "新建任务功能已移除，此消息未发送。请选择已有任务重新安排。 / New chat creation was removed. This message was not sent. Schedule it for an existing chat."
        case "attachment_limit": return "最多 20 个附件，单个不超过 25 MB，总计不超过 100 MB。 / Up to 20 attachments, 25 MB each, 100 MB total."
        case "attachment_invalid", "attachment_image_invalid": return "附件无效或照片格式无法读取，请选择普通文件或有效照片。 / Invalid file or unreadable image."
        case "attachment_changed", "attachment_unavailable": return "保存的附件已变更或无法读取，消息未发送。请重新安排。 / Saved attachments changed or are unavailable. Schedule again."
        case "directory_access_denied": return "无法访问目标任务的工作目录，请检查文稿等文件夹的访问权限。 / Access to the chat working directory was denied. Check Files and Folders permissions."
        case "directory_missing": return "目标任务的工作目录已不存在。 / The chat working directory no longer exists."
        case "directory_unavailable": return "无法读取目标任务的工作目录。 / The chat working directory is unavailable."
        case "desktop_connection_failed", "desktop_request_timeout", "desktop_status_timeout": return "无法连接或读取 Codex 桌面端会话。 / Cannot connect to or read the Codex desktop session."
        case "desktop_delivery_unverified", "completion_unverified", "turn_unverified": return "消息可能已提交，但无法核验完成；请检查目标任务，不要直接重发。 / Delivery may have been accepted, but completion is unverified. Check the chat before resending."
        default: return code
        }
    }
}

struct ScheduledMessageTarget {
    let directory: URL
    let effort: String?
}

struct ScheduledMessageRunner {
    let store: ScheduledMessageStore
    let scheduler: ScheduledMessageScheduler
    var now: () -> Date = Date.init
    var resolveThread: (String) throws -> ScheduledMessageTarget = { id in
        try resolveTarget(id: id, readDesktop: { id in
            let desktop = ScheduledMessageDesktopClient()
            guard try desktop.connect(), let owner = try desktop.owner(threadID: id) else { return nil }
            return try desktop.snapshot(threadID: id, owner: owner)
        }, readCLI: { id in
            let result = try CodexClient().modelRequest("thread/read", params: ["threadId": id, "includeTurns": false])
            guard let thread = result["thread"] as? [String: Any] else { throw ScheduledMessageError.missingTask }
            return thread
        })
    }

    // Desktop metadata is authoritative for an owned chat; no project filesystem access is needed.
    static func resolveTarget(id: String, readDesktop: (String) throws -> [String: Any]?,
                              readCLI: (String) throws -> [String: Any],
                              checkDirectory: (URL) throws -> Void = checkWorkingDirectory) throws -> ScheduledMessageTarget {
        let desktop = try readDesktop(id)
        let thread = try desktop ?? readCLI(id)
        guard thread["id"] as? String == id, thread["canAcceptDirectInput"] as? Bool != false,
              let path = thread["cwd"] as? String, path.hasPrefix("/") else { throw ScheduledMessageError.missingTask }
        let directory = URL(fileURLWithPath: path)
        if desktop == nil { try checkDirectory(directory) }
        return ScheduledMessageTarget(directory: directory,
            effort: thread["reasoningEffort"] as? String ?? thread["latestReasoningEffort"] as? String)
    }

    static func directoryFailure(_ error: Int32) -> ScheduledMessageDeliveryError {
        switch error {
        case EACCES, EPERM: return .init(code: "directory_access_denied")
        case ENOENT, ENOTDIR: return .init(code: "directory_missing")
        default: return .init(code: "directory_unavailable")
        }
    }

    static func checkWorkingDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw directoryFailure(errno) }
        defer { Darwin.close(descriptor) }
        guard directory.path.withCString({ Darwin.access($0, R_OK | X_OK) }) == 0 else {
            throw directoryFailure(errno)
        }
    }
    var resolveEffort: (String, String?, String?) throws -> String = { model, requested, inherited in
        guard let option = try DefaultModelSettingsService().load().models.first(where: { $0.id == model }) else {
            throw ScheduledMessageError.invalidInput
        }
        return try selectedEffort(option: option, requested: requested, inherited: inherited)
    }

    static func selectedEffort(option: CodexModelOption, requested: String?, inherited: String?) throws -> String {
        if let requested {
            guard option.efforts.contains(requested) else { throw ScheduledMessageError.invalidInput }
            return requested
        }
        if let inherited, option.efforts.contains(inherited) { return inherited }
        guard let fallback = option.efforts.first else { throw ScheduledMessageError.invalidInput }
        return option.efforts.contains(option.defaultEffort) ? option.defaultEffort : fallback
    }
    var send: (ScheduledMessage, ScheduledMessageTarget, String) throws -> Bool = { item, target, effort in
        let desktop = ScheduledMessageDesktopClient()
        if try desktop.connect(), let owner = try desktop.owner(threadID: item.threadID) {
            return try desktop.deliver(item, owner: owner, effort: effort, directory: target.directory)
        }
        // Ownership can change after preflight, so recheck permissions before CLI fallback.
        try checkWorkingDirectory(target.directory)
        return try runCodex(item, directory: target.directory, effort: effort)
    }

    var sendNew: (ScheduledMessage, ScheduledMessageTarget, String, (String) throws -> Void) throws -> Bool = { item, target, effort, created in
        try checkWorkingDirectory(target.directory)
        let client = CodexClient()
        var prepared = item
        prepared.threadID = try createVisibleChat(item, directory: target.directory,
            request: client.modelRequest, onCreated: created)
        let completed = try client.completeScheduledTurn(prepared, directory: target.directory, effort: effort)
        try verifyVisibleChat(prepared.threadID, directory: target.directory, request: client.modelRequest)
        return completed
    }

    static func createVisibleChat(_ item: ScheduledMessage, directory: URL,
                                  request: (String, [String: Any]) throws -> [String: Any],
                                  onCreated: (String) throws -> Void) throws -> String {
        let response = try request("thread/start", ["cwd": directory.path, "model": item.model,
            "ephemeral": false, "threadSource": "user"])
        guard let thread = response["thread"] as? [String: Any],
              let id = thread["id"] as? String, UUID(uuidString: id) != nil else {
            throw ScheduledMessageDeliveryError(code: "new_chat_creation_unverified")
        }
        // Save the at-most-once boundary even if subsequent registration checks fail.
        try onCreated(id)
        guard thread["source"] as? String == "vscode" else {
            throw ScheduledMessageDeliveryError(code: "desktop_visibility_unverified")
        }
        return id
    }

    static func verifyVisibleChat(_ id: String, directory: URL,
                                  request: (String, [String: Any]) throws -> [String: Any]) throws {
        // An omitted source filter uses the same interactive sources as the desktop sidebar.
        let response = try request("thread/list", ["cwd": directory.path, "limit": 100,
            "sortKey": "updated_at", "sortDirection": "desc", "modelProviders": [], "useStateDbOnly": true])
        guard let threads = response["data"] as? [[String: Any]], threads.contains(where: { $0["id"] as? String == id }) else {
            throw ScheduledMessageDeliveryError(code: "desktop_visibility_unverified")
        }
    }

    init(store: ScheduledMessageStore = .init(), scheduler: ScheduledMessageScheduler? = nil) {
        self.store = store
        self.scheduler = scheduler ?? ScheduledMessageScheduler(store: store)
    }

    func run(id: UUID) -> Int32 {
        do { return try store.withLock(id) { runLocked(id: id) } }
        catch ScheduledMessageError.alreadyStarted { return 0 }
        catch { return 2 }
    }

    private func runLocked(id: UUID) -> Int32 {
        guard var item = try? store.read(id) else { return 2 }
        guard item.state == .pending else { scheduler.retire(id); return 0 }
        // launchd may run a missed calendar event after waking. Never deliver early or on a later annual recurrence.
        guard now() >= item.fireDate else { return 0 }
        guard now() < item.fireDate.addingTimeInterval(86_400) else {
            item.state = .failed; item.result = "missed_time"
            try? store.write(item); scheduler.retire(id); return 1
        }
        // Persist the at-most-once boundary before requesting a turn. An interrupted attempt stays visible.
        item.state = .sending
        item.result = "started"
        guard (try? store.write(item)) != nil else { return 2 }
        do {
            try ScheduledMessageAttachmentStore(root: store.root).validate(item.attachmentItems, id: item.id)
            guard !item.isUnsupportedNewTask else {
                throw ScheduledMessageDeliveryError(code: "new_task_removed")
            }
            let target: ScheduledMessageTarget
            if item.isNewTask {
                guard item.threadID.isEmpty, let path = item.newTaskDirectory, path.hasPrefix("/") else {
                    throw ScheduledMessageError.invalidStoredData
                }
                let root = URL(fileURLWithPath: path)
                let directory = try item.usesDefaultNewTaskDirectory == true
                    ? ScheduledMessageWorkspace.create(root: root, message: item.message, date: now()) : root
                try Self.checkWorkingDirectory(directory)
                item.newTaskDirectory = directory.path
                try store.write(item)
                target = ScheduledMessageTarget(directory: directory, effort: nil)
            } else {
                target = try resolveThread(item.threadID)
            }
            let effort = try resolveEffort(item.model, item.effort, target.effort)
            let completed: Bool
            if item.isNewTask {
                completed = try sendNew(item, target, effort) { threadID in
                    guard UUID(uuidString: threadID) != nil else { throw ScheduledMessageError.invalidStoredData }
                    item.threadID = threadID.lowercased()
                    try store.write(item)
                }
            } else {
                completed = try send(item, target, effort)
            }
            item.state = completed ? .sent : .failed
            item.result = completed ? "turn_completed" : "turn_unverified"
        } catch {
            item.state = .failed
            item.result = (error as? ScheduledMessageDeliveryError)?.code
                ?? (error is ScheduledMessageError ? "target_unavailable" : "delivery_failed")
        }
        guard (try? store.write(item)) != nil else { return 2 }
        scheduler.retire(id)
        return item.state == .sent ? 0 : 1
    }

    static func runCodex(_ item: ScheduledMessage, directory workingDirectory: URL, effort: String,
                         executable: URL? = nil, timeout: TimeInterval = 3_600) throws -> Bool {
        guard UUID(uuidString: item.threadID) != nil else { throw ScheduledMessageError.invalidInput }
        let cli = try executable ?? CodexExecutableLocator().findExecutable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CQMMessage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw ScheduledMessageError.commandFailed }
        let outputHandle = try FileHandle(forWritingTo: output)
        defer { try? outputHandle.close() }
        let prompt = directory.appendingPathComponent("prompt.txt")
        guard FileManager.default.createFile(atPath: prompt.path, contents: Data(item.deliveryText.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ScheduledMessageError.commandFailed
        }
        let input = try FileHandle(forReadingFrom: prompt)
        defer { try? input.close() }
        let process = Process()
        process.executableURL = cli
        process.currentDirectoryURL = workingDirectory
        var arguments = ["exec", "--cd", workingDirectory.path, "--skip-git-repo-check"]
        arguments += ["resume", "--all"]
        arguments += ["--json", "--model", item.model, "--config", "model_reasoning_effort=\"\(effort)\""]
        arguments += item.attachmentItems.filter { $0.kind == .image }.flatMap { ["--image", $0.path] }
        arguments += [item.threadID, "-"]
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = outputHandle
        let errorOutput = directory.appendingPathComponent("stderr.txt")
        guard FileManager.default.createFile(atPath: errorOutput.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw ScheduledMessageError.commandFailed }
        let errorHandle = try FileHandle(forWritingTo: errorOutput)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try? FileManager.default.attributesOfItem(atPath: errorOutput.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 20_000_000 || errorSize > 2_000_000 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ScheduledMessageDeliveryError(code: "cli_timeout_or_output_limit")
        }
        guard process.terminationStatus == 0 else {
            let raw = (try? String(contentsOf: errorOutput)) ?? ""
            throw ScheduledMessageDeliveryError(code: classifyFailure(raw, exitCode: process.terminationStatus))
        }
        let data = try Data(contentsOf: output)
        guard data.count <= 20_000_000 else { throw ScheduledMessageDeliveryError(code: "cli_output_limit") }
        var completed = false
        var matchedThread = false
        for line in data.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "turn.failed" || type == "error" {
                let raw = String(data: Data(line), encoding: .utf8) ?? ""
                throw ScheduledMessageDeliveryError(code: classifyFailure(raw, exitCode: 0))
            }
            if type == "thread.started" {
                guard let startedID = event["thread_id"] as? String, UUID(uuidString: startedID) != nil,
                      startedID == item.threadID else { throw ScheduledMessageDeliveryError(code: "thread_id_mismatch") }
                matchedThread = true
            }
            if type == "turn.completed" { completed = true }
        }
        guard matchedThread && completed else { throw ScheduledMessageDeliveryError(code: "completion_unverified") }
        return true
    }

    // Persist only fixed categories, never command output, credentials, or message content.
    static func classifyFailure(_ raw: String, exitCode: Int32) -> String {
        let value = raw.lowercased()
        if value.contains("already has an active writer") || value.contains("thread-store conflict") { return "thread_writer_conflict" }
        if value.contains("unexpected argument") || value.contains("unrecognized subcommand") { return "cli_invalid_arguments" }
        if value.contains("not supported") && value.contains("model") { return "model_unsupported" }
        if value.contains("401") || value.contains("unauthorized") || value.contains("not logged in") { return "authentication_failed" }
        if value.contains("429") || value.contains("usage limit") || value.contains("quota exceeded") || value.contains("quota exhausted") { return "quota_unavailable" }
        if value.contains("approval") || value.contains("hook trust") { return "approval_required" }
        if value.contains("session") && (value.contains("not found") || value.contains("no saved")) { return "session_not_found" }
        if value.contains("connection") || value.contains("stream disconnected") { return "connection_failed" }
        return exitCode == 0 ? "turn_failed" : "cli_exit_\(exitCode)"
    }
}
