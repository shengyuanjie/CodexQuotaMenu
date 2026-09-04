import Foundation

struct ActivationLaunchAgentPolicy {
    static let labelPrefix = "com.local.codexquotamenu.activation."
    static let fileExtension = "plist"

    let codexURL: URL
    let homeDirectory: URL

    init(codexURL: URL, homeDirectory: URL) {
        self.codexURL = codexURL
        self.homeDirectory = homeDirectory
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
            programArguments: [
                codexURL.path,
                "exec",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--model",
                "gpt-5.6-luna",
                "--cd",
                homeDirectory.path,
                ManagedAutomationPolicy.activationPrompt
            ],
            workingDirectory: homeDirectory.path,
            standardOutPath: "/dev/null",
            standardErrorPath: "/dev/null"
        )
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
