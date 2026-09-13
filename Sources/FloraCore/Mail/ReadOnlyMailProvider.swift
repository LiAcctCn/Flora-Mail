import Foundation

public struct MailSyncRequest: Sendable {
    public var checkpoint: SyncCheckpoint?
    public var limit: Int
    public var since: Date
    public init(checkpoint: SyncCheckpoint? = nil, limit: Int = 50, since: Date) {
        self.checkpoint = checkpoint; self.limit = min(max(limit, 1), 100); self.since = since
    }
}

public struct MailRemoteStateUpdate: Sendable {
    public var providerID: String
    public var isRead: Bool
    public var isFlagged: Bool
    public init(providerID: String, isRead: Bool, isFlagged: Bool) {
        self.providerID = providerID; self.isRead = isRead; self.isFlagged = isFlagged
    }
}

public struct MailSyncPage: Sendable {
    public var messages: [MailMessage]
    public var checkpoint: SyncCheckpoint
    public var hasMore: Bool
    public var deletedProviderMessageIDs: [String]
    public var messageStateUpdates: [MailRemoteStateUpdate]
    public init(messages: [MailMessage], checkpoint: SyncCheckpoint, hasMore: Bool = false, deletedProviderMessageIDs: [String] = [], messageStateUpdates: [MailRemoteStateUpdate] = []) {
        self.messages = messages; self.checkpoint = checkpoint; self.hasMore = hasMore
        self.deletedProviderMessageIDs = deletedProviderMessageIDs
        self.messageStateUpdates = messageStateUpdates
    }
}

public enum MailSyncError: LocalizedError, Equatable, Sendable {
    case accountNotFound, accountMismatch, alreadySyncing, disconnected, authenticationRequired
    case invalidCredentials, unavailable, timedOut, rateLimited, malformedResponse, unsupportedContent, invalidCheckpoint
    public var errorDescription: String? {
        switch self {
        case .accountNotFound: "This account is no longer available."
        case .accountMismatch: "The server returned mail for a different account. No changes were saved."
        case .alreadySyncing: "This account is already syncing."
        case .disconnected: "Connect this account before syncing. Cached mail remains available."
        case .authenticationRequired: "This account needs authorization again. Reconnect in Accounts settings."
        case .invalidCredentials: "The account credentials were not accepted. Reconnect in Accounts settings."
        case .unavailable: "The mail service is unavailable. Cached mail remains available; try again later."
        case .timedOut: "The mail service took too long to respond. Try syncing again."
        case .rateLimited: "The mail service is limiting requests. Try syncing again later."
        case .malformedResponse: "The mail service returned data Flora could not read. Already cached mail is preserved."
        case .unsupportedContent: "This message or attachment uses an unsupported format."
        case .invalidCheckpoint: "The saved sync position is no longer valid. Reconnect to start a recent-mail sync."
        }
    }
}

/// Adapters translate runtime-specific failures to a small, safe recovery model.
public protocol MailSyncFailure: Error {
    var syncError: MailSyncError { get }
}

/// Real adapters expose reads only. SwiftUI reads synchronized repository values;
/// it never renders live provider-specific objects or obtains credentials.
@MainActor
public protocol ReadOnlyMailProvider: MailProvider {
    var accountID: UUID { get }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor]
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage
    func fetchThread(message: MailMessage) async throws -> MailThread
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data
}

public extension ReadOnlyMailProvider {
    /// The persisted source carries its provider thread ID across adapter
    /// recreation. Providers must explicitly implement remote conversation reads;
    /// the legacy UUID lookup is not a reliable substitute after an app restart.
    func fetchThread(message: MailMessage) async throws -> MailThread {
        guard message.accountID == accountID else { throw MailSyncError.accountMismatch }
        throw MailThreadError.unavailable
    }
    func fetchFolders() async throws -> [MailFolder] {
        let roles = try await fetchRemoteFolders().compactMap(\.role)
        return MailFolder.allCases.filter { roles.contains($0) }
    }
    func fetchMessages(folder: MailFolder? = nil) async throws -> [MailMessage] {
        let page = try await fetchPage(MailSyncRequest(since: Date().addingTimeInterval(-30 * 86_400)))
        return page.messages.filter { folder == nil || $0.folder == folder }
    }
    func fetchThread(id: UUID) async throws -> MailThread {
        let messages = try await fetchMessages(folder: nil).filter { $0.threadID == id }
        guard !messages.isEmpty else { throw MailActionError.messageNotFound }
        return MailThread(id: id, messages: messages.sorted { $0.date < $1.date })
    }
    @discardableResult
    func perform(_ proposal: ProposedAction, confirmed: Bool = false) async throws -> ExecutedAction {
        throw MailActionError.readOnlyAccount
    }
}
