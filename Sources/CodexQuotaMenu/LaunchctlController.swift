import Darwin
import Foundation

struct LaunchctlCommandResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
    let standardOutputWasTruncated: Bool

    init(
        terminationStatus: Int32,
        standardOutput: String = "",
        standardError: String,
        standardOutputWasTruncated: Bool = false
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputWasTruncated = standardOutputWasTruncated
    }
}

protocol LaunchctlCommandRunning {
    func run(arguments: [String]) throws -> LaunchctlCommandResult
}

enum LaunchctlControllerError: Error, Equatable, Sendable {
    case cannotStart(String)
    case commandFailed(command: String, terminationStatus: Int32, diagnostic: String)
    case ambiguousInventory
}

struct LaunchctlProcessRunner: LaunchctlCommandRunning {
    static let maximumStandardErrorBytes = 4_096
    static let maximumStandardOutputBytes = 1_048_576

    func run(arguments: [String]) throws -> LaunchctlCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = BoundedDataCollector(limit: Self.maximumStandardOutputBytes)
        let errorCollector = BoundedDataCollector(limit: Self.maximumStandardErrorBytes)
        startCollecting(standardOutput, into: outputCollector)
        startCollecting(standardError, into: errorCollector)

        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw LaunchctlControllerError.cannotStart(error.localizedDescription)
        }
        process.waitUntilExit()
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
        drainRemainingStandardOutput(
            from: standardOutput.fileHandleForReading,
            into: outputCollector
        )
        drainRemainingStandardError(
            from: standardError.fileHandleForReading,
            into: errorCollector
        )

        return LaunchctlCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: outputCollector.string,
            standardError: errorCollector.string,
            standardOutputWasTruncated: outputCollector.wasTruncated
        )
    }

    private func startCollecting(_ pipe: Pipe, into collector: BoundedDataCollector) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }
    }

    private func drainRemainingStandardOutput(
        from handle: FileHandle,
        into collector: BoundedDataCollector
    ) {
        drainRemainingData(from: handle, into: collector)
    }

    private func drainRemainingStandardError(
        from handle: FileHandle,
        into collector: BoundedDataCollector
    ) {
        drainRemainingData(from: handle, into: collector)
    }

    private func drainRemainingData(from handle: FileHandle, into collector: BoundedDataCollector) {
        while let data = try? handle.read(upToCount: 1_024), !data.isEmpty {
            collector.append(data)
        }
    }
}

protocol LaunchctlControlling {
    func bootstrap(plistURL: URL) throws
    func isLoaded(label: String) throws -> Bool
    func loadedOwnedLabels() throws -> Set<String>
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

    func loadedOwnedLabels() throws -> Set<String> {
        let result = try runner.run(arguments: ["print", domain])
        guard result.terminationStatus == 0 else {
            throw LaunchctlControllerError.commandFailed(
                command: "print",
                terminationStatus: result.terminationStatus,
                diagnostic: result.standardError
            )
        }
        guard !result.standardOutputWasTruncated else {
            throw LaunchctlControllerError.ambiguousInventory
        }
        return try ownedLabels(in: result.standardOutput)
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

    private func ownedLabels(in output: String) throws -> Set<String> {
        let serviceLines = try activeServiceLines(in: output)
        let prefix = NSRegularExpression.escapedPattern(for: ActivationLaunchAgentPolicy.labelPrefix)
        let labelPattern = "\(prefix)(?:[01][0-9]|2[0-3])[0-5][0-9]"
        // A signal-terminated service can have a negative status (for example -9).
        let servicePrefix = "(?:(?:0x[0-9A-Fa-f]+|[0-9]+)\\s*=\\s*|[0-9]+\\s+\\([A-Za-z]+\\)\\s+|[0-9]+\\s+-\\s+|[0-9]+\\s+-?[0-9]+\\s+)?"
        let rowPattern = "^\(servicePrefix)([^\\s{}]+)$"
        let ownedLabelPattern = "^\(labelPattern)$"
        guard let expression = try? NSRegularExpression(pattern: rowPattern),
              let ownedLabelExpression = try? NSRegularExpression(pattern: ownedLabelPattern) else {
            throw LaunchctlControllerError.ambiguousInventory
        }
        var labels: [String] = []
        for line in serviceLines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let labelRange = Range(match.range(at: 1), in: line) else {
                throw LaunchctlControllerError.ambiguousInventory
            }
            let label = String(line[labelRange])
            if ownedLabelExpression.firstMatch(
                in: label,
                range: NSRange(label.startIndex..., in: label)
            ) != nil {
                labels.append(label)
            }
        }
        guard Set(labels).count == labels.count else {
            throw LaunchctlControllerError.ambiguousInventory
        }
        return Set(labels)
    }

    private func activeServiceLines(in output: String) throws -> [String] {
        var foundInventory = false
        var closedInventory = false
        var lines: [String] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !foundInventory {
                switch line {
                case "services = {":
                    foundInventory = true
                case "services = {}":
                    foundInventory = true
                    closedInventory = true
                default:
                    continue
                }
                continue
            }

            if closedInventory {
                guard line != "services = {", line != "services = {}" else {
                    throw LaunchctlControllerError.ambiguousInventory
                }
                continue
            }

            if line == "}" {
                closedInventory = true
            } else if line.contains("{") || line.contains("}") {
                throw LaunchctlControllerError.ambiguousInventory
            } else {
                lines.append(line)
            }
        }

        guard foundInventory, closedInventory else {
            throw LaunchctlControllerError.ambiguousInventory
        }
        return lines
    }
}

private final class BoundedDataCollector {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ incoming: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else {
            truncated = true
            return
        }
        if incoming.count > remaining {
            truncated = true
        }
        data.append(incoming.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}
