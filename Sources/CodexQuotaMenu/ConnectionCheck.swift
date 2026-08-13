import Darwin
import Foundation

enum ConnectionCheck {
    static func successMessage(
        usage: UsageSnapshot,
        tasks: TaskSnapshot,
        text: AppText
    ) -> String {
        let separator = text.language == .simplifiedChinese ? "，" : ", "
        let summary = usage.windows
            .map { text.remainingUsage(window: $0) }
            .joined(separator: separator)
        return text.connectionSuccess(summary: summary, running: tasks.running.count)
    }

    static func run(
        client: CodexClient = CodexClient(),
        text: AppText = .current
    ) -> Never {
        do {
            let usage = try client.fetchUsage()
            let tasks = try client.fetchTasks()
            let message = successMessage(usage: usage, tasks: tasks, text: text)
            FileHandle.standardOutput.write(Data("\(message)\n".utf8))
            exit(EXIT_SUCCESS)
        } catch {
            let message = text.connectionFailure(text.errorDescription(error))
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
