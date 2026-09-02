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
            guard let name = StringFieldMap.topLevelName(in: source) else {
                return .unavailable("an automation file has an ambiguous format")
            }
            guard ManagedAutomationPolicy.managedTime(from: name) != nil else {
                continue
            }
            guard let fields = try? StringFieldMap(source: source),
                  fields.string("name") == name else {
                return .unavailable("an automation file has an ambiguous format")
            }
            guard let parsed = Self.parse(fields), parsed.version == 1 else {
                return .unavailable("managed automation has an unsupported format")
            }
            guard parsed.id == child.lastPathComponent else {
                return .unavailable("managed automation id does not match its directory")
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
            reasoningEffort: fields.string("reasoning_effort"),
            notificationPolicy: fields.string("notification_policy"),
            executionEnvironment: fields.string("execution_environment"),
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
        "reasoning_effort",
        "notification_policy",
        "execution_environment",
        "target"
    ]

    private var integers: [String: Int] = [:]
    private var strings: [String: String] = [:]
    private var inlineTables: [String: String] = [:]

    init(source: String) throws {
        var recognizedTopLevelKeys = Set<String>()
        var valuePaths = Set<String>()
        var tableKinds: [String: TableKind] = [:]
        var currentTablePath: String?
        var currentValueScope: String?
        var arrayElementSequence = 0
        let statements = try Self.statements(in: source)

        for statement in statements {
            if statement.hasPrefix("[") {
                guard let table = Self.tableHeader(statement) else {
                    throw StringFieldMapError.malformed
                }
                guard !Self.hasValuePrefix(of: table.path, in: valuePaths) else {
                    throw StringFieldMapError.malformed
                }
                let components = table.path.split(separator: ".")
                if components.count > 1 {
                    for parentIndex in 0..<(components.count - 1) {
                        let parent = components[...parentIndex].joined(separator: ".")
                        if tableKinds[parent] == .array {
                            throw StringFieldMapError.malformed
                        }
                        if tableKinds[parent] == nil {
                            tableKinds[parent] = .implicitStandard
                        }
                    }
                }
                let kind: TableKind = table.isArray ? .array : .standard
                if let existing = tableKinds[table.path] {
                    if kind == .standard, existing == .implicitStandard {
                        tableKinds[table.path] = .standard
                    } else {
                        guard existing == .array, kind == .array else {
                            throw StringFieldMapError.malformed
                        }
                    }
                } else {
                    tableKinds[table.path] = kind
                }
                currentTablePath = table.path
                if kind == .array {
                    arrayElementSequence += 1
                    currentValueScope = "\(table.path)#\(arrayElementSequence)"
                } else {
                    currentValueScope = table.path
                }
                continue
            }

            guard let separator = Self.topLevelSeparator(in: statement) else {
                throw StringFieldMapError.malformed
            }
            let key = String(statement[..<separator].trimmingCharacters(in: .whitespacesAndNewlines))
            let value = String(statement[statement.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines))
            guard Self.isBareKey(key), Self.isValidValue(value) else {
                throw StringFieldMapError.malformed
            }

            let isRecognized = Self.recognizedKeys.contains(key)
            if let currentTablePath, let currentValueScope {
                let logicalPath = currentTablePath + "." + key
                let scopedPath = currentValueScope + "." + key
                guard valuePaths.insert(scopedPath).inserted,
                      !Self.hasTableAtOrBelow(logicalPath, in: Set(tableKinds.keys)) else {
                    throw StringFieldMapError.malformed
                }
                guard !isRecognized else {
                    throw StringFieldMapError.ambiguousRecognizedKey
                }
                continue
            }
            guard valuePaths.insert(key).inserted,
                  !Self.hasTableAtOrBelow(key, in: Set(tableKinds.keys)) else {
                throw StringFieldMapError.malformed
            }
            guard isRecognized else { continue }
            guard recognizedTopLevelKeys.insert(key).inserted else {
                throw StringFieldMapError.duplicateRecognizedKey
            }

            if key == "version", Self.isDecimalInteger(value), let integer = Int(value) {
                integers[key] = integer
            } else if key == "target", Self.validInlineTable(value) != nil {
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
        guard let source = inlineTables[table],
              let fields = Self.validInlineTable(source),
              let value = fields[key] else { return nil }
        return Self.unquoted(value)
    }

    static func topLevelName(in source: String) -> String? {
        var isInsideTable = false
        var pending = ""
        var foundName: String?

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let uncommented = removingComment(from: String(rawLine)) else { return foundName }
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if pending.isEmpty {
                if tableHeader(line) != nil {
                    isInsideTable = true
                    continue
                }
                pending = line
            } else {
                pending += "\n" + line
            }

            guard let separator = topLevelSeparator(in: pending) else { return foundName }
            let value = String(pending[pending.index(after: separator)...])
            switch delimiterState(value) {
            case .incomplete:
                continue
            case .invalid:
                return foundName
            case .complete:
                break
            }

            let key = pending[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            if !isInsideTable, key == "name" {
                guard foundName == nil,
                      let parsed = unquoted(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                foundName = parsed
            }
            pending = ""
        }
        return foundName
    }

    private static func hasValuePrefix(of tablePath: String, in valuePaths: Set<String>) -> Bool {
        let components = tablePath.split(separator: ".")
        return components.indices.contains { index in
            valuePaths.contains(components[...index].joined(separator: "."))
        }
    }

    private static func hasTableAtOrBelow(_ valuePath: String, in tablePaths: Set<String>) -> Bool {
        tablePaths.contains { $0 == valuePath || $0.hasPrefix(valuePath + ".") }
    }

    private static func statements(in source: String) throws -> [String] {
        var result: [String] = []
        var pending = ""

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let uncommented = removingComment(from: String(rawLine)) else {
                throw StringFieldMapError.malformed
            }
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if pending.isEmpty {
                if line.hasPrefix("[") && tableHeader(line) != nil {
                    result.append(line)
                    continue
                }
                pending = line
            } else {
                pending += "\n" + line
            }

            guard let separator = topLevelSeparator(in: pending) else {
                if delimiterState(pending) == .invalid { throw StringFieldMapError.malformed }
                continue
            }
            let value = String(pending[pending.index(after: separator)...])
            switch delimiterState(value) {
            case .complete:
                result.append(pending)
                pending = ""
            case .incomplete:
                continue
            case .invalid:
                throw StringFieldMapError.malformed
            }
        }

        guard pending.isEmpty else { throw StringFieldMapError.malformed }
        return result
    }

    private static func topLevelSeparator(in statement: String) -> String.Index? {
        var quote: QuoteMode?
        var escaping = false
        for index in statement.indices {
            let character = statement[index]
            if escaping {
                escaping = false
            } else if character == "\\", quote == .basic {
                escaping = true
            } else if character == "\"", quote == .basic {
                quote = nil
            } else if character == "'", quote == .literal {
                quote = nil
            } else if character == "\"", quote == nil {
                quote = .basic
            } else if character == "'", quote == nil {
                quote = .literal
            } else if character == "=", quote == nil {
                return index
            }
        }
        return nil
    }

    private static func removingComment(from line: String) -> String? {
        var result = ""
        var quote: QuoteMode?
        var isEscaping = false

        for character in line {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\", quote == .basic {
                result.append(character)
                isEscaping = true
            } else if character == "\"", quote == .basic {
                result.append(character)
                quote = nil
            } else if character == "'", quote == .literal {
                result.append(character)
                quote = nil
            } else if character == "\"", quote == nil {
                result.append(character)
                quote = .basic
            } else if character == "'", quote == nil {
                result.append(character)
                quote = .literal
            } else if character == "#", quote == nil {
                break
            } else {
                result.append(character)
            }
        }
        return quote != nil || isEscaping ? nil : result
    }

    private static func tableHeader(_ line: String) -> (path: String, isArray: Bool)? {
        if line.hasPrefix("[[") {
            guard line.hasSuffix("]]"), line.count > 4 else { return nil }
            let name = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            guard isValidTablePath(name) else { return nil }
            return (name, true)
        }
        guard line.hasSuffix("]"), line.count > 2 else { return nil }
        let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard isValidTablePath(name) else { return nil }
        return (name, false)
    }

    private static func isValidTablePath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { isBareKey(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122) || byte == 95 || byte == 45
        }
    }

    private enum QuoteMode: Equatable {
        case basic
        case literal
    }

    private enum TableKind: Equatable {
        case standard
        case implicitStandard
        case array
    }

    private enum DelimiterState: Equatable {
        case complete
        case incomplete
        case invalid
    }

    private static func delimiterState(_ value: String) -> DelimiterState {
        var quote: QuoteMode?
        var isEscaping = false
        var braceDepth = 0
        var bracketDepth = 0

        for character in value {
            if isEscaping {
                isEscaping = false
            } else if character == "\\", quote == .basic {
                isEscaping = true
            } else if character == "\"", quote == .basic {
                quote = nil
            } else if character == "'", quote == .literal {
                quote = nil
            } else if character == "\"", quote == nil {
                quote = .basic
            } else if character == "'", quote == nil {
                quote = .literal
            } else if quote == nil {
                switch character {
                case "{": braceDepth += 1
                case "}": braceDepth -= 1
                case "[": bracketDepth += 1
                case "]": bracketDepth -= 1
                default: break
                }
                if braceDepth < 0 || bracketDepth < 0 { return .invalid }
            }
        }
        if isEscaping { return .invalid }
        return quote != nil || braceDepth > 0 || bracketDepth > 0 ? .incomplete : .complete
    }

    private static func isValidValue(_ value: String) -> Bool {
        guard !value.isEmpty, delimiterState(value) == .complete else { return false }
        if isValidBasicString(value) || isValidLiteralString(value) { return true }
        if value == "true" || value == "false" { return true }
        if isValidNumber(value) { return true }
        if value.first == "[", value.last == "]" {
            return validArray(value)
        }
        if value.first == "{", value.last == "}" {
            return validInlineTable(value) != nil
        }
        return isValidDateOrTime(value)
    }

    private static func isDecimalInteger(_ value: String) -> Bool {
        matches(value, #"^[+-]?(?:0|[1-9](?:_?[0-9])*)$"#)
    }

    private static func isValidNumber(_ value: String) -> Bool {
        if isDecimalInteger(value) { return true }
        if matches(value, #"^0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*$"#)
            || matches(value, #"^0o[0-7](?:_?[0-7])*$"#)
            || matches(value, #"^0b[01](?:_?[01])*$"#) {
            return true
        }
        return matches(
            value,
            #"^[+-]?(?:(?:0|[1-9](?:_?[0-9])*)\.[0-9](?:_?[0-9])*(?:[eE][+-]?[0-9](?:_?[0-9])*)?|(?:0|[1-9](?:_?[0-9])*)[eE][+-]?[0-9](?:_?[0-9])*|inf|nan)$"#
        )
    }

    private static func isValidBasicString(_ value: String) -> Bool {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return false }
        let content = value.dropFirst().dropLast()
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            guard character != "\n" && character != "\r" && character != "\"" else { return false }
            if character != "\\" {
                guard character.unicodeScalars.allSatisfy({ scalar in
                    scalar.value == 9 || (scalar.value >= 32 && scalar.value != 127)
                }) else { return false }
                index = content.index(after: index)
                continue
            }
            let escape = content.index(after: index)
            guard escape < content.endIndex else { return false }
            let marker = content[escape]
            if "btnfr\"\\".contains(marker) {
                index = content.index(after: escape)
                continue
            }
            let digits: Int
            if marker == "u" { digits = 4 }
            else if marker == "U" { digits = 8 }
            else { return false }
            var cursor = content.index(after: escape)
            let hexStart = cursor
            for _ in 0..<digits {
                guard cursor < content.endIndex, content[cursor].isHexDigit else { return false }
                cursor = content.index(after: cursor)
            }
            guard let scalarValue = UInt32(content[hexStart..<cursor], radix: 16),
                  Unicode.Scalar(scalarValue) != nil else { return false }
            index = cursor
        }
        return true
    }

    private static func isValidLiteralString(_ value: String) -> Bool {
        guard value.count >= 2, value.first == "'", value.last == "'" else { return false }
        let content = value.dropFirst().dropLast()
        return !content.contains("'") && content.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || (scalar.value >= 32 && scalar.value != 127)
        }
    }

    private static func isValidDateOrTime(_ value: String) -> Bool {
        let formats: [(String, String)] = [
            (#"^\d{4}-\d{2}-\d{2}$"#, "yyyy-MM-dd"),
            (#"^\d{2}:\d{2}:\d{2}$"#, "HH:mm:ss")
        ]
        for (pattern, format) in formats where matches(value, pattern) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter.date(from: value) != nil
        }
        guard value.contains("T") || value.contains("t") || value.contains(" ") else { return false }
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: normalized) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized) != nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func validArray(_ source: String) -> Bool {
        let body = String(source.dropFirst().dropLast())
        guard let components = commaSeparatedComponents(body) else { return false }
        return components.allSatisfy { !$0.isEmpty && isValidValue($0) }
    }

    private static func validInlineTable(_ source: String) -> [String: String]? {
        guard source.first == "{", source.last == "}" else { return nil }
        guard !source.contains("\n") && !source.contains("\r") else { return nil }
        let body = String(source.dropFirst().dropLast())
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",") else { return nil }
        guard let components = commaSeparatedComponents(body) else { return nil }
        var fields: [String: String] = [:]
        for component in components {
            guard !component.isEmpty,
                  let separator = topLevelSeparator(in: component) else { return nil }
            let key = String(component[..<separator].trimmingCharacters(in: .whitespacesAndNewlines))
            let value = String(component[component.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines))
            guard isBareKey(key), fields[key] == nil, isValidValue(value) else { return nil }
            fields[key] = value
        }
        return fields
    }

    private static func commaSeparatedComponents(_ source: String) -> [String]? {
        var result: [String] = []
        var start = source.startIndex
        var quote: QuoteMode?
        var escaping = false
        var braceDepth = 0
        var bracketDepth = 0

        for index in source.indices {
            let character = source[index]
            if escaping {
                escaping = false
            } else if character == "\\", quote == .basic {
                escaping = true
            } else if character == "\"", quote == .basic {
                quote = nil
            } else if character == "'", quote == .literal {
                quote = nil
            } else if character == "\"", quote == nil {
                quote = .basic
            } else if character == "'", quote == nil {
                quote = .literal
            } else if quote == nil {
                switch character {
                case "{": braceDepth += 1
                case "}": braceDepth -= 1
                case "[": bracketDepth += 1
                case "]": bracketDepth -= 1
                case "," where braceDepth == 0 && bracketDepth == 0:
                    result.append(String(source[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = source.index(after: index)
                default: break
                }
                if braceDepth < 0 || bracketDepth < 0 { return nil }
            }
        }
        guard quote == nil, !escaping, braceDepth == 0, bracketDepth == 0 else { return nil }
        let tail = String(source[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
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
