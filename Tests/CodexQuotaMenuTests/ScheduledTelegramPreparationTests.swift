import XCTest
@testable import CodexQuotaMenu

final class ScheduledTelegramPreparationTests: XCTestCase {
    func testOnlyEnabledNewChatsPrepareCredentialsInOrder() throws {
        var steps: [String] = []
        var preparation = ScheduledTelegramPreparation()
        preparation.settings = { .init(enabled: true, chatID: "123") }
        preparation.authorize = { steps.append("authorize") }
        preparation.verifyBackground = { steps.append("background") }
        try preparation.prepare(isNewTask: false)
        XCTAssertTrue(steps.isEmpty)
        preparation.settings = { .init(enabled: false) }
        try preparation.prepare(isNewTask: true)
        XCTAssertTrue(steps.isEmpty)
        preparation.settings = { .init(enabled: true, chatID: "123") }
        XCTAssertTrue(try preparation.saveThenPrepare(isNewTask: true,
            save: { steps.append("schedule") }, onSaved: { steps.append("show saved") }))
        XCTAssertEqual(steps, ["schedule", "show saved", "authorize", "background"])
    }

    func testCancellationAndInvalidConfigurationSkipProbe() {
        var preparation = ScheduledTelegramPreparation()
        preparation.settings = { .init(enabled: true, chatID: "123") }
        preparation.authorize = { throw ScheduledTelegramError(code: "credentials") }
        preparation.verifyBackground = { XCTFail("must not launch probe after cancellation") }
        XCTAssertThrowsError(try preparation.prepare(isNewTask: true))
        preparation.settings = { .init(enabled: true, chatID: "invalid") }
        preparation.authorize = { XCTFail("must validate configuration first") }
        XCTAssertThrowsError(try preparation.prepare(isNewTask: true))
    }

    func testBackgroundRejectionIsDetectedAfterForegroundAuthorization() {
        var preparation = ScheduledTelegramPreparation()
        preparation.settings = { .init(enabled: true, chatID: "123") }
        preparation.authorize = {}
        preparation.verifyBackground = { throw ScheduledTelegramError(code: "background_credentials") }
        XCTAssertThrowsError(try preparation.prepare(isNewTask: true)) { error in
            XCTAssertEqual((error as? ScheduledTelegramError)?.code, "background_credentials")
        }
    }

    func testAuthorizationFailureNeverRemovesSavedPlanOrLaunchAgent() throws {
        for failure in ["cancel", "background", "configuration"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ScheduledMessageStore(root: root.appendingPathComponent("records"))
            let controller = PreparationLaunchctl()
            let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root.appendingPathComponent("agents"), controller: controller)
            let item = ScheduledMessage(fireDate: Date().addingTimeInterval(3_600), threadID: "", threadTitle: "New",
                model: "test", message: "test", newTaskDirectory: root.path)
            var preparation = ScheduledTelegramPreparation()
            preparation.settings = { .init(enabled: true, chatID: failure == "configuration" ? "invalid" : "123") }
            var savedWasShown = false
            preparation.authorize = {
                XCTAssertTrue(savedWasShown)
                XCTAssertEqual(try store.read(item.id).state, .pending)
                XCTAssertFalse(controller.loaded.isEmpty)
                if failure == "cancel" { throw ScheduledTelegramError(code: "credentials") }
            }
            preparation.verifyBackground = { throw ScheduledTelegramError(code: "background_credentials") }
            XCTAssertFalse(try preparation.saveThenPrepare(isNewTask: true, save: {
                try scheduler.schedule(item)
            }, onSaved: { savedWasShown = true }))
            XCTAssertTrue(savedWasShown)
            XCTAssertEqual(try store.read(item.id).state, .pending)
            XCTAssertTrue(FileManager.default.fileExists(atPath: scheduler.plistURL(item.id).path))
            XCTAssertEqual(controller.loaded.count, 1)
            XCTAssertEqual(controller.bootouts, 0)
        }
    }

    func testFailedScheduleNeverStartsAuthorizationOrReportsSaved() {
        var preparation = ScheduledTelegramPreparation()
        preparation.settings = { XCTFail("authorization must not run"); return .init() }
        XCTAssertThrowsError(try preparation.saveThenPrepare(isNewTask: true,
            save: { throw ScheduledMessageError.commandFailed },
            onSaved: { XCTFail("must not report success") }))
    }

    func testInteractionPolicyIsRestoredOnSuccessAndFailure() throws {
        for initial in [true, false] {
            for fail in [true, false] {
                var state = initial
                var changes: [Bool] = []
                let outcome = Result {
                    try ScheduledTelegramBackgroundAccess.withRestoredPolicy(readState: { state }, setState: {
                        state = $0; changes.append($0)
                    }, body: {
                        XCTAssertFalse(state)
                        if fail { throw ScheduledTelegramError(code: "credentials") }
                        return "read"
                    })
                }
                XCTAssertEqual(state, initial)
                XCTAssertEqual(changes, [false, initial])
                if fail { XCTAssertThrowsError(try outcome.get()) }
                else { XCTAssertEqual(try outcome.get(), "read") }
            }
        }
    }

    func testFailedDisableStillRestoresPolicyAndDoesNotReadToken() {
        var changes: [Bool] = []
        XCTAssertThrowsError(try ScheduledTelegramBackgroundAccess.withRestoredPolicy(readState: { true }, setState: {
            changes.append($0)
            if !$0 { throw ScheduledTelegramError(code: "credentials") }
        }, body: { XCTFail("must not access token if UI policy cannot be set") }))
        XCTAssertEqual(changes, [false, true])
    }

    func testBackgroundReadIsRejectedInGUIOrTestProcessWithoutChangingPolicy() {
        XCTAssertThrowsError(try ScheduledTelegramBackgroundAccess.read { XCTFail("must not run"); return "secret" })
    }

    func testProbeUsesExactFlagAndReportsOnlyFixedErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("probe")
        for exit in [0, 1] {
            try "#!/bin/sh\nprintf '%s' \"$1\" > '\(root.path)/args'\nprintf '%s' 'private-token' >&2\nexit \(exit)\n".write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let result = Result { try ScheduledTelegramPreparation.probe(executable: fake, timeout: 2) }
            if exit == 0 { XCTAssertNoThrow(try result.get()) }
            else { XCTAssertThrowsError(try result.get()) { XCTAssertFalse($0.localizedDescription.contains("private-token")) } }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("args")), ScheduledTelegramPreparation.probeFlag)
        }
    }
}

private final class PreparationLaunchctl: LaunchctlControlling {
    var loaded = Set<String>()
    var bootouts = 0
    func bootstrap(plistURL: URL) throws { loaded.insert(plistURL.deletingPathExtension().lastPathComponent) }
    func isLoaded(label: String) throws -> Bool { loaded.contains(label) }
    func loadedOwnedLabels() throws -> Set<String> { loaded }
    func bootout(label: String) throws { bootouts += 1; loaded.remove(label) }
}
