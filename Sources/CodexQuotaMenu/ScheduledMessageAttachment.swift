import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ScheduledMessageAttachment: Codable, Equatable {
    enum Kind: String, Codable { case file, image }
    let name: String
    let path: String
    let kind: Kind
    let byteCount: Int
    let sha256: String
}

struct ScheduledMessageAttachmentStore {
    static let maximumCount = 20
    static let maximumFileBytes = 25_000_000
    static let maximumTotalBytes = 100_000_000
    let root: URL

    func directory(_ id: UUID) -> URL { root.resolvingSymlinksInPath().appendingPathComponent(id.uuidString + "-attachments", isDirectory: true) }

    func stage(_ urls: [URL], id: UUID) throws -> [ScheduledMessageAttachment] {
        guard urls.count <= Self.maximumCount else { throw failure("attachment_limit") }
        guard !urls.isEmpty else { return [] }
        let folder = directory(id)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ScheduledMessageError.collision }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: folder) } }
        var result: [ScheduledMessageAttachment] = []
        var total = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard url.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
                  size <= Self.maximumFileBytes else { throw failure("attachment_invalid") }
            let name = Self.safeName(url.lastPathComponent)
            var target = folder.appendingPathComponent(UUID().uuidString + "-" + name)
            let imageType = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            let kind: ScheduledMessageAttachment.Kind = imageType ? .image : .file
            if imageType {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, Double(width) * Double(height) <= 80_000_000 else {
                    throw failure("attachment_image_invalid")
                }
                if ["png", "jpg", "jpeg", "webp", "gif"].contains(url.pathExtension.lowercased()) {
                    try FileManager.default.copyItem(at: url, to: target)
                } else {
                    // HEIC/TIFF and other ImageIO formats are normalized with orientation preserved.
                    target = target.appendingPathExtension("jpg")
                    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw failure("attachment_image_invalid")
                    }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92,
                        kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] ?? 1] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw failure("attachment_image_invalid") }
                }
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let data = try Data(contentsOf: target, options: .mappedIfSafe)
            total += data.count
            guard data.count <= Self.maximumFileBytes, total <= Self.maximumTotalBytes else { throw failure("attachment_limit") }
            result.append(.init(name: name, path: target.path, kind: kind, byteCount: data.count,
                                sha256: Self.hash(data)))
        }
        success = true
        return result
    }

    func validate(_ attachments: [ScheduledMessageAttachment], id: UUID) throws {
        guard attachments.count <= Self.maximumCount else { throw failure("attachment_limit") }
        var total = 0
        for item in attachments {
            let url = URL(fileURLWithPath: item.path)
            guard url.deletingLastPathComponent().standardizedFileURL == directory(id).standardizedFileURL,
                  url.resolvingSymlinksInPath() == url.standardizedFileURL,
                  item.byteCount > 0, item.byteCount <= Self.maximumFileBytes else { throw failure("attachment_invalid") }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue == item.byteCount else { throw failure("attachment_changed") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard Self.hash(data) == item.sha256 else { throw failure("attachment_changed") }
            } catch let error as ScheduledMessageDeliveryError { throw error }
            catch { throw failure("attachment_unavailable") }
            total += item.byteCount
        }
        guard total <= Self.maximumTotalBytes else { throw failure("attachment_limit") }
    }

    func remove(_ id: UUID) throws {
        let folder = directory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func failure(_ code: String) -> ScheduledMessageDeliveryError { .init(code: code) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func safeName(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" ? "_" : String($0) }.joined()
        return String(cleaned.prefix(160))
    }
}

extension ScheduledMessage {
    var attachmentItems: [ScheduledMessageAttachment] { attachments ?? [] }
    var deliveryText: String {
        guard !attachmentItems.isEmpty else { return message }
        let references = attachmentItems.map { attachment in
            "\n## \(attachment.name): \(attachment.path)\n" + (attachment.kind == .image ? "Image attachment: true\n" : "")
        }.joined()
        return "# Files mentioned by the user:\n" + references + "\n## My request:\n" + message
    }
    var deliveryInput: [[String: Any]] {
        [["type": "text", "text": deliveryText, "text_elements": []] as [String: Any]] +
            attachmentItems.filter { $0.kind == .image }.map { ["type": "localImage", "path": $0.path] }
    }
}
