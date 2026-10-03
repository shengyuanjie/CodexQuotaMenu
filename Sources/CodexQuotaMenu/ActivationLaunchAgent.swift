import Foundation

struct ActivationLaunchAgentPolicy {
    static let labelPrefix = "com.local.codexquotamenu.activation."
    static let fileExtension = "plist"

    let codexURL: URL
    let homeDirectory: URL
    let runnerURL: URL?

    init(codexURL: URL, homeDirectory: URL, runnerURL: URL? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.executableURL : nil) {
        self.codexURL = codexURL
        self.homeDirectory = homeDirectory
        self.runnerURL = runnerURL
    }

    func label(for time: ActivationTime) -> String {
        Self.labelPrefix + String(format: "%02d%02d", time.hour, time.minute)
    }

    func fileName(for time: ActivationTime) -> String {
        label(for: time) + "." + Self.fileExtension
    }

    func fileURL(for time: ActivationTime, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: time), isDirectory: false)
    }

    func time(forLabel label: String) -> ActivationTime? {
        guard label.hasPrefix(Self.labelPrefix) else { return nil }
        let suffix = label.dropFirst(Self.labelPrefix.count)
        guard suffix.utf8.count == 4,
              suffix.utf8.allSatisfy(Self.isASCIIDigit),
              let hour = Int(suffix.prefix(2)),
              let minute = Int(suffix.suffix(2)) else {
            return nil
        }
        return try? ActivationTime(hour: hour, minute: minute)
    }

    func time(forFileName fileName: String) -> ActivationTime? {
        let extensionSuffix = "." + Self.fileExtension
        guard fileName.hasSuffix(extensionSuffix) else { return nil }
        let label = String(fileName.dropLast(extensionSuffix.count))
        guard let time = time(forLabel: label), fileName == self.fileName(for: time) else {
            return nil
        }
        return time
    }

    func agent(for time: ActivationTime) -> ActivationLaunchAgent {
        ActivationLaunchAgent(
            time: time,
            label: label(for: time),
            programArguments: (runnerURL.map { [$0.path, "--activate", label(for: time)] } ?? []) + [
                codexURL.path,
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--cd",
                homeDirectory.path,
                ManagedAutomationPolicy.activationPrompt
            ],
            workingDirectory: homeDirectory.path,
            standardOutPath: "/dev/null",
            standardErrorPath: "/dev/null"
        )
    }

    // Recognize the exact previous command only for migration and old runner invocations.
    func legacyProgramArguments(for time: ActivationTime) -> [String] {
        var arguments = agent(for: time).programArguments
        let index = arguments.firstIndex(of: "--cd")!
        arguments.insert(contentsOf: ["--model", "gpt-5.6-luna"], at: index)
        return arguments
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}

struct ActivationLaunchAgent: Equatable, Sendable {
    let time: ActivationTime
    let label: String
    let programArguments: [String]
    let workingDirectory: String
    let standardOutPath: String
    let standardErrorPath: String
    let requiresSynchronization: Bool

    init(
        time: ActivationTime,
        label: String,
        programArguments: [String],
        workingDirectory: String,
        standardOutPath: String,
        standardErrorPath: String,
        requiresSynchronization: Bool = false
    ) {
        self.time = time
        self.label = label
        self.programArguments = programArguments
        self.workingDirectory = workingDirectory
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.requiresSynchronization = requiresSynchronization
    }

    var hour: Int { time.hour }
    var minute: Int { time.minute }

    func xmlData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label,
                "ProgramArguments": programArguments,
                "StartCalendarInterval": ["Hour": hour, "Minute": minute],
                "WorkingDirectory": workingDirectory,
                "StandardOutPath": standardOutPath,
                "StandardErrorPath": standardErrorPath
            ],
            format: .xml,
            options: 0
        )
    }
}
