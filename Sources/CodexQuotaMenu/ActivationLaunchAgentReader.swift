import Foundation

enum ActivationLaunchAgentReadResult: Equatable, Sendable {
    case available([ActivationLaunchAgent])
    case unavailable(String)
}

struct ActivationLaunchAgentReader {
    let policy: ActivationLaunchAgentPolicy
    let directoryURL: URL
    let fileManager: FileManager

    init(
        policy: ActivationLaunchAgentPolicy,
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.policy = policy
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func read() -> ActivationLaunchAgentReadResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return .available([])
        }
        guard isDirectory.boolValue,
              let files = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return .unavailable("LaunchAgents directory is unreadable")
        }

        var agents: [ActivationLaunchAgent] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let time = policy.time(forFileName: file.lastPathComponent) else { continue }
            guard isRegularFile(file) else {
                return .unavailable("owned LaunchAgent is not a regular file")
            }
            guard let data = try? Data(contentsOf: file) else {
                return .unavailable("owned LaunchAgent is unreadable")
            }
            guard hasNoDuplicateXMLKeys(data) else {
                return .unavailable("owned LaunchAgent has ambiguous plist keys")
            }
            guard let agent = validatedAgent(from: data, namedFor: time) else {
                return .unavailable("owned LaunchAgent does not match policy")
            }
            agents.append(agent)
        }

        return .available(agents)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return true
    }

    private func validatedAgent(from data: Data, namedFor time: ActivationTime) -> ActivationLaunchAgent? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        Set(plist.keys) == [
            "Label",
            "ProgramArguments",
            "StartCalendarInterval",
            "WorkingDirectory",
            "StandardOutPath",
            "StandardErrorPath"
        ] else {
            return nil
        }

        let expected = policy.agent(for: time)
        guard plist["Label"] as? String == expected.label,
              plist["ProgramArguments"] as? [String] == expected.programArguments,
              plist["WorkingDirectory"] as? String == expected.workingDirectory,
              plist["StandardOutPath"] as? String == expected.standardOutPath,
              plist["StandardErrorPath"] as? String == expected.standardErrorPath,
              let calendar = plist["StartCalendarInterval"] as? [String: Any],
              Set(calendar.keys) == ["Hour", "Minute"],
              strictInteger(calendar["Hour"]) == expected.hour,
              strictInteger(calendar["Minute"]) == expected.minute,
              policy.time(forLabel: expected.label) == time else {
            return nil
        }

        return expected
    }

    private func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.intValue
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }

    private func hasNoDuplicateXMLKeys(_ data: Data) -> Bool {
        let detector = PlistDuplicateKeyDetector()
        let parser = XMLParser(data: data)
        parser.delegate = detector
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !detector.hasDuplicateKey
    }
}

private final class PlistDuplicateKeyDetector: NSObject, XMLParserDelegate {
    private var dictionaryKeys: [Set<String>] = []
    private var keyText = ""
    private var isReadingKey = false
    private(set) var hasDuplicateKey = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "dict" {
            dictionaryKeys.append([])
        } else if elementName == "key" {
            guard !dictionaryKeys.isEmpty, !isReadingKey else {
                hasDuplicateKey = true
                return
            }
            isReadingKey = true
            keyText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingKey {
            keyText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "key" {
            guard isReadingKey, !dictionaryKeys.isEmpty else {
                hasDuplicateKey = true
                return
            }
            if !dictionaryKeys[dictionaryKeys.count - 1].insert(keyText).inserted {
                hasDuplicateKey = true
            }
            isReadingKey = false
        } else if elementName == "dict" {
            guard !dictionaryKeys.isEmpty else {
                hasDuplicateKey = true
                return
            }
            dictionaryKeys.removeLast()
        }
    }
}
