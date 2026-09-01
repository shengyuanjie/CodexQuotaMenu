import Foundation

struct CodexAutomation: Equatable, Sendable {
    let id: String
    let version: Int
    let kind: String
    let name: String
    let prompt: String?
    let status: String
    let rrule: String
    let model: String?
    let reasoningEffort: String?
    let notificationPolicy: String?
    let executionEnvironment: String?
    let targetType: String?
}

enum AutomationReadResult: Equatable, Sendable {
    case available([CodexAutomation])
    case unavailable(String)
}

struct CodexAutomationReader {
    let rootURL: URL
    let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/automations", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func readManagedAutomations() -> AutomationReadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return .available([])
        }
        guard isDirectory.boolValue,
              let children = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return .unavailable("automation directory is unreadable")
        }

        var tasks: [CodexAutomation] = []
        for child in children.sorted(by: { $0.path < $1.path }) {
            let file = child.appendingPathComponent("automation.toml")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else {
                return .unavailable("an automation file is unreadable")
            }
            guard source.contains(ManagedAutomationPolicy.namePrefix) else { continue }
            guard let parsed = Self.parse(source), parsed.version == 1 else {
                return .unavailable("managed automation has an unsupported format")
            }
            tasks.append(parsed)
        }

        return .available(tasks.sorted { $0.name < $1.name })
    }

    private static func parse(_ source: String) -> CodexAutomation? {
        let fields = StringFieldMap(source: source)
        guard let version = fields.integer("version"),
              let id = fields.string("id"),
              let kind = fields.string("kind"),
              let name = fields.string("name"),
              let status = fields.string("status"),
              let rrule = fields.string("rrule") else {
            return nil
        }

        return CodexAutomation(
            id: id,
            version: version,
            kind: kind,
            name: name,
            prompt: fields.string("prompt"),
            status: status,
            rrule: rrule,
            model: fields.string("model"),
            reasoningEffort: fields.string("reasoningEffort"),
            notificationPolicy: fields.string("notificationPolicy"),
            executionEnvironment: fields.string("executionEnvironment"),
            targetType: fields.inlineTableString("target", key: "type")
        )
    }
}

private struct StringFieldMap {
    private var integers: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var inlineTables: [String: String] = [:]

    init(source: String) {
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if let integer = Int(value) {
                integers[key] = integer
            } else if let string = Self.unquoted(value) {
                strings[key] = string
            } else if value.first == "{", value.last == "}" {
                inlineTables[key] = String(value)
            }
        }
    }

    func integer(_ key: String) -> Int? {
        integers[key]
    }

    func string(_ key: String) -> String? {
        strings[key]
    }

    func inlineTableString(_ table: String, key: String) -> String? {
        guard let source = inlineTables[table] else { return nil }
        let body = source.dropFirst().dropLast()
        for component in body.split(separator: ",", omittingEmptySubsequences: false) {
            guard let separator = component.firstIndex(of: "=") else { continue }
            let field = component[..<separator].trimmingCharacters(in: .whitespaces)
            guard field == key else { continue }
            let value = component[component.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return Self.unquoted(value)
        }
        return nil
    }

    private static func unquoted(_ value: String) -> String? {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return nil }
        let content = value.dropFirst().dropLast()
        var result = ""
        var isEscaping = false

        for character in content {
            if isEscaping {
                guard character == "\"" || character == "\\" else { return nil }
                result.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "\"" {
                return nil
            } else {
                result.append(character)
            }
        }

        return isEscaping ? nil : result
    }
}
