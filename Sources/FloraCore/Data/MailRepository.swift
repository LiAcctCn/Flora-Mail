import Foundation

public enum RepositoryError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case unreadableStore

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "This mail store uses unsupported version \(version). Your existing data has been preserved."
        case .unreadableStore: "The local mail store could not be read. Your existing data has been preserved."
        }
    }
}

@MainActor
public protocol MailRepository {
    func load() throws -> AppSnapshot?
    func save(_ snapshot: AppSnapshot) throws
}

/// A small, versioned local store. Atomic replacement prevents partial writes.
/// Loading a corrupt or newer store fails explicitly, never reseeding over it.
@MainActor
public final class JSONMailRepository: MailRepository {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> AppSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw RepositoryError.unreadableStore
        }
        guard header.schemaVersion == 1 else { throw RepositoryError.unsupportedSchema(header.schemaVersion) }
        do { return try decoder.decode(AppSnapshot.self, from: data) }
        catch { throw RepositoryError.unreadableStore }
    }

    public func save(_ snapshot: AppSnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw RepositoryError.unsupportedSchema(snapshot.schemaVersion) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
public final class MemoryMailRepository: MailRepository {
    public private(set) var snapshot: AppSnapshot?
    public init(snapshot: AppSnapshot? = nil) { self.snapshot = snapshot }
    public func load() throws -> AppSnapshot? { snapshot }
    public func save(_ snapshot: AppSnapshot) throws { self.snapshot = snapshot }
}
