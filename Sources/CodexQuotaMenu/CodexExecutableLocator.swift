import Foundation

protocol CodexExecutableLocating {
    func findExecutable() throws -> URL
}

struct CodexExecutableLocator: CodexExecutableLocating {
    let candidatePaths: [String]
    let isExecutable: (String) -> Bool

    init(
        candidatePaths: [String],
        isExecutable: @escaping (String) -> Bool
    ) {
        self.candidatePaths = candidatePaths
        self.isExecutable = isExecutable
    }

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        bundledCandidatePaths: [String]? = nil
    ) {
        let home = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        let defaults = bundledCandidatePaths ?? [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        candidatePaths = [environment["CODEX_CLI_PATH"]].compactMap { $0 } + defaults
        isExecutable = fileManager.isExecutableFile(atPath:)
    }

    func findExecutable() throws -> URL {
        guard let path = candidatePaths.first(where: isExecutable) else {
            throw UsageError.codexNotFound
        }
        return URL(fileURLWithPath: path)
    }
}
