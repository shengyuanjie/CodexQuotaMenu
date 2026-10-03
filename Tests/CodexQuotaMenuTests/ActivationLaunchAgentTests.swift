import Foundation
import XCTest
@testable import CodexQuotaMenu

final class ActivationLaunchAgentTests: XCTestCase {
    func testPolicyBuildsExactOwnedLabelAndCanonicalCommand() throws {
        let codex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let sixThirty = try ActivationTime(hour: 6, minute: 30)
        let policy = ActivationLaunchAgentPolicy(codexURL: codex, homeDirectory: home)

        let agent = policy.agent(for: sixThirty)

        XCTAssertEqual(policy.label(for: sixThirty), "com.local.codexquotamenu.activation.0630")
        XCTAssertEqual(policy.fileName(for: sixThirty), "com.local.codexquotamenu.activation.0630.plist")
        XCTAssertEqual(agent.programArguments.prefix(4), [
            codex.path, "exec", "--ephemeral", "--ignore-user-config"
        ])
        XCTAssertEqual(agent.programArguments, [
            codex.path,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--cd",
            home.path,
            ManagedAutomationPolicy.activationPrompt
        ])
        XCTAssertTrue(agent.programArguments.contains("--ignore-rules"))
        XCTAssertEqual(agent.hour, 6)
        XCTAssertEqual(agent.minute, 30)
        XCTAssertEqual(agent.workingDirectory, home.path)
        XCTAssertEqual(agent.standardOutPath, "/dev/null")
        XCTAssertEqual(agent.standardErrorPath, "/dev/null")
    }

    func testPolicyRecognizesOnlyCompleteValidOwnedLabelsAndFileNames() throws {
        let policy = ActivationLaunchAgentPolicy(
            codexURL: URL(fileURLWithPath: "/usr/local/bin/codex"),
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertEqual(
            policy.time(forLabel: "com.local.codexquotamenu.activation.0630"),
            try ActivationTime(hour: 6, minute: 30)
        )
        XCTAssertEqual(
            policy.time(forFileName: "com.local.codexquotamenu.activation.2359.plist"),
            try ActivationTime(hour: 23, minute: 59)
        )

        [
            "com.local.codexquotamenu.activation.2400",
            "com.local.codexquotamenu.activation.2360",
            "com.local.codexquotamenu.activation.630",
            "com.local.codexquotamenu.activation.0630.copy",
            "com.local.codexquotamenu.activation.0630.plist",
            "com.local.codexquotamenu.activation.0630/../0715",
            "other.activation.0630"
        ].forEach { XCTAssertNil(policy.time(forLabel: $0), $0) }

        [
            "com.local.codexquotamenu.activation.2400.plist",
            "com.local.codexquotamenu.activation.2360.plist",
            "com.local.codexquotamenu.activation.0630.plist.bak",
            "com.local.codexquotamenu.activation.0630/../0715.plist",
            "com.local.codexquotamenu.activation.0630.plist/child",
            "other.activation.0630.plist"
        ].forEach { XCTAssertNil(policy.time(forFileName: $0), $0) }
    }

    func testCanonicalPlistRoundTripsAsExpectedDictionary() throws {
        let codex = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let time = try ActivationTime(hour: 6, minute: 30)
        let policy = ActivationLaunchAgentPolicy(codexURL: codex, homeDirectory: home)
        let agent = policy.agent(for: time)

        let object = try PropertyListSerialization.propertyList(
            from: try agent.xmlData(),
            options: [],
            format: nil
        ) as? [String: Any]

        XCTAssertEqual(object?["Label"] as? String, policy.label(for: time))
        XCTAssertEqual(object?["ProgramArguments"] as? [String], agent.programArguments)
        XCTAssertEqual(object?["StartCalendarInterval"] as? [String: Int], ["Hour": 6, "Minute": 30])
        XCTAssertEqual(object?["WorkingDirectory"] as? String, home.path)
        XCTAssertEqual(object?["StandardOutPath"] as? String, "/dev/null")
        XCTAssertEqual(object?["StandardErrorPath"] as? String, "/dev/null")
        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            Set([
                "Label", "ProgramArguments", "StartCalendarInterval", "WorkingDirectory", "StandardOutPath", "StandardErrorPath"
            ])
        )
    }
}
