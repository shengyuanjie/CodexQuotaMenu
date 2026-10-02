import Foundation
import CryptoKit
import Darwin

/// Deliberately edits only the plain [models.new_thread] table. Unsupported TOML is refused.
enum ManagedModelConfig {
    static let filePath = "/etc/codex/requirements.toml"
    static let helperFlag = "--write-managed-default-model"

    private static func tableRange(_ lines: [String]) throws -> Range<Int> {
        let text = lines.joined(separator: "\n")
        guard !text.contains("\"\"\""), !text.contains("'''"), text.utf8.count < 1_048_576 else {
            throw DefaultModelError.unsupportedSystemFile
        }
        let headers = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        let starts = headers.filter {
            lines[$0].range(of: "^\\s*\\[models\\.new_thread\\]\\s*(#.*)?$", options: .regularExpression) != nil
        }
        guard starts.count == 1, let start = starts.first else { throw DefaultModelError.unsupportedSystemFile }
        return (start + 1)..<(headers.first(where: { $0 > start }) ?? lines.count)
    }

    private static func scalar(_ line: String, key: String) -> String? {
        let pattern = "^\\s*" + key + "\\s*=\\s*[\"']([A-Za-z0-9._-]+)[\"']\\s*(?:#.*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    static func values(in text: String) throws -> (model: String?, effort: String?, serviceTier: String?) {
        let lines = text.components(separatedBy: "\n")
        let range = try tableRange(lines)
        var values: [String: String] = [:]
        for index in range {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Unrecognized keys are preserved; non-plain assignments in this small table are refused.
            guard line.range(of: "^[A-Za-z_][A-Za-z0-9_]*\\s*=", options: .regularExpression) != nil else {
                throw DefaultModelError.unsupportedSystemFile
            }
            for key in ["model", "model_reasoning_effort", "service_tier"] {
                if line.range(of: "^" + key + "\\s*=", options: .regularExpression) != nil {
                    guard values[key] == nil, let value = scalar(line, key: key) else {
                        throw DefaultModelError.unsupportedSystemFile
                    }
                    values[key] = value
                }
            }
        }
        return (values["model"], values["model_reasoning_effort"], values["service_tier"])
    }

    static func replacing(_ text: String, with selection: DefaultModelSelection) throws -> String {
        try selection.validate()
        let existing = try values(in: text)
        var lines = text.components(separatedBy: "\n")
        let range = try tableRange(lines)
        var missing: [String] = []
        var edits = [("model", selection.model), ("model_reasoning_effort", selection.effort)]
        // Only update a system speed override when one already exists.
        if existing.serviceTier != nil { edits.append(("service_tier", selection.serviceTier)) }
        for (key, value) in edits {
            if let i = range.first(where: { scalar(lines[$0], key: key) != nil }) {
                // Keep indentation and trailing comments, replacing only the string token.
                let regex = try NSRegularExpression(pattern: "([\"'])[A-Za-z0-9._-]+[\"']")
                guard let m = regex.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])),
                      let r = Range(m.range, in: lines[i]) else { throw DefaultModelError.unsupportedSystemFile }
                lines[i].replaceSubrange(r, with: "\"\(value)\"")
            } else { missing.append("\(key) = \"\(value)\"") }
        }
        lines.insert(contentsOf: missing, at: range.lowerBound)
        return lines.joined(separator: "\n")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func authorizeAndWrite(_ original: String, _ selection: DefaultModelSelection) throws {
        try selection.validate()
        guard let executable = Bundle.main.executableURL else { throw DefaultModelError.administratorFailed }
        let command = [executable.path, helperFlag, selection.model, selection.effort, selection.serviceTier, digest(original)]
            .map(shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // The OS owns the password dialog. No password is read, stored, or passed by the app.
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw message.contains("-128") ? DefaultModelError.administratorCancelled : DefaultModelError.administratorFailed
        }
    }

    /// Root-only, fixed destination; no caller-controlled path or arbitrary configuration contents.
    static func runHelper(arguments: [String]) -> Int32 {
        guard geteuid() == 0, arguments.count == 6, arguments[1] == helperFlag else { return 1 }
        do {
            let selection = DefaultModelSelection(model: arguments[2], effort: arguments[3], serviceTier: arguments[4])
            try selection.validate()
            let fm = FileManager.default
            let parent = try fm.attributesOfItem(atPath: "/etc/codex")
            let attrs = try fm.attributesOfItem(atPath: filePath)
            guard parent[.type] as? FileAttributeType == .typeDirectory,
                  (parent[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  ((parent[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0,
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0 else { return 1 }
            let original = try String(contentsOfFile: filePath, encoding: .utf8)
            guard digest(original) == arguments[5] else { throw DefaultModelError.concurrentChange }
            let revised = try replacing(original, with: selection)
            if revised == original { return 0 }
            let backup = filePath + ".codexquotamenu-" + UUID().uuidString + ".bak"
            try Data(original.utf8).write(to: URL(fileURLWithPath: backup), options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
            guard try String(contentsOfFile: filePath, encoding: .utf8) == original else { throw DefaultModelError.concurrentChange }
            try Data(revised.utf8).write(to: URL(fileURLWithPath: filePath), options: .atomic)
            try fm.setAttributes([.posixPermissions: attrs[.posixPermissions] ?? 0o644,
                                  .ownerAccountID: attrs[.ownerAccountID] ?? 0,
                                  .groupOwnerAccountID: attrs[.groupOwnerAccountID] ?? 0], ofItemAtPath: filePath)
            guard try String(contentsOfFile: filePath, encoding: .utf8) == revised else { return 1 }
            return 0
        } catch { return 1 }
    }
}
