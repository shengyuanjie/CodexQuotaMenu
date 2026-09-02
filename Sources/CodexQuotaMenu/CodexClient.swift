import Foundation
import Darwin

final class CodexClient {
    private let timeout: TimeInterval = 20
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var outputBuffer = Data()
    private var nextRequestID = 2

    deinit { stop() }

    func fetchUsage() throws -> UsageSnapshot {
        do {
            return try fetchFromPersistentSession()
        } catch {
            stop()
            throw error
        }
    }

    func fetchTasks() throws -> TaskSnapshot {
        do {
            try ensureStarted()
            guard let input, let output else {
                throw UsageError.taskConnectionUnavailable
            }
            let requestID = nextRequestID
            nextRequestID += 1
            try send([
                "id": requestID,
                "method": "thread/list",
                "params": [
                    "limit": 50,
                    "sortKey": "updated_at",
                    "sortDirection": "desc",
                    "useStateDbOnly": true
                ]
            ], to: input.fileHandleForWriting)
            let response = try waitForResponse(
                id: requestID,
                from: output.fileHandleForReading,
                buffer: &outputBuffer
            )
            return try TaskParser.parse(response)
        } catch {
            stop()
            throw error
        }
    }

    private func fetchFromPersistentSession() throws -> UsageSnapshot {
        try ensureStarted()
        guard let input, let output else {
            throw UsageError.usageConnectionUnavailable
        }

        let requestID = nextRequestID
        nextRequestID += 1
        try send(["id": requestID, "method": "account/rateLimits/read"], to: input.fileHandleForWriting)
        let response = try waitForResponse(
            id: requestID,
            from: output.fileHandleForReading,
            buffer: &outputBuffer
        )
        return try UsageParser.parse(response)
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }

        stop()
        let executable = try findCodexExecutable()
        let newProcess = Process()
        let newInput = Pipe()
        let newOutput = Pipe()
        newProcess.executableURL = URL(fileURLWithPath: executable)
        newProcess.arguments = ["app-server", "--stdio"]
        newProcess.standardInput = newInput
        newProcess.standardOutput = newOutput
        newProcess.standardError = FileHandle.nullDevice
        do { try newProcess.run() } catch {
            throw UsageError.cannotStartCodex(error.localizedDescription)
        }

        process = newProcess
        input = newInput
        output = newOutput
        outputBuffer.removeAll(keepingCapacity: true)
        nextRequestID = 2

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "codex-quota-menubar", "title": "Codex Usage", "version": "1.6.6"],
                "capabilities": ["experimentalApi": true]
            ]
        ], to: newInput.fileHandleForWriting)
        _ = try waitForResponse(id: 1, from: newOutput.fileHandleForReading, buffer: &outputBuffer)
        try send(["method": "initialized"], to: newInput.fileHandleForWriting)
    }

    private func stop() {
        try? input?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func waitForResponse(id: Int, from handle: FileHandle, buffer: inout Data) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["id"] as? Int == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw UsageError.serverError(error["message"] as? String)
                }
                return Data(line)
            }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult == 0 { throw UsageError.timedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw UsageError.readFailed(String(cString: strerror(errno)))
            }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 { throw UsageError.connectionClosed }
            if count < 0 {
                if errno == EINTR { continue }
                throw UsageError.readFailed(String(cString: strerror(errno)))
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw UsageError.timedOut
    }

    private func findCodexExecutable() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            environment["CODEX_CLI_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw UsageError.codexNotFound
    }
}
