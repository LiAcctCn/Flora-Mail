import CryptoKit
import Foundation

/// Granted OAuth access is separate from the user's current permission to write.
/// Existing registrations and saved configurations remain read-only by default.
public enum OAuthAccessLevel: String, Codable, Equatable, Sendable { case readOnly, readWrite }

public enum MailProviderType: String, Codable, CaseIterable, Identifiable, Sendable {
    case demo, gmail, microsoft, iCloud
    public var id: String { rawValue }
    public var title: String {
        switch self { case .demo: "Demo"; case .gmail: "Gmail"; case .microsoft: "Microsoft Outlook"; case .iCloud: "iCloud Mail" }
    }
}

public enum MailAccountStatus: String, Codable, Sendable {
    case connected, disconnected, reauthenticationRequired, syncing, error
    public var title: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .reauthenticationRequired: "Reconnect required"
        case .syncing: "Syncing"
        case .error: "Unable to sync"
        }
    }
}

/// An opaque Keychain item name, never credential material.
public struct MailCredentialReference: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

/// The provider owns interpretation of these strings. A checkpoint advances only
/// in the same atomic commit as its normalized message page.
public struct SyncCheckpoint: Codable, Equatable, Sendable {
    public var opaqueState: String?
    public var continuationToken: String?
    public var initialComplete: Bool
    public init(opaqueState: String? = nil, continuationToken: String? = nil, initialComplete: Bool = false) {
        self.opaqueState = opaqueState; self.continuationToken = continuationToken; self.initialComplete = initialComplete
    }
}

public struct MailSyncState: Codable, Equatable, Sendable {
    public var checkpoint: SyncCheckpoint?
    public var lastSuccessfulSync: Date?
    public var errorMessage: String?
    public init(checkpoint: SyncCheckpoint? = nil, lastSuccessfulSync: Date? = nil, errorMessage: String? = nil) {
        self.checkpoint = checkpoint; self.lastSuccessfulSync = lastSuccessfulSync; self.errorMessage = errorMessage
    }
}

public struct MailFolderDescriptor: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var accountID: UUID
    public var name: String
    public var role: MailFolder?
    public var isLabel: Bool
    public init(id: String, accountID: UUID, name: String, role: MailFolder? = nil, isLabel: Bool = false) {
        self.id = id; self.accountID = accountID; self.name = name; self.role = role; self.isLabel = isLabel
    }
}

public enum AttachmentDownloadState: String, Codable, Sendable { case notDownloaded, downloaded }

/// Namespaced, deterministic local IDs. Provider IDs are never globally unique.
public enum StableMailIdentity {
    public static func message(accountID: UUID, providerID: String) -> UUID { make(accountID, "message", providerID) }
    public static func thread(accountID: UUID, providerID: String) -> UUID { make(accountID, "thread", providerID) }
    public static func attachment(accountID: UUID, providerID: String) -> UUID { make(accountID, "attachment", providerID) }
    private static func make(_ accountID: UUID, _ kind: String, _ providerID: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(accountID.uuidString.lowercased())\u{0}\(kind)\u{0}\(providerID)".utf8))
        var bytes = Array(digest.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
