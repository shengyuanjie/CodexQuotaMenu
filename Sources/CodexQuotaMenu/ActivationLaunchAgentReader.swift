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
              let programArguments = plist["ProgramArguments"] as? [String],
              acceptsArguments(programArguments, expected: expected, time: time),
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

        return ActivationLaunchAgent(
            time: time,
            label: expected.label,
            programArguments: programArguments,
            workingDirectory: expected.workingDirectory,
            standardOutPath: expected.standardOutPath,
            standardErrorPath: expected.standardErrorPath,
            requiresSynchronization: programArguments != expected.programArguments
        )
    }

    private func hasStableCommandPolicy(_ actual: [String], expected: [String]) -> Bool {
        guard actual.count == expected.count,
              actual.dropFirst() == expected.dropFirst(),
              let actualExecutable = actual.first,
              let expectedExecutable = expected.first else {
            return false
        }
        return isAbsoluteCodexExecutablePath(
            actualExecutable,
            expectedName: URL(fileURLWithPath: expectedExecutable).lastPathComponent
        )
    }

    private func acceptsArguments(_ actual: [String], expected: ActivationLaunchAgent, time: ActivationTime) -> Bool {
        if actual == expected.programArguments { return true }
        let direct = ActivationLaunchAgentPolicy(codexURL: policy.codexURL, homeDirectory: policy.homeDirectory, runnerURL: nil).agent(for: time).programArguments
        if hasStableCommandPolicy(actual, expected: direct) { return true }
        guard let runner = policy.runnerURL,
              Array(actual.prefix(3)) == [runner.path, "--activate", expected.label] else { return false }
        return hasStableCommandPolicy(Array(actual.dropFirst(3)), expected: direct)
    }

    private func isAbsoluteCodexExecutablePath(_ path: String, expectedName: String) -> Bool {
        guard NSString(string: path).isAbsolutePath,
              !path.contains("\0") else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path == path &&
            !expectedName.isEmpty &&
            url.lastPathComponent == expectedName
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
