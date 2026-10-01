import Foundation
import Darwin

// The desktop coordinator routes to the existing writer. Never open a second writer for an owned chat.
final class ScheduledMessageDesktopClient {
    // Desktop snapshots include loaded tool history; long chats can exceed 20 MB.
    // Keep a separate bounded receive limit; outbound scheduled messages remain capped at 1 MB.
    static let maximumReceiveFrameBytes: UInt32 = 128_000_000

    static func validateReceiveFrameLength(_ length: UInt32) throws {
        guard length > 0, length <= maximumReceiveFrameBytes else {
            throw ScheduledMessageDeliveryError(code: "desktop_frame_limit")
        }
    }

    private var descriptor: Int32 = -1
    private var clientID = "initializing-client"
    private let socketURL: URL

    init(socketURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")) {
        self.socketURL = socketURL
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func connect() throws -> Bool {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        let parent = try FileManager.default.attributesOfItem(atPath: socketURL.deletingLastPathComponent().path)
        guard attributes[.type] as? FileAttributeType == .typeSocket,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (parent[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((parent[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
            throw ScheduledMessageDeliveryError(code: "desktop_socket_untrusted")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ScheduledMessageDeliveryError(code: "desktop_socket_invalid")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ScheduledMessageDeliveryError(code: "desktop_connection_failed") }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ScheduledMessageDeliveryError(code: "desktop_connection_failed") }
        let response = try request("initialize", version: 0, params: ["clientType": "codexquotamenu"])
        guard let id = (response["result"] as? [String: Any])?["clientId"] as? String else {
            throw ScheduledMessageDeliveryError(code: "desktop_protocol_invalid")
        }
        clientID = id
        return true
    }

    func owner(threadID: String) throws -> String? {
        let response = try request("thread-owner-discovery", version: 1,
                                   params: ["hostId": "local", "conversationId": threadID], allowNoOwner: true)
        if response["error"] as? String == "no-client-found" { return nil }
        guard let id = response["handledByClientId"] as? String else {
            throw ScheduledMessageDeliveryError(code: "desktop_protocol_invalid")
        }
        return id
    }

    func snapshot(threadID: String, owner: String) throws -> [String: Any] {
        try write(["type": "broadcast", "sourceClientId": clientID, "version": 1,
                   "method": "thread-stream-following-changed", "targetClientIds": [owner],
                   "params": ["hostId": "local", "conversationId": threadID, "following": true]])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let message = try read(deadline: deadline)
            guard message["type"] as? String == "broadcast",
                  message["method"] as? String == "thread-stream-state-changed",
                  message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any], params["conversationId"] as? String == threadID,
                  let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                  let state = change["conversationState"] as? [String: Any] else { continue }
            guard state["id"] as? String == threadID else { throw ScheduledMessageDeliveryError(code: "thread_id_mismatch") }
            return state
        }
        throw ScheduledMessageDeliveryError(code: "desktop_status_timeout")
    }

    static func isBusy(_ state: [String: Any]) -> Bool {
        if let runtime = state["threadRuntimeStatus"] as? [String: Any], let type = runtime["type"] as? String {
            return type == "active"
        }
        return turns(state).last?["status"] as? String == "inProgress"
    }

    static func turns(_ state: [String: Any]) -> [[String: Any]] {
        var rows = state["turns"] as? [[String: Any]] ?? []
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any],
           let islands = history["islands"] as? [[String: Any]] {
            let entities = history["entitiesByKey"] as? [String: [String: Any]] ?? [:]
            for island in islands {
                for entry in island["entries"] as? [[String: Any]] ?? [] {
                    if let key = entry["key"] as? String, let turn = entities[key], turn["turnId"] != nil {
                        rows.append(turn)
                    } else if let turn = entry["turn"] as? [String: Any] { rows.append(turn) }
                }
            }
        }
        return rows
    }

    static func turnRequest(_ item: ScheduledMessage, effort: String, directory: URL) -> [String: Any] {
        ["threadId": item.threadID, "clientUserMessageId": item.id.uuidString.lowercased(),
         "model": item.model, "effort": effort, "cwd": directory.path,
         "input": item.deliveryInput]
    }

    func deliver(_ item: ScheduledMessage, owner: String, effort: String, directory: URL,
                 timeout: TimeInterval = 3_600) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Self.isBusy(try snapshot(threadID: item.threadID, owner: owner)) {
            guard Date() < deadline else { throw ScheduledMessageDeliveryError(code: "target_busy_timeout") }
            Thread.sleep(forTimeInterval: 2)
        }
        let response = try request("thread-follower-start-turn", version: 2,
            params: ["conversationId": item.threadID,
                     "turnStart": ["request": Self.turnRequest(item, effort: effort, directory: directory),
                                   "context": ["inheritThreadSettings": false, "useAppServerPermissionDefault": true]]],
            owner: owner)
        guard response["handledByClientId"] as? String == owner,
              let result = response["result"] as? [String: Any],
              let inner = result["result"] as? [String: Any],
              let turn = inner["turn"] as? [String: Any], let turnID = turn["id"] as? String else {
            throw ScheduledMessageDeliveryError(code: "desktop_delivery_unverified")
        }
        while Date() < deadline {
            let state = try snapshot(threadID: item.threadID, owner: owner)
            if let completed = Self.turns(state).first(where: { $0["turnId"] as? String == turnID }) {
                switch completed["status"] as? String {
                case "completed": return true
                case "failed", "interrupted": throw ScheduledMessageDeliveryError(code: "turn_failed")
                default: break
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw ScheduledMessageDeliveryError(code: "completion_unverified")
    }

    private func request(_ method: String, version: Int, params: [String: Any], owner: String? = nil,
                         allowNoOwner: Bool = false) throws -> [String: Any] {
        let id = UUID().uuidString.lowercased()
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
                                      "version": version, "method": method, "params": params, "timeoutMs": 20_000]
        if let owner { message["targetClientId"] = owner }
        try write(message)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let response = try read(deadline: deadline)
            guard response["type"] as? String == "response", response["requestId"] as? String == id else { continue }
            if allowNoOwner, response["error"] as? String == "no-client-found" { return response }
            guard response["resultType"] as? String == "success", response["method"] as? String == method else {
                throw ScheduledMessageDeliveryError(code: "desktop_request_rejected")
            }
            return response
        }
        throw ScheduledMessageDeliveryError(code: "desktop_request_timeout")
    }

    private func write(_ message: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: message)
        guard payload.count <= 1_000_000 else { throw ScheduledMessageDeliveryError(code: "desktop_frame_limit") }
        var length = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(payload)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ScheduledMessageDeliveryError(code: "desktop_connection_failed") }
                sent += count
            }
        }
    }

    private func read(deadline: Date) throws -> [String: Any] {
        let header = try readBytes(4, deadline: deadline)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << UInt32(8 * $1.offset)) }
        try Self.validateReceiveFrameLength(length)
        guard let message = try JSONSerialization.jsonObject(with: readBytes(Int(length), deadline: deadline)) as? [String: Any] else {
            throw ScheduledMessageDeliveryError(code: "desktop_protocol_invalid")
        }
        return message
    }

    private func readBytes(_ count: Int, deadline: Date) throws -> Data {
        var data = Data()
        while data.count < count {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard Date() < deadline else { throw ScheduledMessageDeliveryError(code: "desktop_request_timeout") }
            let status = Darwin.poll(&poller, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1_000)))
            if status < 0, errno == EINTR { continue }
            guard status > 0 else { throw ScheduledMessageDeliveryError(code: "desktop_request_timeout") }
            var bytes = [UInt8](repeating: 0, count: min(count - data.count, 65_536))
            let size = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if size < 0, errno == EINTR { continue }
            guard size > 0 else { throw ScheduledMessageDeliveryError(code: "desktop_connection_failed") }
            data.append(contentsOf: bytes.prefix(size))
        }
        return data
    }
}
