import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ScheduledMessageEditorLayoutTests: XCTestCase {
    func testSendTimeFitsWithoutCompressingDateAtMinimumWindowWidth() throws {
        _ = NSApplication.shared
        for language in [DisplayLanguage.simplifiedChinese, .english] {
            let controller = ScheduledMessageWindowController(textProvider: { AppText(language: language) })
            let window = try XCTUnwrap(controller.window)
            let content = try XCTUnwrap(window.contentView)
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { descendants($0) }
            }
            let views = descendants(content)
            let date = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Scheduled message send time" })
            let buttons = views.compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("adjustSendTime:") }
            XCTAssertEqual(buttons.count, 8)
            for width in [600.0, 650.0, 850.0] {
                window.setContentSize(NSSize(width: width, height: 750))
                content.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(date.frame.width + 0.5, date.intrinsicContentSize.width)
                for control in [date as NSView] + buttons {
                    let rect = control.convert(control.bounds, to: content)
                    XCTAssertGreaterThanOrEqual(rect.minX, 21)
                    XCTAssertLessThanOrEqual(rect.maxX, content.bounds.maxX - 21)
                }
                let dateRect = date.convert(date.bounds, to: content)
                let buttonRects = buttons.map { $0.convert($0.bounds, to: content) }
                XCTAssertLessThan(dateRect.maxX, buttonRects.map(\.minX).min()!)
                XCTAssertTrue(buttonRects.contains { $0.minY <= dateRect.midY && $0.maxY >= dateRect.midY } ||
                              (buttonRects.map(\.minY).min()! < dateRect.midY && buttonRects.map(\.maxY).max()! > dateRect.midY))
                for button in buttons {
                    XCTAssertEqual(button.frame.width, buttons[0].frame.width, accuracy: 0.5)
                    XCTAssertEqual(button.frame.height, buttons[0].frame.height, accuracy: 0.5)
                }
            }
        }
    }

    func testDateTextHasNoDayPaddingAndRejectsInvalidDates() throws {
        for text in ["2026/10/2 15:08", "2026/1/9 09:01", "2028/2/29 23:59"] {
            let date = try XCTUnwrap(ScheduledMessageDateText.date(from: text))
            XCTAssertEqual(ScheduledMessageDateText.string(from: date), text)
        }
        let padded = try XCTUnwrap(ScheduledMessageDateText.date(from: "2026/10/02 15:08"))
        XCTAssertEqual(ScheduledMessageDateText.string(from: padded), "2026/10/2 15:08")
        for text in ["2026/10/ 2 15:08", "2026/2/29 15:08", "2026/13/2 15:08", "2026/10/2 25:08", "2026/10/2 15:08 junk"] {
            XCTAssertNil(ScheduledMessageDateText.date(from: text), text)
        }
    }

    func testFirstChineseGlyphRemainsVisibleAndLongLinesWrapAfterResize() throws {
        _ = NSApplication.shared
        let controller = ScheduledMessageWindowController(textProvider: { AppText(language: .simplifiedChinese) })
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let text = try XCTUnwrap(editor(in: content))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        for width in [650.0, 600.0, 850.0] {
            window.setContentSize(NSSize(width: width, height: 750))
            content.layoutSubtreeIfNeeded()
            scroll.tile()
            text.string = "消息首字必须完整显示。" + String(repeating: "中文长消息自动换行。", count: 30)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.scrollRangeToVisible(NSRange(location: 0, length: 1))
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
            let glyph = layout.boundingRect(forGlyphRange: range, in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            let visible = text.visibleRect
            XCTAssertEqual(text.frame.width, scroll.contentSize.width, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(glyph.minX, visible.minX + 4)
            XCTAssertGreaterThanOrEqual(glyph.minY, visible.minY)
            XCTAssertLessThanOrEqual(glyph.maxX, visible.maxX)
            XCTAssertLessThanOrEqual(glyph.maxY, visible.maxY)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
            let allGlyphs = layout.glyphRange(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: allGlyphs) { _, _, _, _, _ in lines += 1 }
            XCTAssertGreaterThan(lines, 5)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX,
                                     visible.width - text.textContainerInset.width * 2 + 1)
        }
    }
}
