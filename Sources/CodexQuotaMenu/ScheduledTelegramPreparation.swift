import Foundation
import Security
import Darwin

// Legacy file-keychain ACL UI is controlled by a process-local Security.framework
// flag (Apple Security/SecKeychain.cpp, globals().setUserInteractionAllowed).
// Confine it to this CLI process's single read and restore its prior value on all
// paths. This does not write keychain ACLs, unlock settings or any OS preference.
enum ScheduledTelegramBackgroundAccess {
    private static let lock = NSLock()
    static func read<T>(_ body: () throws -> T) throws -> T {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == [ScheduledTelegramPreparation.probeFlag]
            || (args.count == 2 && args.first == "--send-scheduled-message" && UUID(uuidString: args[1]) != nil) else {
            throw ScheduledTelegramError(code: "credentials")
        }
        lock.lock(); defer { lock.unlock() }
        return try withRestoredPolicy(readState: {
            var prior: DarwinBoolean = true
            guard SecKeychainGetUserInteractionAllowed(&prior) == errSecSuccess else { throw ScheduledTelegramError(code: "credentials") }
            return prior.boolValue
        }, setState: { value in
            guard SecKeychainSetUserInteractionAllowed(value) == errSecSuccess else { throw ScheduledTelegramError(code: "credentials") }
        }, body: body)
    }

    static func withRestoredPolicy<T>(readState: () throws -> Bool, setState: (Bool) throws -> Void,
                                      body: () throws -> T) throws -> T {
        let prior = try readState()
        let result = Result { () throws -> T in
            try setState(false)
            return try body()
        }
        // Restore even when disabling interaction or the keychain read failed.
        try setState(prior)
        return try result.get()
    }
}

struct ScheduledTelegramPreparation {
    static let probeFlag = "--check-telegram-background-credentials"
    var settings: () -> ScheduledTelegramSettings = { ScheduledTelegramPreferences().load() }
    var authorize: () throws -> Void = { _ = try ScheduledTelegramKeychain().load(foreground: true) }
    var verifyBackground: () throws -> Void = { try probe() }

    // Save and expose the schedule first. Notification authorization is a separate
    // post-save step: its failure must never roll back the record or LaunchAgent.
    func saveThenPrepare(isNewTask: Bool, save: () throws -> Void, onSaved: () -> Void) throws -> Bool {
        try save()
        onSaved()
        do { try prepare(isNewTask: isNewTask); return true }
        catch { return false }
    }

    // Called by saveThenPrepare after the plan has been durably scheduled.
    func prepare(isNewTask: Bool) throws {
        guard isNewTask else { return }
        let configuration = settings()
        guard configuration.enabled else { return }
        try configuration.validate()
        try authorize()
        try verifyBackground()
    }

    static func probe(executable: URL? = Bundle.main.executableURL, timeout: TimeInterval = 15) throws {
        guard let executable else { throw ScheduledTelegramError(code: "background_credentials") }
        let process = Process()
        process.executableURL = executable
        process.arguments = [probeFlag]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ScheduledTelegramError(code: "background_credentials") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let stop = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ScheduledTelegramError(code: "background_credentials")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ScheduledTelegramError(code: "background_credentials")
        }
    }
}
