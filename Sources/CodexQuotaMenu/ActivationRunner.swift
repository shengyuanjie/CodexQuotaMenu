import Foundation

enum ActivationRunner {
    static func commandArguments(policy: ActivationLaunchAgentPolicy, time: ActivationTime,
                                 snapshot: DefaultModelSnapshot) throws -> [String] {
        let selection = snapshot.effective
        try selection.validate()
        guard snapshot.models.contains(where: {
            $0.id == selection.model && $0.efforts.contains(selection.effort)
                && (!selection.fastEnabled || $0.supportsFast)
        }) else { throw DefaultModelError.invalidSelection }
        var arguments = Array(policy.agent(for: time).programArguments.dropFirst())
        // Keep activation isolated from user hooks/tools while adopting current model defaults.
        arguments.insert(contentsOf: ["--json", "--model", selection.model,
            "-c", "model_reasoning_effort=\"\(selection.effort)\"",
            "-c", "service_tier=\"\(selection.serviceTier)\""], at: 1)
        return arguments
    }

    static func commandError(_ result: CodexCommandResult) -> String? {
        if result.timedOut { return "timeout" }
        let events = result.standardOutput.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failed = events.contains { ["turn.failed", "error"].contains($0["type"] as? String ?? "") }
        let completed = events.contains {
            $0["type"] as? String == "turn.completed" &&
            (($0["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0) > 0
        }
        if result.terminationStatus == 0 && completed && !failed { return nil }
        let error = (result.standardError + result.standardOutput).lowercased()
        if error.contains("401") || error.contains("unauthorized") { return "authentication" }
        if error.contains("429") || error.contains("rate limit") || error.contains("usage limit") { return "rate_limit" }
        if result.terminationStatus != 0 || failed { return "command_failed" }
        return "turn_not_completed"
    }

    static func verifiedOutcome(before: RateLimitWindow?, after: RateLimitWindow?, confirmation: RateLimitWindow?, started: Date, now: Date, commandError: String?) -> String {
        if commandError != nil { return "request_failed" }
        guard let after, let end = after.resetsAt, let confirmation,
              confirmation.resetsAt == end, end > now,
              after.durationMinutes == 300, confirmation.durationMinutes == 300 else {
            return "verification_unavailable"
        }
        // Zero-percent windows can expose a moving now + five hours placeholder.
        // A future deadline alone is never proof of activation.
        guard after.usedPercent > 0 || confirmation.usedPercent > 0 else { return "request_completed_unverified" }
        guard let before, let previousEnd = before.resetsAt else { return "active_without_baseline" }
        if previousEnd <= started || (before.usedPercent == 0 && end.timeIntervalSince(previousEnd) > 60) {
            return "window_activated"
        }
        return "window_already_active"
    }

    static func expiryDelay(_ window: RateLimitWindow?, now: Date) -> TimeInterval? {
        guard let window, window.durationMinutes == 300, window.usedPercent > 0,
              let end = window.resetsAt, end > now else { return nil }
        let delay = end.timeIntervalSince(now) + 5
        return delay <= 600 ? delay : nil
    }

    static func run(arguments: [String]) -> Int32 {
        guard arguments.count > 3, arguments[0] == "--activate" else { return 64 }
        let label = arguments[1]
        let configuredExecutable = URL(fileURLWithPath: arguments[2])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let policy = ActivationLaunchAgentPolicy(codexURL: configuredExecutable, homeDirectory: home, runnerURL: nil)
        guard let time = policy.time(forLabel: label),
              (Array(arguments.dropFirst(2)) == policy.agent(for: time).programArguments ||
               Array(arguments.dropFirst(2)) == policy.legacyProgramArguments(for: time)) else { return 64 }
        let started = Date()
        // Resolve at execution time, rather than trusting a path embedded by an older app.
        let locator = CodexExecutableLocator()
        var record: [String: Any] = ["schema": 2, "label": label, "startedAt": started.timeIntervalSince1970]
        var attempts: [[String: Any]] = []
        var status = "verification_unavailable"
        let directory = home.appendingPathComponent("Library/Logs/CodexQuotaMenu/Activation", isDirectory: true)
        let destination = directory.appendingPathComponent(label + ".json")
        let history = directory.appendingPathComponent("\(label).\(Int(started.timeIntervalSince1970))-\(UUID().uuidString).json")
        func persist() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            record["attempts"] = attempts
            record["status"] = status
            record["updatedAt"] = Date().timeIntervalSince1970
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            for url in [destination, history] {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        do { try persist() } catch { return 74 }
        let executable: URL
        do { executable = try locator.findExecutable() } catch {
            status = "cli_unavailable"
            try? persist()
            return 69
        }
        record["cliPathChanged"] = executable.path != configuredExecutable.path
        func readWindow() -> RateLimitWindow? {
            let resolved = CodexExecutableLocator(candidatePaths: [executable.path], isExecutable: FileManager.default.isExecutableFile(atPath:))
            guard let window = try? CodexClient(executableLocator: resolved).fetchUsage().shortWindow,
                  window.durationMinutes == 300 else { return nil }
            return window
        }
        func snapshot(_ window: RateLimitWindow?) -> Any {
            guard let window else { return NSNull() }
            return ["usedPercent": window.usedPercent,
                    "resetsAt": window.resetsAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()] as [String: Any]
        }
        var before = readWindow()
        record["before"] = snapshot(before)
        if let delay = expiryDelay(before, now: Date()) {
            status = "waiting_for_expiry"
            record["deferredSeconds"] = delay
            do { try persist() } catch { return 74 }
            Thread.sleep(forTimeInterval: delay)
            before = readWindow()
            record["beforeAfterWait"] = snapshot(before)
        } else if let before, before.usedPercent > 0, let end = before.resetsAt, end > Date() {
            status = "window_already_active"
            record["nextEligibleAt"] = end.timeIntervalSince1970
            do { try persist() } catch { return 74 }
            return 0
        }
        let commandArguments: [String]
        do {
            let resolved = CodexExecutableLocator(candidatePaths: [executable.path], isExecutable: FileManager.default.isExecutableFile(atPath:))
            let snapshot = try DefaultModelSettingsService(makeClient: { CodexClient(executableLocator: resolved) }).load()
            commandArguments = try self.commandArguments(policy: policy, time: time, snapshot: snapshot)
        } catch {
            status = "default_model_unavailable"
            try? persist()
            return 78
        }
        for index in 0..<2 {
            if index > 0 { Thread.sleep(forTimeInterval: 15) }
            let attemptStarted = Date()
            var attempt: [String: Any] = ["startedAt": attemptStarted.timeIntervalSince1970]
            var failure: String? = "launch_failed"
            do {
                let result = try CodexProcessRunner().run(executableURL: executable,
                    arguments: commandArguments, timeout: 90)
                attempt["exitCode"] = result.terminationStatus
                attempt["timedOut"] = result.timedOut
                failure = commandError(result)
            } catch { failure = "launch_failed" }
            attempt["errorCategory"] = failure ?? "none"
            let after = readWindow()
            var confirmation: RateLimitWindow?
            if failure == nil {
                Thread.sleep(forTimeInterval: 10)
                confirmation = readWindow()
            }
            status = verifiedOutcome(before: before, after: after, confirmation: confirmation,
                                     started: attemptStarted, now: Date(), commandError: failure)
            attempt["after"] = snapshot(after)
            attempt["confirmation"] = snapshot(confirmation)
            attempt["status"] = status
            attempts.append(attempt)
            do { try persist() } catch { return 74 }
            if status == "window_activated" || status == "window_already_active" { return 0 }
            if failure == "authentication" || failure == "rate_limit" { break }
            before = confirmation ?? after
        }
        return 1
    }
}
