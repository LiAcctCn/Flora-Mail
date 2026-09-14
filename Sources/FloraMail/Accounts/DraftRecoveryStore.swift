import Foundation
import FloraCore

/// Unsaved editor recovery is separate from an accepted local/server draft.
/// Only one composer exists, so a single bounded, access-restricted file suffices.
@MainActor
final class DraftRecoveryStore {
    enum StorageError: Error { case tooLarge, pendingRecovery }
    private let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> Draft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
    }
    func save(_ draft: Draft) throws {
        // Recovery is a single slot, but it is not permission to overwrite a
        // different unsaved draft awaiting the user's Review/Discard decision.
        if let pending = try load(), pending.id != draft.id { throw StorageError.pendingRecovery }
        let data = try JSONEncoder().encode(draft)
        guard data.count <= 4 * 1_024 * 1_024 else { throw StorageError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear(draftID: UUID) throws {
        guard try load()?.id == draftID else { return }
        try FileManager.default.removeItem(at: url)
    }
}
