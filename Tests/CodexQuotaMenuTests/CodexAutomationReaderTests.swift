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

    func testDuplicateNameIsUnavailableEvenWhenPersonalNameComesFirst() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            "name = \"Personal reminder\"\nname = \"CodexQuotaMenu · 06:00\"",
            root: root,
            id: "personal-first"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected duplicate name ownership to be unavailable regardless of order")
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

    func testMalformedPrefixedNamesAreIgnoredWithoutManagedValidation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAutomation(root, id: "backup", name: "CodexQuotaMenu · backup", version: 2)
        try writeSource(
            "name = \"CodexQuotaMenu · 06:00 copy\"\nversion = 1",
            root: root,
            id: "copy"
        )

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected non-owned prefixed names to be ignored")
        }
        XCTAssertEqual(tasks, [])
    }

    func testMalformedPrefixedNameIgnoresInvalidNonOwnershipFields() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            """
            name = "CodexQuotaMenu · backup"
            model = "first"
            model = "duplicate"
            futureValue = definitely-not-valid-toml
            """,
            root: root,
            id: "broken-backup"
        )

        XCTAssertEqual(CodexAutomationReader(rootURL: root).readManagedAutomations(), .available([]))
    }

    func testScalarCannotBeRedefinedAsTable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "redefined", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[model]\nnote = \"invalid\"",
            root: root,
            id: "redefined"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected scalar-to-table redefinition to be unavailable")
        }
    }

    func testInvalidInlineTargetComponentIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = automationSource(id: "target", name: "CodexQuotaMenu · 06:00", version: 1)
            .replacingOccurrences(
                of: "target = { type = \"projectless\" }",
                with: "target = { type = \"projectless\", garbage = 1. }"
            )
        try writeSource(source, root: root, id: "target")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected malformed inline target to be unavailable")
        }
    }

    func testInlineTargetTrailingCommaIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = automationSource(id: "target-comma", name: "CodexQuotaMenu · 06:00", version: 1)
            .replacingOccurrences(
                of: "target = { type = \"projectless\" }",
                with: "target = { type = \"projectless\", }"
            )
        try writeSource(source, root: root, id: "target-comma")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected inline table trailing comma to be unavailable")
        }
    }

    func testMultilineInlineTargetIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = automationSource(id: "target-multiline", name: "CodexQuotaMenu · 06:00", version: 1)
            .replacingOccurrences(
                of: "target = { type = \"projectless\" }",
                with: "target = {\n  type = \"projectless\"\n}"
            )
        try writeSource(source, root: root, id: "target-multiline")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected TOML 1.0 multiline inline table to be unavailable")
        }
    }

    func testValidUnknownMultilineValueIsTolerated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "multiline", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureValues = [\n  \"one\",\n  \"two\",\n]",
            root: root,
            id: "multiline"
        )

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected valid unknown multiline value to be tolerated")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
    }

    func testInvalidUnknownValueIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "invalid-unknown", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureValue = definitely-not-valid-toml",
            root: root,
            id: "invalid-unknown"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected invalid unknown value to be unavailable")
        }
    }

    func testValidUnknownLiteralHexAndEscapedStringAreTolerated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "valid-unknowns", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureLiteral = 'value'\nfutureHex = 0x10\nfutureEscaped = \"line\\nnext\"",
            root: root,
            id: "valid-unknowns"
        )

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected valid unknown TOML scalar forms to be tolerated")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
    }

    func testLiteralStringMayContainCommentAndDelimiterCharacters() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "literal-content", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureLiteral = 'value#[],{}'",
            root: root,
            id: "literal-content"
        )

        guard case .available = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected literal string contents not to be parsed as TOML structure")
        }
    }

    func testNonASCIIBareKeyIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "unicode-key", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n未来 = \"invalid bare key\"",
            root: root,
            id: "unicode-key"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected non-ASCII bare key to be unavailable")
        }
    }

    func testLeadingZeroVersionIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = automationSource(id: "leading-zero", name: "CodexQuotaMenu · 06:00", version: 1)
            .replacingOccurrences(of: "version = 1", with: "version = 01")
        try writeSource(source, root: root, id: "leading-zero")

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected invalid leading-zero integer to be unavailable")
        }
    }

    func testInvalidUnknownDateIsUnavailable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "bad-date", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\nfutureDate = 2026-99-99",
            root: root,
            id: "bad-date"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected invalid date to be unavailable")
        }
    }

    func testTableScalarCannotBeRedefinedAsSubtable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "nested-redefined", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[metadata]\nnote = \"scalar\"\n[metadata.note]\nvalue = \"invalid\"",
            root: root,
            id: "nested-redefined"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected table scalar-to-subtable redefinition to be unavailable")
        }
    }

    func testTableCannotBeRedefinedAsArrayOfTables() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "table-aot", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[metadata]\nnote = \"first\"\n[[metadata]]",
            root: root,
            id: "table-aot"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected table-to-array-of-tables redefinition to be unavailable")
        }
    }

    func testNameProbeIgnoresNestedArrayOpeningLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        futureValues = [
          [1]
        ]
        \(automationSource(id: "nested-array", name: "CodexQuotaMenu · 06:00", version: 1))
        """
        try writeSource(source, root: root, id: "nested-array")

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected a top-level name after a nested array to remain discoverable")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
    }

    func testImplicitParentTableCannotBecomeArrayOfTables() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "implicit-parent", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[metadata.child]\nnote = \"value\"\n[[metadata]]",
            root: root,
            id: "implicit-parent"
        )

        guard case .unavailable = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected implicit parent table not to be redefined as an array of tables")
        }
    }

    func testRepeatedArrayOfTablesMayReuseFieldNames() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSource(
            automationSource(id: "repeated-aot", name: "CodexQuotaMenu · 06:00", version: 1)
                + "\n[[metadata]]\nnote = \"first\"\n[[metadata]]\nnote = \"second\"",
            root: root,
            id: "repeated-aot"
        )

        guard case .available(let tasks) = CodexAutomationReader(rootURL: root).readManagedAutomations() else {
            return XCTFail("expected repeated array-of-tables elements to have independent fields")
        }
        XCTAssertEqual(tasks.map(\.name), ["CodexQuotaMenu · 06:00"])
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
        reasoning_effort = \"low\"
        notification_policy = \"failed_runs_only\"
        execution_environment = \"local\"
        target = { type = \"projectless\" }
        unknown = \"ignored\"
        """
    }
}
