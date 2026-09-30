import Foundation
import XCTest
@testable import CodexQuotaMenu

final class LaunchctlControllerTests: XCTestCase {
    func testBuildsNonShellCommandsInTheCurrentUserDomain() throws {
        let plist = URL(fileURLWithPath: "/Users/tester/Library/LaunchAgents/example.plist")
        let label = "com.local.codexquotamenu.activation.0630"
        let runner = RecordingLaunchctlRunner(results: [
            .init(terminationStatus: 0, standardError: ""),
            .init(terminationStatus: 0, standardError: ""),
            .init(terminationStatus: 0, standardError: "")
        ])
        let controller = LaunchctlController(guiUserID: 501, runner: runner)

        try controller.bootstrap(plistURL: plist)
        XCTAssertTrue(try controller.isLoaded(label: label))
        try controller.bootout(label: label)

        XCTAssertEqual(runner.invocations, [
            ["bootstrap", "gui/501", plist.path],
            ["print", "gui/501/" + label],
            ["bootout", "gui/501/" + label]
        ])
    }

    func testPrintExit113MeansTheServiceIsUnloaded() throws {
        let runner = RecordingLaunchctlRunner(results: [
            .init(terminationStatus: 113, standardError: "Could not find service")
        ])
        let controller = LaunchctlController(guiUserID: 501, runner: runner)

        XCTAssertFalse(try controller.isLoaded(label: "com.local.codexquotamenu.activation.0630"))
    }

    func testUnexpectedPrintFailureIsNotMistakenForAnUnloadedService() {
        let runner = RecordingLaunchctlRunner(results: [
            .init(terminationStatus: 1, standardError: "localized failure")
        ])
        let controller = LaunchctlController(guiUserID: 501, runner: runner)

        XCTAssertThrowsError(
            try controller.isLoaded(label: "com.local.codexquotamenu.activation.0630")
        )
    }

    func testBootstrapAndBootoutSurfaceNonzeroExitStatuses() {
        let plist = URL(fileURLWithPath: "/Users/tester/Library/LaunchAgents/example.plist")
        let label = "com.local.codexquotamenu.activation.0630"
        let bootstrapRunner = RecordingLaunchctlRunner(results: [
            .init(terminationStatus: 1, standardError: "bootstrap failed")
        ])
        let bootoutRunner = RecordingLaunchctlRunner(results: [
            .init(terminationStatus: 1, standardError: "bootout failed")
        ])

        XCTAssertThrowsError(
            try LaunchctlController(guiUserID: 501, runner: bootstrapRunner).bootstrap(plistURL: plist)
        )
        XCTAssertThrowsError(
            try LaunchctlController(guiUserID: 501, runner: bootoutRunner).bootout(label: label)
        )
    }

    func testDomainInventoryFindsOnlyExactValidOwnedLabels() throws {
        let sixThirty = "com.local.codexquotamenu.activation.0630"
        let elevenTwo = "com.local.codexquotamenu.activation.1102"
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: """
                services = {
                    0x100 = \(sixThirty)
                    \(elevenTwo)
                    com.local.codexquotamenu.activation.2460
                    com.local.codexquotamenu.activation.0630-copy
                    prefixcom.local.codexquotamenu.activation.0630
                }
                disabled services = {
                    0x200 = com.local.codexquotamenu.activation.2359
                }
                """,
                standardError: ""
            )
        ])
        let controller = LaunchctlController(guiUserID: 501, runner: runner)

        XCTAssertEqual(try controller.loadedOwnedLabels(), [sixThirty, elevenTwo])
        XCTAssertEqual(runner.invocations, [["print", "gui/501"]])
    }

    func testRepeatedExactOwnedLabelMakesDomainInventoryUnavailable() {
        let label = "com.local.codexquotamenu.activation.0630"
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: "services = {\n\(label)\n\(label)\n}",
                standardError: ""
            )
        ])

        XCTAssertThrowsError(
            try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels()
        )
    }

    func testDisabledServicesInventoryDoesNotMakeAnAgentLoaded() throws {
        let disabledOnly = "com.local.codexquotamenu.activation.0630"
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: """
                services = {
                    0x100 = com.apple.unrelated
                }
                disabled services = {
                    0x200 = \(disabledOnly)
                }
                """,
                standardError: ""
            )
        ])

        XCTAssertEqual(
            try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels(),
            []
        )
    }

    func testDomainInventoryRecognizesMacOSActiveServiceRows() throws {
        let pending = "com.local.codexquotamenu.activation.0630"
        let inactive = "com.local.codexquotamenu.activation.1102"
        let running = "com.local.codexquotamenu.activation.1530"
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: """
                services = {
                    0   (pe)  \(pending)
                    0   -     \(inactive)
                    0   712   \(running)
                }
                disabled services = {
                    0   (pe)  com.local.codexquotamenu.activation.2359
                }
                """,
                standardError: ""
            )
        ])

        XCTAssertEqual(
            try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels(),
            [pending, inactive, running]
        )
    }

    func testUnknownActiveServiceRowMakesDomainInventoryUnavailable() {
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: """
                services = {
                    unexpected service row
                }
                """,
                standardError: ""
            )
        ])

        XCTAssertThrowsError(
            try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels()
        )
    }

    func testNegativeStatusesDoNotHideOwnedServices() throws {
        let label = "com.local.codexquotamenu.activation.0430"
        for row in ["0 -9 netdisk_service", "0 -15 \(label)", "123 -1 unrelated.service"] {
            let ownedRow = row.contains(label) ? "" : "0 - \(label)"
            let runner = RecordingLaunchctlRunner(results: [.init(
                terminationStatus: 0,
                standardOutput: "services = {\n\(row)\n\(ownedRow.isEmpty ? "" : ownedRow + "\n")}\n",
                standardError: ""
            )])
            XCTAssertEqual(try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels(), [label])
        }
    }

    func testMalformedNegativeStatusRemainsRejected() {
        for status in ["--9", "-9x"] {
            let runner = RecordingLaunchctlRunner(results: [.init(
                terminationStatus: 0, standardOutput: "services = {\n0 \(status) unrelated.service\n}", standardError: ""
            )])
            XCTAssertThrowsError(try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels())
        }
    }

    func testTruncatedDomainInventoryIsUnavailableRatherThanIncomplete() {
        let runner = RecordingLaunchctlRunner(results: [
            .init(
                terminationStatus: 0,
                standardOutput: "com.local.codexquotamenu.activation.0630",
                standardError: "",
                standardOutputWasTruncated: true
            )
        ])

        XCTAssertThrowsError(
            try LaunchctlController(guiUserID: 501, runner: runner).loadedOwnedLabels()
        )
    }
}

private final class RecordingLaunchctlRunner: LaunchctlCommandRunning {
    private var results: [LaunchctlCommandResult]
    private(set) var invocations: [[String]] = []

    init(results: [LaunchctlCommandResult]) {
        self.results = results
    }

    func run(arguments: [String]) throws -> LaunchctlCommandResult {
        invocations.append(arguments)
        return results.removeFirst()
    }
}
