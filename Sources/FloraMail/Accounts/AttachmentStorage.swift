import Foundation

/// Attachment bytes are fetched only on an explicit Download command. Paths in
/// mail metadata are relative, so provider filenames cannot escape this store.
actor AttachmentStorage {
    let root: URL
    static let maximumBytes = 25 * 1_024 * 1_024

    init(root: URL) { self.root = root }

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
    case tooLarge, missing, invalidPath
    var errorDescription: String? {
        switch self {
        case .tooLarge: "This attachment exceeds the local 25 MiB storage limit. The selected provider may impose a smaller download limit."
        case .missing: "The downloaded file is no longer available. Download it again."
        case .invalidPath: "The attachment location is invalid. Download it again."
        }
    }
}
