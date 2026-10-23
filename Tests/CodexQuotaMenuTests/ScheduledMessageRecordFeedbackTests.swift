import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ScheduledMessageRecordFeedbackTests: XCTestCase {
    func testRemovingOneRecordShowsRemainingPlansActualStatus() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root.appendingPathComponent("records"))
        let scheduler = ScheduledMessageScheduler(store: store, agentsDirectory: root.appendingPathComponent("agents"), controller: FeedbackLaunchctl())
        let first = message(date: Date().addingTimeInterval(3600))
        let remaining = message(date: Date().addingTimeInterval(7200))
        try scheduler.schedule(first)
        try scheduler.schedule(remaining)
        let controller = ScheduledMessageWindowController(textProvider: { AppText(language: .simplifiedChinese) }, store: store, scheduler: scheduler)
        defer { controller.window?.close() }
        let (picker, feedback) = try controls(controller)
        controller.refreshSaved(preferredID: first.id)
        controller.perform(NSSelectorFromString("remove"))
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, remaining.id)
        XCTAssertEqual(try store.read(remaining.id).state, .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scheduler.plistURL(remaining.id).path))
        XCTAssertTrue(feedback.stringValue.contains("已安排，等待发送"))
        XCTAssertFalse(feedback.stringValue.contains("已移除"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: first.id).path))
        controller.perform(NSSelectorFromString("remove"))
        XCTAssertTrue(feedback.stringValue.contains("当前没有定时消息"))
        XCTAssertEqual(picker.numberOfItems, 0)
    }

    func testRefreshPreservesSelectionAndCanSelectNewlySavedRecord() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScheduledMessageStore(root: root)
        let old = message(date: Date().addingTimeInterval(3600))
        let new = message(date: Date().addingTimeInterval(7200))
        try store.write(old)
        let controller = ScheduledMessageWindowController(textProvider: { AppText(language: .simplifiedChinese) }, store: store)
        defer { controller.window?.close() }
        let (picker, _) = try controls(controller)
        controller.refreshSaved()
        try store.write(new)
        controller.refreshSaved(preferredID: new.id)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, new.id)
        controller.refreshSaved()
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, new.id)
    }

    private func message(date: Date) -> ScheduledMessage {
        .init(fireDate: date, threadID: UUID().uuidString, threadTitle: "Test", model: "test", message: "test")
    }
    private func controls(_ controller: ScheduledMessageWindowController) throws -> (NSPopUpButton, NSTextField) {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let views = descendants(try XCTUnwrap(controller.window?.contentView))
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Scheduled message records" })
        let feedback = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Scheduled message feedback" })
        return (picker, feedback)
    }
}

private final class FeedbackLaunchctl: LaunchctlControlling {
    var loaded = Set<String>()
    func bootstrap(plistURL: URL) throws { loaded.insert(plistURL.deletingPathExtension().lastPathComponent) }
    func isLoaded(label: String) throws -> Bool { loaded.contains(label) }
    func loadedOwnedLabels() throws -> Set<String> { loaded }
    func bootout(label: String) throws { loaded.remove(label) }
}
