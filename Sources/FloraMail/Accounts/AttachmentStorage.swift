import Foundation
import ImageIO
import UniformTypeIdentifiers
import FloraCore
import CryptoKit

/// Attachment bytes are fetched only on an explicit Download command. Paths in
/// mail metadata are relative, so provider filenames cannot escape this store.
actor AttachmentStorage {
    let root: URL
    private let mimeTypeLookup: @Sendable (URL) throws -> String?
    static let maximumBytes = 25 * 1_024 * 1_024
    static let maximumOutgoingBytes = 2 * 1_024 * 1_024
    static let maximumOutgoingTotalBytes = 8 * 1_024 * 1_024

    init(root: URL, mimeTypeLookup: @escaping @Sendable (URL) throws -> String? = { source in
        try source.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType
    }) { self.root = root; self.mimeTypeLookup = mimeTypeLookup }

    func save(_ data: Data, accountID: UUID, messageID: UUID, attachmentID: UUID, fileName: String) throws -> String {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else { throw AttachmentStorageError.tooLarge }
        let suffix = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let allowed = CharacterSet.alphanumerics
        let safeSuffix = !suffix.isEmpty && suffix.count <= 12 && suffix.unicodeScalars.allSatisfy(allowed.contains) ? ".\(suffix)" : ""
        let relative = "\(accountID.uuidString)/\(messageID.uuidString)/\(attachmentID.uuidString)\(safeSuffix)"
        let target = try location(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        try data.write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return relative
    }

    func existingFile(_ relative: String) throws -> URL {
        let url = try location(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AttachmentStorageError.missing }
        return url
    }

    func importForDraft(_ source: URL, accountID: UUID, draftID: UUID) throws -> DraftAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        // File identity and bounds are required. MIME metadata is optional and
        // can fail independently when LaunchServices is unavailable.
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, size >= 0, size <= Self.maximumOutgoingBytes else { throw AttachmentStorageError.outgoingTooLarge }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumOutgoingBytes + 1) ?? Data()
        guard data.count <= Self.maximumOutgoingBytes else { throw AttachmentStorageError.outgoingTooLarge }
        let id = UUID(), name = source.lastPathComponent
        let path = try save(data, accountID: accountID, messageID: draftID, attachmentID: id, fileName: name)
        let mimeType = (try? mimeTypeLookup(source)) ?? "application/octet-stream"
        return DraftAttachment(id: id, name: name, mimeType: mimeType, size: data.count, localRelativePath: path,
                               contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func outgoingPayloads(for draft: Draft) throws -> [OutgoingAttachment] {
        guard let accountID = draft.accountID, draft.attachments.count <= 10,
              draft.attachments.reduce(0, { $0 + max(0, $1.size) }) <= Self.maximumOutgoingTotalBytes else { throw AttachmentStorageError.outgoingTooLarge }
        return try draft.attachments.map { attachment in
            let prefix = "\(accountID.uuidString)/\(draft.id.uuidString)/\(attachment.id.uuidString)"
            guard attachment.localRelativePath == prefix || attachment.localRelativePath.hasPrefix(prefix + ".") else { throw AttachmentStorageError.invalidPath }
            let file = try existingFile(attachment.localRelativePath)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumOutgoingBytes + 1) ?? Data()
            guard data.count <= Self.maximumOutgoingBytes, data.count == attachment.size else { throw AttachmentStorageError.outgoingTooLarge }
            guard attachment.contentHash == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { throw AttachmentStorageError.changed }
            return OutgoingAttachment(id: attachment.id, name: attachment.name, mimeType: attachment.mimeType, data: data)
        }
    }

    func imagePreview(_ relative: String) throws -> Data {
        let url = try existingFile(relative)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 64_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw AttachmentStorageError.unsupportedImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AttachmentStorageError.unsupportedImage }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 5 * 1_024 * 1_024 else { throw AttachmentStorageError.tooLarge }
        return data as Data
    }

    private func location(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              !relative.contains("\0"), relative.split(separator: "/").count == 3 else { throw AttachmentStorageError.invalidPath }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/") else { throw AttachmentStorageError.invalidPath }
        return target
    }
}

enum AttachmentStorageError: LocalizedError {
    case tooLarge, outgoingTooLarge, missing, invalidPath, unsupportedImage, changed
    var errorDescription: String? {
        switch self {
        case .changed: "This attachment changed or predates attachment verification. Remove it and attach the intended file again before sending."
        case .outgoingTooLarge: "Composer attachments are limited to 2 MiB each and 8 MiB total. The file may also have changed since it was attached."
        case .unsupportedImage: "This image cannot be safely previewed. You can inspect the downloaded file in Finder."
        case .tooLarge: "This attachment exceeds the local 25 MiB storage limit. The selected provider may impose a smaller download limit."
        case .missing: "The downloaded file is no longer available. Download it again."
        case .invalidPath: "The attachment location is invalid. Download it again."
        }
    }
}
