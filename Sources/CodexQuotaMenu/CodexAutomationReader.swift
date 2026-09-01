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
            guard let fields = try? StringFieldMap(source: source),
                  let name = fields.string("name") else {
                return .unavailable("an automation file has an ambiguous format")
            }
            guard ManagedAutomationPolicy.managedTime(from: name) != nil
                    || ManagedAutomationPolicy.isMalformedPrefixedName(name) else {
                continue
            }
            guard let parsed = Self.parse(fields), parsed.version == 1 else {
                return .unavailable("managed automation has an unsupported format")
            }
            tasks.append(parsed)
        }

        return .available(tasks.sorted { $0.name < $1.name })
    }

    private static func parse(_ fields: StringFieldMap) -> CodexAutomation? {
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
    private static let recognizedKeys: Set<String> = [
        "version",
        "id",
        "kind",
        "name",
        "prompt",
        "status",
        "rrule",
        "model",
        "reasoningEffort",
        "notificationPolicy",
        "executionEnvironment",
        "target"
    ]

    private var integers: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var inlineTables: [String: String] = [:]

    init(source: String) throws {
        var recognizedTopLevelKeys = Set<String>()
        var isInsideTable = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let uncommented = Self.removingComment(from: String(rawLine)) else {
                throw StringFieldMapError.malformed
            }
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                guard Self.isSupportedTableHeader(line) else {
                    throw StringFieldMapError.malformed
                }
                isInsideTable = true
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw StringFieldMapError.malformed
            }
            let key = String(line[..<separator].trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            guard Self.isBareKey(key), !value.isEmpty, Self.hasBalancedDelimiters(value) else {
                throw StringFieldMapError.malformed
            }

            let isRecognized = Self.recognizedKeys.contains(key)
            if isInsideTable {
                guard !isRecognized else {
                    throw StringFieldMapError.ambiguousRecognizedKey
                }
                continue
            }
            guard isRecognized else { continue }
            guard recognizedTopLevelKeys.insert(key).inserted else {
                throw StringFieldMapError.duplicateRecognizedKey
            }

            if key == "version", let integer = Int(value) {
                integers[key] = integer
            } else if key == "target", value.first == "{", value.last == "}" {
                inlineTables[key] = value
            } else if key != "version", key != "target", let string = Self.unquoted(value) {
                strings[key] = string
            } else {
                throw StringFieldMapError.malformed
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
        var match: String?
        for component in body.split(separator: ",", omittingEmptySubsequences: false) {
            guard let separator = component.firstIndex(of: "=") else { continue }
            let field = component[..<separator].trimmingCharacters(in: .whitespaces)
            guard field == key else { continue }
            let value = component[component.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard match == nil, let parsed = Self.unquoted(value) else { return nil }
            match = parsed
        }
        return match
    }

    private static func removingComment(from line: String) -> String? {
        var result = ""
        var isInsideString = false
        var isEscaping = false

        for character in line {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\", isInsideString {
                result.append(character)
                isEscaping = true
            } else if character == "\"" {
                result.append(character)
                isInsideString.toggle()
            } else if character == "#", !isInsideString {
                break
            } else {
                result.append(character)
            }
        }
        return isInsideString || isEscaping ? nil : result
    }

    private static func isSupportedTableHeader(_ line: String) -> Bool {
        if line.hasPrefix("[[") {
            guard line.hasSuffix("]]"), line.count > 4 else { return false }
            let name = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && !name.contains("[") && !name.contains("]")
        }
        guard line.hasSuffix("]"), line.count > 2 else { return false }
        let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !name.contains("[") && !name.contains("]")
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    private static func hasBalancedDelimiters(_ value: String) -> Bool {
        var isInsideString = false
        var isEscaping = false
        var braceDepth = 0
        var bracketDepth = 0

        for character in value {
            if isEscaping {
                isEscaping = false
            } else if character == "\\", isInsideString {
                isEscaping = true
            } else if character == "\"" {
                isInsideString.toggle()
            } else if !isInsideString {
                switch character {
                case "{": braceDepth += 1
                case "}": braceDepth -= 1
                case "[": bracketDepth += 1
                case "]": bracketDepth -= 1
                default: break
                }
                if braceDepth < 0 || bracketDepth < 0 { return false }
            }
        }
        return !isInsideString && !isEscaping && braceDepth == 0 && bracketDepth == 0
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

private enum StringFieldMapError: Error {
    case malformed
    case duplicateRecognizedKey
    case ambiguousRecognizedKey
}
