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

    func testMissingTopLevelNameMakesVerificationUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource("prompt = \"CodexQuotaMenu · 06:00\"", root: root, id: "missing-name")

        guard case .unavailable =
                CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected unavailable")
        }
    }

    func testUnparseableTopLevelNameMakesVerificationUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource("name = \"unterminated", root: root, id: "bad-name")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected unavailable")
        }
    }

    func testTruncatedManagedAutomationMakesVerificationUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource("name = \"CodexQuotaMenu · 06:00\"", root: root, id: "truncated")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected unavailable")
        }
    }

    func testDuplicateRecognizedTopLevelNameOrModelIsUnavailable() throws {
        for (suffix, duplicate) in [
            ("name", "name = \"Personal reminder\""),
            ("model", "model = \"gpt-5.6-sol\"")
        ] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try writeSource(
                automationSource(id: suffix, name: "CodexQuotaMenu · 06:00", version: 1)
                    + "\n" + duplicate,
                root: root,
                id: suffix
            )

            guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
                return XCTFail("expected duplicate \(suffix) to be unavailable")
            }
        }
    }

    func testUnknownTableCannotShadowRecognizedTopLevelModel() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "shadow", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[metadata]\nmodel = \"gpt-5.6-sol\"",
            root: root,
            id: "shadow"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected table-scoped recognized key to be unavailable")
        }
    }

    func testMalformedSourceWithReliableManagedNameIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "malformed", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nthis is not valid TOML",
            root: root,
            id: "malformed"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected malformed source to be unavailable")
        }
    }

    func testUnknownFieldsAndUnambiguousUnknownTableAreTolerated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "unknown", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureFlag = true\n[metadata]\nnote = \"kept separate\"",
            root: root,
            id: "unknown"
        )

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected structurally unambiguous unknown fields to be tolerated")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
    }

    func testMalformedPrefixedNamesAreObservedForDiagnostics() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAutomation(root, id: "backup", name: "CodexQuotaMenu · backup", version: 1)
        try writeAutomation(root, id: "copy", name: "CodexQuotaMenu · 06:00 copy", version: 1)

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected diagnostic names to remain observable")
        }
        XCTAssertEqual(
            tasks.map(\.name),
            ["CodexQuotaMenu · 06:00 copy", "CodexQuotaMenu · backup"]
        )
    }

    func testPersonalNameWithManagedPrefixInPromptIsIgnored() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = automationFile(root, "personal")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            name = "Personal reminder"
            prompt = "CodexQuotaMenu · 06:00"
            # CodexQuotaMenu · 11:02
            """.utf8
        ).write(to: file)

        XCTAssertEqual(CodexAutomationReader(rootURL: root).readManagedAutomations(), .available([]))
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
        try writeSource(automationSource(id: id, name: name, version: version), root: root, id: id)
    }

    private func writeSource(_ source: String, root: URL, id: String) throws {
        let file = automationFile(root, id)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: file)
    }

    private func automationSource(id: String, name: String, version: Int) -> String {
        """
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
    }
}
