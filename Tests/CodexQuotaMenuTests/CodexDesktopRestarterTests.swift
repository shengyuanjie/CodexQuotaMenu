import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class CodexDesktopRestarterTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/Applications/Codex.app")

    func testWaitsForNormalExitBeforeOpeningSameApplication() async throws {
        let application = RestartApplicationStub(url: url)
        var waits = 0
        var opened: URL?
        var sut = CodexDesktopRestarter()
        sut.applications = { [application] }
        sut.open = { target in
            XCTAssertTrue(application.isTerminated)
            opened = target
        }
        sut.wait = {
            waits += 1
            application.isTerminated = true
        }
        try await sut.restart()
        XCTAssertEqual(application.quitRequests, 1)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(opened, url)
    }

    func testRefusedQuitDoesNotOpenAnotherInstance() async {
        let application = RestartApplicationStub(url: url)
        application.acceptsQuit = false
        var sut = CodexDesktopRestarter()
        sut.applications = { [application] }
        sut.open = { _ in XCTFail("Must not relaunch after a refused quit") }
        do { try await sut.restart(); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? CodexDesktopRestarter.RestartError, .quitRefused) }
    }

    func testQuitTimeoutDoesNotForceQuitOrRelaunch() async {
        let application = RestartApplicationStub(url: url)
        var sut = CodexDesktopRestarter()
        sut.applications = { [application] }
        sut.wait = {}
        sut.attempts = 2
        sut.open = { _ in XCTFail("Must not relaunch while still running") }
        do { try await sut.restart(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? CodexDesktopRestarter.RestartError, .quitRefused) }
        XCTAssertEqual(application.quitRequests, 1)
    }

    func testClosedAppOpensInstalledCodex() async throws {
        var opened: URL?
        var sut = CodexDesktopRestarter()
        sut.applications = { [] }
        sut.installedURL = { self.url }
        sut.open = { opened = $0 }
        try await sut.restart()
        XCTAssertEqual(opened, url)
    }

    func testMissingOrAmbiguousApplicationDoesNotQuitAnything() async {
        let first = RestartApplicationStub(url: url)
        let second = RestartApplicationStub(url: URL(fileURLWithPath: "/Other/Codex.app"))
        for applications: [any CodexDesktopApplication] in [[], [first, second]] {
            var sut = CodexDesktopRestarter()
            sut.applications = { applications }
            sut.installedURL = { nil }
            sut.open = { _ in XCTFail("Must not open an unknown app") }
            do { try await sut.restart(); XCTFail("Expected unavailable") }
            catch { XCTAssertEqual(error as? CodexDesktopRestarter.RestartError, .unavailable) }
        }
        XCTAssertEqual(first.quitRequests, 0)
        XCTAssertEqual(second.quitRequests, 0)
    }

    func testLaunchFailureIsReported() async {
        var sut = CodexDesktopRestarter()
        sut.applications = { [] }
        sut.installedURL = { self.url }
        sut.open = { _ in throw CocoaError(.fileReadNoSuchFile) }
        do { try await sut.restart(); XCTFail("Expected launch failure") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile) }
    }

    func testRestartPromptOffersBothChoicesAndDefaultsToLater() {
        _ = NSApplication.shared
        for language in [DisplayLanguage.simplifiedChinese, .english] {
            let prompt = DefaultModelWindowController.restartPrompt(text: AppText(language: language))
            XCTAssertEqual(prompt.buttons.count, 2)
            XCTAssertEqual(prompt.buttons[0].keyEquivalent, "")
            XCTAssertEqual(prompt.buttons[1].keyEquivalent, "\r")
            XCTAssertFalse(prompt.informativeText.isEmpty)
            if language == .simplifiedChinese {
                XCTAssertEqual(prompt.buttons.map(\.title), ["现在重启 Codex", "稍后手动重启"])
                XCTAssertTrue(prompt.informativeText.contains("可能中断正在运行的任务"))
            }
        }
    }
}

@MainActor
private final class RestartApplicationStub: CodexDesktopApplication {
    let bundleURL: URL?
    var isTerminated = false
    var acceptsQuit = true
    var quitRequests = 0
    init(url: URL?) { bundleURL = url }
    func terminate() -> Bool {
        quitRequests += 1
        return acceptsQuit
    }
}
