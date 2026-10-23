import AppKit
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class ScheduledMessageShortcutTests: XCTestCase {
    func testCommandPasteIntoTaskFieldSelectsExactChat() throws {
        _ = NSApplication.shared
        let controller = ScheduledMessageWindowController(textProvider: { AppText(language: .simplifiedChinese) })
        let window = try XCTUnwrap(controller.window)
        let clipboard = NSPasteboard.withUniqueName()
        defer { window.close(); clipboard.releaseGlobally() }
        // Isolate the test from the user's clipboard, while keeping the real field-editor route.
        let delegate = ShortcutWindowDelegate(clipboard: clipboard)
        window.delegate = delegate
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let views = descendants(try XCTUnwrap(window.contentView))
        let field = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Target Codex chat ID" })
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("selectTask") })
        let id = "01a16784-0649-7352-a8bd-d7191240e483"
        ScheduledMessageWindowController.populateTaskMenu(picker, tasks: [(id, "Target")], placeholder: "Choose")
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        XCTAssertTrue(window.firstResponder === delegate.editor)
        XCTAssertTrue(delegate.editor.isFieldEditor)
        func key(_ character: String, code: UInt16) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            return window.performKeyEquivalent(with: event)
        }
        let link = "codex://threads/\(id)?view=review"
        clipboard.setString(link, forType: .string)
        XCTAssertTrue(try key("v", code: 9))
        XCTAssertEqual(delegate.editor.pasteCount, 1)
        XCTAssertEqual(field.stringValue, link)
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, id)
        XCTAssertEqual(ScheduledMessageWindowController.canonicalTaskID(field.stringValue), id)
        XCTAssertTrue(try key("a", code: 0))
        XCTAssertEqual(delegate.editor.selectedRange(), NSRange(location: 0, length: link.utf16.count))
    }
}

@MainActor
private final class ShortcutWindowDelegate: NSObject, NSWindowDelegate {
    let editor: ShortcutFieldEditor
    init(clipboard: NSPasteboard) {
        editor = ShortcutFieldEditor(clipboard: clipboard)
        super.init()
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
}

@MainActor
private final class ShortcutFieldEditor: NSTextView {
    let clipboard: NSPasteboard
    var pasteCount = 0
    init(clipboard: NSPasteboard) {
        self.clipboard = clipboard
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: 100))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isFieldEditor = true
        isRichText = false
    }
    required init?(coder: NSCoder) { nil }
    override func paste(_ sender: Any?) {
        pasteCount += 1
        if let text = clipboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }
}
