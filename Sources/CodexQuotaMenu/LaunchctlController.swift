import Darwin
import Foundation

struct LaunchctlCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardError: String
}

protocol LaunchctlCommandRunning {
    func run(arguments: [String]) throws -> LaunchctlCommandResult
}

enum LaunchctlControllerError: Error, Equatable, Sendable {
    case cannotStart(String)
    case commandFailed(command: String, terminationStatus: Int32, diagnostic: String)
}

struct LaunchctlProcessRunner: LaunchctlCommandRunning {
    static let maximumStandardErrorBytes = 4_096

    func run(arguments: [String]) throws -> LaunchctlCommandResult {
        let process = Process()
        let standardError = Pipe()
        let collector = BoundedStandardErrorCollector(limit: Self.maximumStandardErrorBytes)

        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }

        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            standardError.fileHandleForReading.readabilityHandler = nil
            throw LaunchctlControllerError.cannotStart(error.localizedDescription)
        }
        process.waitUntilExit()
        standardError.fileHandleForReading.readabilityHandler = nil
        drainRemainingStandardError(
            from: standardError.fileHandleForReading,
            into: collector
        )

        return LaunchctlCommandResult(
            terminationStatus: process.terminationStatus,
            standardError: collector.string
        )
    }

    private func drainRemainingStandardError(
        from handle: FileHandle,
        into collector: BoundedStandardErrorCollector
    ) {
        while let data = try? handle.read(upToCount: 1_024), !data.isEmpty {
            collector.append(data)
        }
    }
}

protocol LaunchctlControlling {
    func bootstrap(plistURL: URL) throws
    func isLoaded(label: String) throws -> Bool
    func bootout(label: String) throws
}

struct LaunchctlController: LaunchctlControlling {
    private static let serviceNotFoundExitStatus: Int32 = 113

    let guiUserID: uid_t
    let runner: LaunchctlCommandRunning

    init(
        guiUserID: uid_t = getuid(),
        runner: LaunchctlCommandRunning = LaunchctlProcessRunner()
    ) {
        self.guiUserID = guiUserID
        self.runner = runner
    }

    func bootstrap(plistURL: URL) throws {
        try requireSuccess(
            arguments: ["bootstrap", domain, plistURL.path],
            command: "bootstrap"
        )
    }

    func isLoaded(label: String) throws -> Bool {
        let result = try runner.run(arguments: ["print", "\(domain)/\(label)"])
        switch result.terminationStatus {
        case 0:
            return true
        case Self.serviceNotFoundExitStatus:
            return false
        default:
            throw LaunchctlControllerError.commandFailed(
                command: "print",
                terminationStatus: result.terminationStatus,
                diagnostic: result.standardError
            )
        }
    }

    func bootout(label: String) throws {
        try requireSuccess(
            arguments: ["bootout", "\(domain)/\(label)"],
            command: "bootout"
        )
    }

    private var domain: String { "gui/\(guiUserID)" }

    private func requireSuccess(arguments: [String], command: String) throws {
        let result = try runner.run(arguments: arguments)
        guard result.terminationStatus == 0 else {
            throw LaunchctlControllerError.commandFailed(
                command: command,
                terminationStatus: result.terminationStatus,
                diagnostic: result.standardError
            )
        }
    }
}

private final class BoundedStandardErrorCollector {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ incoming: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { return }
        data.append(incoming.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
