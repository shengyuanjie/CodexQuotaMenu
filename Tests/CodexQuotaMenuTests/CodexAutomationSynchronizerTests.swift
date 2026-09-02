import XCTest
@testable import CodexQuotaMenu

final class CodexAutomationSynchronizerTests: XCTestCase {
    func testCreatesDesiredTasksWithoutChangingUnrelatedAutomation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root
            .appendingPathComponent("personal-reminder", isDirectory: true)
            .appendingPathComponent("automation.toml")
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unrelatedSource = "name = \"Personal reminder\"\n"
        try Data(unrelatedSource.utf8).write(to: unrelated)
        let entries = [
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30)),
            ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))
        ]

        try CodexAutomationSynchronizer(
            rootURL: root,
            timestampProvider: { 1_788_310_000_000 }
        ).synchronize(entries: entries, timeZoneIdentifier: "Asia/Shanghai")

        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), unrelatedSource)
        let readResult = CodexAutomationReader(rootURL: root).readManagedAutomations()
        XCTAssertEqual(
            AutomationReconciler.evaluate(
                entries: entries,
                readResult: readResult,
                timeZoneIdentifier: "Asia/Shanghai"
            ),
            .synced
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("codexquotamenu-06-30/automation.toml").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("codexquotamenu-11-33/automation.toml").path
        ))
    }

    func testReplacesManagedTaskSetAndDropsDisabledTimes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synchronizer = CodexAutomationSynchronizer(
            rootURL: root,
            timestampProvider: { 1_788_310_000_000 }
        )
        try synchronizer.synchronize(
            entries: [
                ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30)),
                ActivationScheduleEntry(time: try ActivationTime(hour: 7, minute: 45))
            ],
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let desired = [
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30)),
            ActivationScheduleEntry(time: try ActivationTime(hour: 7, minute: 45), isEnabled: false),
            ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))
        ]

        try synchronizer.synchronize(entries: desired, timeZoneIdentifier: "Asia/Shanghai")

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected readable automations")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:30", "CodexQuotaMenu · 11:33"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("codexquotamenu-07-45").path
        ))
    }

    func testRejectsCanonicalDirectoryCollisionWithoutChangingExistingTasks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synchronizer = CodexAutomationSynchronizer(rootURL: root)
        let originalEntries = [
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        ]
        try synchronizer.synchronize(entries: originalEntries, timeZoneIdentifier: "Asia/Shanghai")
        let originalFile = root.appendingPathComponent("codexquotamenu-06-30/automation.toml")
        let originalSource = try String(contentsOf: originalFile, encoding: .utf8)
        let collisionFile = root.appendingPathComponent("codexquotamenu-11-33/automation.toml")
        try FileManager.default.createDirectory(
            at: collisionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let unrelatedSource = "name = \"Personal reminder\"\n"
        try Data(unrelatedSource.utf8).write(to: collisionFile)

        XCTAssertThrowsError(try synchronizer.synchronize(
            entries: [
                originalEntries[0],
                ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))
            ],
            timeZoneIdentifier: "Asia/Shanghai"
        ))

        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), originalSource)
        XCTAssertEqual(try String(contentsOf: collisionFile, encoding: .utf8), unrelatedSource)
    }

    func testInvalidStagedConfigurationLeavesExistingTaskSetUntouched() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synchronizer = CodexAutomationSynchronizer(rootURL: root)
        let originalEntries = [
            ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        ]
        try synchronizer.synchronize(entries: originalEntries, timeZoneIdentifier: "Asia/Shanghai")
        let originalFile = root.appendingPathComponent("codexquotamenu-06-30/automation.toml")
        let originalSource = try String(contentsOf: originalFile, encoding: .utf8)

        XCTAssertThrowsError(try synchronizer.synchronize(
            entries: [ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))],
            timeZoneIdentifier: "Asia/Shanghai\""
        ))

        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), originalSource)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("codexquotamenu-11-33").path
        ))
    }

    func testEmptyDesiredListRemovesOnlyManagedTasks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synchronizer = CodexAutomationSynchronizer(rootURL: root)
        try synchronizer.synchronize(
            entries: [ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))],
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let unrelated = root.appendingPathComponent("personal/automation.toml")
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("name = \"Personal reminder\"\n".utf8).write(to: unrelated)

        try synchronizer.synchronize(entries: [], timeZoneIdentifier: "Asia/Shanghai")

        XCTAssertEqual(
            CodexAutomationReader(rootURL: root).readManagedAutomations(),
            .available([])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRejectsManagedTaskWhoseIDDoesNotMatchItsDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synchronizer = CodexAutomationSynchronizer(rootURL: root)
        let entry = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        try synchronizer.synchronize(entries: [entry], timeZoneIdentifier: "Asia/Shanghai")
        let canonical = root.appendingPathComponent("codexquotamenu-06-30", isDirectory: true)
        let mismatched = root.appendingPathComponent("misnamed-managed-task", isDirectory: true)
        try FileManager.default.moveItem(at: canonical, to: mismatched)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        let unrelatedFile = canonical.appendingPathComponent("automation.toml")
        let unrelatedSource = "name = \"Personal reminder\"\n"
        try Data(unrelatedSource.utf8).write(to: unrelatedFile)

        XCTAssertThrowsError(try synchronizer.synchronize(entries: [], timeZoneIdentifier: "Asia/Shanghai"))

        XCTAssertEqual(try String(contentsOf: unrelatedFile, encoding: .utf8), unrelatedSource)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mismatched.appendingPathComponent("automation.toml").path
        ))
    }

    func testConcurrentTargetCollisionIsNeverDeletedDuringRollback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = CodexAutomationSynchronizer(rootURL: root)
        let original = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        try initial.synchronize(entries: [original], timeZoneIdentifier: "Asia/Shanghai")
        let originalFile = root.appendingPathComponent("codexquotamenu-06-30/automation.toml")
        let originalSource = try String(contentsOf: originalFile, encoding: .utf8)
        let collisionFile = root.appendingPathComponent("codexquotamenu-11-33/automation.toml")
        let collisionSource = "name = \"Concurrent personal task\"\n"
        let synchronizer = CodexAutomationSynchronizer(
            rootURL: root,
            hooks: .init(beforeInstallingTask: { id in
                guard id == "codexquotamenu-11-33" else { return }
                try FileManager.default.createDirectory(
                    at: collisionFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(collisionSource.utf8).write(to: collisionFile)
            })
        )

        XCTAssertThrowsError(try synchronizer.synchronize(
            entries: [
                original,
                ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))
            ],
            timeZoneIdentifier: "Asia/Shanghai"
        ))

        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), originalSource)
        XCTAssertEqual(try String(contentsOf: collisionFile, encoding: .utf8), collisionSource)
    }

    func testFailedRollbackRetainsRecoveryCopyAndDoesNotDeleteCollision() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = CodexAutomationSynchronizer(rootURL: root)
        let original = ActivationScheduleEntry(time: try ActivationTime(hour: 6, minute: 30))
        try initial.synchronize(entries: [original], timeZoneIdentifier: "Asia/Shanghai")
        let originalFile = root.appendingPathComponent("codexquotamenu-06-30/automation.toml")
        let originalSource = try String(contentsOf: originalFile, encoding: .utf8)
        let collisionSource = "name = \"Concurrent replacement\"\n"
        let synchronizer = CodexAutomationSynchronizer(
            rootURL: root,
            hooks: .init(
                beforeInstallingTask: { _ in throw FixtureError.stopAfterRemoval },
                beforeRollback: {
                    try FileManager.default.createDirectory(
                        at: originalFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(collisionSource.utf8).write(to: originalFile)
                }
            )
        )

        XCTAssertThrowsError(try synchronizer.synchronize(
            entries: [ActivationScheduleEntry(time: try ActivationTime(hour: 11, minute: 33))],
            timeZoneIdentifier: "Asia/Shanghai"
        )) { error in
            guard case CodexAutomationSynchronizationError.recoveryRequired = error else {
                return XCTFail("expected recoveryRequired, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: originalFile, encoding: .utf8), collisionSource)
        let recoveryDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".codexquotamenu-recovery-") }
        let recovery = try XCTUnwrap(recoveryDirectories.first)
        XCTAssertEqual(
            try String(
                contentsOf: recovery.appendingPathComponent("codexquotamenu-06-30/automation.toml"),
                encoding: .utf8
            ),
            originalSource
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAutomationSynchronizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum FixtureError: Error {
    case stopAfterRemoval
}
