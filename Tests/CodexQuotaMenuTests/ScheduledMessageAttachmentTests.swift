import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CodexQuotaMenu

final class ScheduledMessageAttachmentTests: XCTestCase {
    private let threadID = "019f898f-3d2d-7a03-ab69-7a2f89882f96"
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/cqm-attachment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func message(_ attachments: [ScheduledMessageAttachment], id: UUID) -> ScheduledMessage {
        .init(id: id, fireDate: Date().addingTimeInterval(3600), threadID: threadID, threadTitle: "Test",
              model: "gpt-6-sol", message: "Check these files", effort: "high", attachments: attachments)
    }
    private func image(at url: URL, type: UTType) throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }

    func testSnapshotSurvivesOriginalDeletionAndUsesPrivatePermissions() throws {
        let root = try fixture(), id = UUID()
        let source = root.appendingPathComponent("财务 测试.txt")
        try Data("test content".utf8).write(to: source)
        let store = ScheduledMessageAttachmentStore(root: root.appendingPathComponent("records"))
        let attachments = try store.stage([source], id: id)
        try FileManager.default.removeItem(at: source)
        try store.validate(attachments, id: id)
        XCTAssertEqual(attachments[0].name, "财务 测试.txt")
        XCTAssertEqual(try String(contentsOfFile: attachments[0].path), "test content")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: attachments[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.directory(id).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testImagesAreNativeInputsAndTIFFConvertsToJPEGWithOrientation() throws {
        let root = try fixture(), id = UUID()
        let png = root.appendingPathComponent("photo.png"), tiff = root.appendingPathComponent("photo.tiff")
        let text = root.appendingPathComponent("notes.txt")
        try image(at: png, type: .png); try image(at: tiff, type: .tiff)
        try Data("note".utf8).write(to: text)
        let store = ScheduledMessageAttachmentStore(root: root.appendingPathComponent("records"))
        let attachments = try store.stage([text, png, tiff], id: id)
        try store.validate(attachments, id: id)
        XCTAssertEqual(attachments.map(\.kind), [.file, .image, .image])
        XCTAssertTrue(attachments[2].path.hasSuffix(".jpg"))
        let converted = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: attachments[2].path) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(converted) as String?, UTType.jpeg.identifier)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(converted, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        let item = message(attachments, id: id)
        let request = ScheduledMessageDesktopClient.turnRequest(item, effort: "high", directory: root)
        let input = try XCTUnwrap(request["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["text"] as? String, item.deliveryText)
        XCTAssertEqual(input[1]["type"] as? String, "localImage")
        XCTAssertEqual(input[1]["path"] as? String, attachments[1].path)
        XCTAssertEqual(input[2]["path"] as? String, attachments[2].path)
        XCTAssertTrue(item.deliveryText.contains("## notes.txt: " + attachments[0].path))
        XCTAssertTrue(item.deliveryText.hasSuffix("## My request:\nCheck these files"))
    }

    func testLegacyRecordsAndAttachmentOnlyMessage() throws {
        let id = UUID()
        let item = message([], id: id)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        raw.removeValue(forKey: "attachments")
        let legacy = try JSONDecoder().decode(ScheduledMessage.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(legacy.attachmentItems.isEmpty)
        XCTAssertEqual(legacy.deliveryText, legacy.message)
        let only = ScheduledMessage(id: id, fireDate: item.fireDate, threadID: threadID, threadTitle: "Test",
            model: item.model, message: "", attachments: [.init(name: "x", path: "/x", kind: .file, byteCount: 1, sha256: "x")])
        XCTAssertNoThrow(try only.validate())
    }

    func testChangedMissingAndForeignAttachmentsPreventSending() throws {
        let root = try fixture(), id = UUID()
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        let recordStore = ScheduledMessageStore(root: root.appendingPathComponent("records"))
        let store = ScheduledMessageAttachmentStore(root: recordStore.root)
        let attachments = try store.stage([file], id: id)
        XCTAssertThrowsError(try store.validate(attachments, id: UUID()))
        try Data("other".utf8).write(to: URL(fileURLWithPath: attachments[0].path))
        XCTAssertThrowsError(try store.validate(attachments, id: id)) {
            XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "attachment_changed")
        }
        let item = message(attachments, id: id)
        try recordStore.write(item)
        let scheduler = ScheduledMessageScheduler(store: recordStore, agentsDirectory: root, controller: AttachmentLaunchctl())
        var runner = ScheduledMessageRunner(store: recordStore, scheduler: scheduler)
        runner.now = { item.fireDate }
        runner.resolveThread = { _ in XCTFail("Must validate before contacting Codex"); return .init(directory: root, effort: nil) }
        runner.send = { _, _, _ in XCTFail("Must never send invalid attachments"); return true }
        XCTAssertEqual(runner.run(id: id), 1)
        XCTAssertEqual(try recordStore.read(id).result, "attachment_changed")
        try FileManager.default.removeItem(atPath: attachments[0].path)
        XCTAssertThrowsError(try store.validate(attachments, id: id)) {
            XCTAssertEqual(($0 as? ScheduledMessageDeliveryError)?.code, "attachment_unavailable")
        }
    }

    func testCancelAndBootstrapFailureCleanOnlyOwnedCopies() throws {
        let root = try fixture(), id = UUID()
        let source = root.appendingPathComponent("notes.txt")
        try Data("note".utf8).write(to: source)
        let recordStore = ScheduledMessageStore(root: root.appendingPathComponent("records"))
        let attachments = ScheduledMessageAttachmentStore(root: recordStore.root)
        let controller = AttachmentLaunchctl()
        let scheduler = ScheduledMessageScheduler(store: recordStore, agentsDirectory: root.appendingPathComponent("agents"), controller: controller)
        let item = message(try attachments.stage([source], id: id), id: id)
        try scheduler.schedule(item)
        try scheduler.cancel(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.directory(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let secondID = UUID()
        let second = message(try attachments.stage([source], id: secondID), id: secondID)
        controller.failBootstrap = true
        XCTAssertThrowsError(try scheduler.schedule(second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.directory(secondID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordStore.url(for: secondID).path))
    }

    func testCLIFallbackReceivesFileReferencesAndNativeImageArgument() throws {
        let root = try fixture(), id = UUID()
        let png = root.appendingPathComponent("photo.png"), text = root.appendingPathComponent("notes.txt")
        try image(at: png, type: .png); try Data("note".utf8).write(to: text)
        let attachments = try ScheduledMessageAttachmentStore(root: root.appendingPathComponent("records")).stage([text, png], id: id)
        let item = message(attachments, id: id)
        let fake = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(root.path)/args'
        cat > '\(root.path)/prompt'
        printf '%s\\n' '{"type":"thread.started","thread_id":"\(threadID)"}' '{"type":"turn.completed"}'
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        XCTAssertTrue(try ScheduledMessageRunner.runCodex(item, directory: root, effort: "high", executable: fake, timeout: 5))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prompt")), item.deliveryText)
        let args = try String(contentsOf: root.appendingPathComponent("args")).split(separator: "\n").map(String.init)
        let imageIndex = try XCTUnwrap(args.firstIndex(of: "--image"))
        XCTAssertEqual(args[imageIndex + 1], attachments[1].path)
        XCTAssertEqual(Array(args.suffix(2)), [threadID, "-"])
        XCTAssertFalse(args.contains(item.message))
    }

    func testLimitsDirectoryAndSymlinkRejectAndRollback() throws {
        let root = try fixture()
        let store = ScheduledMessageAttachmentStore(root: root.appendingPathComponent("records"))
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        for urls in [[empty], [root], Array(repeating: empty, count: 21)] {
            let id = UUID()
            XCTAssertThrowsError(try store.stage(urls, id: id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(id).path))
        }
        let file = root.appendingPathComponent("file.txt"), link = root.appendingPathComponent("link.txt")
        try Data("hi".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try store.stage([link], id: UUID()))
        let big = root.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(ScheduledMessageAttachmentStore.maximumFileBytes + 1)); try handle.close()
        XCTAssertThrowsError(try store.stage([big], id: UUID()))
    }
}

private final class AttachmentLaunchctl: LaunchctlControlling {
    var labels = Set<String>()
    var failBootstrap = false
    func bootstrap(plistURL: URL) throws {
        if failBootstrap { throw ScheduledMessageError.commandFailed }
        labels.insert(plistURL.deletingPathExtension().lastPathComponent)
    }
    func isLoaded(label: String) throws -> Bool { labels.contains(label) }
    func loadedOwnedLabels() throws -> Set<String> { labels }
    func bootout(label: String) throws { labels.remove(label) }
}
