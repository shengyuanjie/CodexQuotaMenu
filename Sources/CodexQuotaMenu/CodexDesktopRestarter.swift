import AppKit

@MainActor
protocol CodexDesktopApplication {
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: CodexDesktopApplication {}

@MainActor
struct CodexDesktopRestarter {
    // The desktop app can be named ChatGPT.app, but its Codex bundle identity is stable.
    static let bundleIdentifier = "com.openai.codex"
    var applications: () -> [any CodexDesktopApplication] = {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    }
    var installedURL: () -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    var open: (URL) async throws -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    var wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
    var attempts = 100

    func restart() async throws {
        let running = applications().filter { !$0.isTerminated }
        let urls = Set(running.compactMap(\.bundleURL))
        guard urls.count <= 1, running.allSatisfy({ $0.bundleURL != nil }),
              let url = urls.first ?? installedURL() else { throw RestartError.unavailable }
        for application in running {
            guard application.terminate() else { throw RestartError.quitRefused }
        }
        for _ in 0..<attempts {
            if running.allSatisfy(\.isTerminated) {
                try await open(url)
                return
            }
            try await wait()
        }
        // Never force-quit or launch a second instance while the original is still running.
        guard running.allSatisfy(\.isTerminated) else { throw RestartError.quitRefused }
        try await open(url)
    }

    enum RestartError: LocalizedError {
        case unavailable, quitRefused
        var errorDescription: String? {
            let t = AppText.current
            switch self {
            case .unavailable:
                return t.modelText("无法确定 Codex 应用位置，请稍后手动重启 Codex。", "Cannot locate the Codex desktop app. Please restart Codex manually later.")
            case .quitRefused:
                return t.modelText("Codex 未完成退出，可能有任务或退出确认等待处理。请处理后手动重启。", "Codex has not quit. A task or quit confirmation may need attention. Please restart manually after handling it.")
            }
        }
    }
}
