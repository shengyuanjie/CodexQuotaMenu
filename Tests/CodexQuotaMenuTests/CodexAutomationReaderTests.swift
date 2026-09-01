import XCTest
@testable import CodexQuotaMenu

final class CodexAutomationReaderTests: XCTestCase {
    func testReadsOnlyManagedVersionOneTasks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAutomation(root, id: "managed", name: "CodexQuotaMenu · 06:00", version: 1)
        try writeAutomation(root, id: "other", name: "Personal reminder", version: 1)

        guard case .available(let tasks) =
                CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected available")
        }

        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
        XCTAssertEqual(
            tasks.first,
            CodexAutomation(
                id: "managed",
                version: 1,
                kind: "heartbeat",
                name: "CodexQuotaMenu · 06:00",
                prompt: "Activate \"now\"",
                status: "ACTIVE",
                rrule: "FREQ=DAILY;BYHOUR=6;BYMINUTE=0",
                model: "gpt-5.6-luna",
                reasoningEffort: "low",
                notificationPolicy: "failed_runs_only",
                executionEnvironment: "local",
                targetType: "projectless"
            )
        )
    }

    func testMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertEqual(CodexAutomationReader(rootURL: missing).readManagedAutomations(), .available([]))
    }

    func testUnknownManagedVersionIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAutomation(root, id: "future", name: "CodexQuotaMenu · 06:00", version: 2)

        guard case .unavailable =
                CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected unavailable")
        }
    }

    func testMalformedUnmanagedFileIsIgnoredButMalformedManagedFileBlocksVerification() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unmanaged = automationFile(root, "other")
        try FileManager.default.createDirectory(
            at: unmanaged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not toml".utf8).write(to: unmanaged)

        XCTAssertEqual(CodexAutomationReader(rootURL: root).readManagedAutomations(), .available([]))

        let managed = automationFile(root, "managed")
        try FileManager.default.createDirectory(
            at: managed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("name = \"CodexQuotaMenu · 06:00\"".utf8).write(to: managed)
        guard case .unavailable =
                CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected unavailable")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAutomationReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func automationFile(_ root: URL, _ id: String) -> URL {
        root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("automation.toml")
    }

    private func writeAutomation(_ root: URL, id: String, name: String, version: Int) throws {
        let file = automationFile(root, id)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = """
        id = \"\(id)\"
        version = \(version)
        kind = \"heartbeat\"
        name = \"\(name)\"
        prompt = \"Activate \\\"now\\\"\"
        status = \"ACTIVE\"
        rrule = \"FREQ=DAILY;BYHOUR=6;BYMINUTE=0\"
        model = \"gpt-5.6-luna\"
        reasoningEffort = \"low\"
        notificationPolicy = \"failed_runs_only\"
        executionEnvironment = \"local\"
        target = { type = \"projectless\" }
        unknown = \"ignored\"
        """
        try Data(source.utf8).write(to: file)
    }
}
