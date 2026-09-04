import XCTest
@testable import CodexQuotaMenu

final class CodexExecutableLocatorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecutableLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    func testSelectsFirstExecutableCandidateInStableOrder() throws {
        let missing = temporaryDirectory.appendingPathComponent("missing")
        let executable = try makeFixture(named: "executable", executable: true)

        let selected = try CodexExecutableLocator(
            candidatePaths: [missing.path, executable.path],
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        ).findExecutable()

        XCTAssertEqual(selected, executable)
    }

    func testEnvironmentPathTakesPrecedenceOverBundledCandidates() throws {
        let environmentPath = try makeFixture(named: "environment", executable: true)
        let appPath = try makeFixture(named: "app", executable: true)
        let locator = CodexExecutableLocator(
            fileManager: .default,
            environment: ["CODEX_CLI_PATH": environmentPath.path],
            homeDirectory: temporaryDirectory,
            bundledCandidatePaths: [appPath.path]
        )

        XCTAssertEqual(try locator.findExecutable(), environmentPath)
    }

    func testRejectsNonExecutableCandidates() throws {
        let nonExecutable = try makeFixture(named: "non-executable", executable: false)
        let locator = CodexExecutableLocator(
            candidatePaths: [nonExecutable.path],
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )

        XCTAssertThrowsError(try locator.findExecutable()) { error in
            guard case .codexNotFound? = error as? UsageError else {
                return XCTFail("expected codexNotFound, got \(error)")
            }
        }
    }

    func testThrowsCodexNotFoundWhenNoCandidateIsExecutable() throws {
        let locator = CodexExecutableLocator(
            candidatePaths: [temporaryDirectory.appendingPathComponent("missing").path],
            isExecutable: { _ in false }
        )

        XCTAssertThrowsError(try locator.findExecutable()) { error in
            guard case .codexNotFound? = error as? UsageError else {
                return XCTFail("expected codexNotFound, got \(error)")
            }
        }
    }

    private func makeFixture(named name: String, executable: Bool) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }
}
