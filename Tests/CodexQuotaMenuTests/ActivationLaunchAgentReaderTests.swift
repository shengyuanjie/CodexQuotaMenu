import Foundation
import XCTest
@testable import CodexQuotaMenu

final class ActivationLaunchAgentReaderTests: XCTestCase {
    private var directory: URL!
    private var policy: ActivationLaunchAgentPolicy!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivationLaunchAgentReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        policy = ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testReadsOnlyRegularExactOwnedPlists() throws {
        let sixThirty = try ActivationTime(hour: 6, minute: 30)
        try writeCanonical(sixThirty)
        try Data("personal plist".utf8).write(to: directory.appendingPathComponent("personal.plist"))

        let result = ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read()

        XCTAssertEqual(result, .available([policy.agent(for: sixThirty)]))
    }

    func testMissingDirectoryIsAvailableAndEmpty() {
        let missing = directory.appendingPathComponent("missing", isDirectory: true)

        XCTAssertEqual(
            ActivationLaunchAgentReader(policy: policy, directoryURL: missing).read(),
            .available([])
        )
    }

    func testAcceptsCanonicalOwnedAgentWithStaleAbsoluteCodexPathForReconciliation() throws {
        let sixThirty = try ActivationTime(hour: 6, minute: 30)
        let stalePolicy = ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/Applications/Codex A.app/Contents/Resources/codex"),
            homeDirectory: policy.homeDirectory
        )
        try stalePolicy.agent(for: sixThirty).xmlData().write(
            to: directory.appendingPathComponent(policy.fileName(for: sixThirty))
        )

        let result = ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read()

        guard case .available(let agents) = result else {
            return XCTFail("a stale absolute Codex path must remain safely reconcilable")
        }
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(
            agents.first?.programArguments.first,
            "/Applications/Codex A.app/Contents/Resources/codex"
        )
    }

    func testRejectsInvalidOwnedLabelAndMismatchedFilename() throws {
        let sixThirty = try ActivationTime(hour: 6, minute: 30)
        let sevenFifteen = try ActivationTime(hour: 7, minute: 15)
        try writeCanonical(sevenFifteen, named: policy.fileName(for: sixThirty))

        assertUnavailable(ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read())
    }

    func testRejectsPathEscapeSymlinkForOwnedFile() throws {
        let sixThirty = try ActivationTime(hour: 6, minute: 30)
        let escaped = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivationLaunchAgentReaderTests-escaped-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: escaped) }
        try policy.agent(for: sixThirty).xmlData().write(to: escaped)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(policy.fileName(for: sixThirty)),
            withDestinationURL: escaped
        )

        assertUnavailable(ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read())
    }

    func testRejectsDuplicateRequiredPlistKeys() throws {
        let time = try ActivationTime(hour: 6, minute: 30)
        var xml = String(decoding: try policy.agent(for: time).xmlData(), as: UTF8.self)
        xml = xml.replacingOccurrences(
            of: "<key>Label</key>",
            with: "<key>Label</key><string>\(policy.label(for: time))</string><key>Label</key>",
            options: [],
            range: xml.range(of: "<key>Label</key>")
        )
        try Data(xml.utf8).write(to: directory.appendingPathComponent(policy.fileName(for: time)))

        assertUnavailable(ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read())
    }

    func testRejectsRunAtLoadUnexpectedProgramArgumentsAndOutputPaths() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("run-at-load", { $0["RunAtLoad"] = true }),
            ("arguments", { $0["ProgramArguments"] = ["/bin/sh", "-c", "echo unexpected"] }),
            ("arbitrary executable", {
                var arguments = $0["ProgramArguments"] as! [String]
                arguments[0] = "/bin/sh"
                $0["ProgramArguments"] = arguments
            }),
            ("relative executable", {
                var arguments = $0["ProgramArguments"] as! [String]
                arguments[0] = "codex"
                $0["ProgramArguments"] = arguments
            }),
            ("non-exec command", {
                var arguments = $0["ProgramArguments"] as! [String]
                arguments[1] = "login"
                $0["ProgramArguments"] = arguments
            }),
            ("unsafe sandbox", {
                var arguments = $0["ProgramArguments"] as! [String]
                arguments[arguments.firstIndex(of: "read-only")!] = "danger-full-access"
                $0["ProgramArguments"] = arguments
            }),
            ("pseudo-owned label", {
                $0["Label"] = "com.local.codexquotamenu.activation.0630.backup"
            }),
            ("stdout", { $0["StandardOutPath"] = "/tmp/output" }),
            ("stderr", { $0["StandardErrorPath"] = "/tmp/error" })
        ]

        for (name, mutate) in cases {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let time = try ActivationTime(hour: 6, minute: 30)
            var plist = try canonicalDictionary(for: time)
            mutate(&plist)
            try write(plist, named: policy.fileName(for: time))

            assertUnavailable(
                ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read(),
                file: #filePath,
                line: #line,
                name: name
            )
        }
    }

    func testRejectsCalendarWithInvalidTimeOrAdditionalKeys() throws {
        let time = try ActivationTime(hour: 6, minute: 30)
        for calendar: [String: Any] in [
            ["Hour": 24, "Minute": 30],
            ["Hour": 6, "Minute": 60],
            ["Hour": 6, "Minute": 30, "Weekday": 1]
        ] {
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var plist = try canonicalDictionary(for: time)
            plist["StartCalendarInterval"] = calendar
            try write(plist, named: policy.fileName(for: time))

            assertUnavailable(ActivationLaunchAgentReader(policy: policy, directoryURL: directory).read())
        }
    }

    private func writeCanonical(_ time: ActivationTime, named name: String? = nil) throws {
        try policy.agent(for: time).xmlData().write(
            to: directory.appendingPathComponent(name ?? policy.fileName(for: time))
        )
    }

    private func canonicalDictionary(for time: ActivationTime) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(
            from: policy.agent(for: time).xmlData(),
            options: [],
            format: nil
        ) as! [String: Any]
    }

    private func write(_ plist: [String: Any], named name: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func assertUnavailable(
        _ result: ActivationLaunchAgentReadResult,
        file: StaticString = #filePath,
        line: UInt = #line,
        name: String = ""
    ) {
        guard case .unavailable = result else {
            return XCTFail("expected unavailable \(name)", file: file, line: line)
        }
    }
}
