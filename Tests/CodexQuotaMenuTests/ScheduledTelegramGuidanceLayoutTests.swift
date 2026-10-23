import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ScheduledTelegramGuidanceLayoutTests: XCTestCase {
    func testGuidanceAndBindingStatusFitInBothLanguages() throws {
        _ = NSApplication.shared
        for (language, suffix) in [(DisplayLanguage.simplifiedChinese, "zh"), (.english, "en")] {
            let controller = ScheduledTelegramWindowController(textProvider: { AppText(language: language) })
            let window = try XCTUnwrap(controller.window)
            defer { window.close() }
            let content = try XCTUnwrap(window.contentView)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let fields = descendants(content).compactMap { $0 as? NSTextField }
            // Keep generated previews independent of the user's saved recipient.
            fields.first { $0.accessibilityLabel() == "Telegram Chat ID" }?.stringValue = ""
            window.makeKeyAndOrderFront(nil)
            controller.perform(NSSelectorFromString("bindRecipient"))
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            for view in descendants(content) where view is NSTextField || view is NSButton {
                let frame = view.convert(view.bounds, to: content)
                XCTAssertGreaterThanOrEqual(frame.minY, 0, "\(suffix): \(view)")
                XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height, "\(suffix): \(view)")
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width)
            }
            if ProcessInfo.processInfo.environment["CQM_RENDER_GUIDANCE"] == "1",
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/cqm-guidance-\(suffix).png"))
            }
        }
    }
}
