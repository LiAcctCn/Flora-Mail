import Foundation

public enum MailThreadError: LocalizedError, Equatable, Sendable {
    case unavailable, sourceUnavailable, invalidThread, tooLarge, alreadyLoading
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This provider cannot load more of this conversation. Cached messages remain available."
        case .sourceUnavailable: "The source message is no longer available. Select the conversation again."
        case .invalidThread: "The mail service returned a different conversation. No cached mail was changed."
        case .tooLarge: "This conversation exceeds the current loading limit. Cached messages remain available."
        case .alreadyLoading: "This conversation is already loading."
        }
    }
}

/// Explicit conversation retrieval augments the local store without touching the
/// mailbox-wide synchronization checkpoint or granting any mail mutation rights.
@MainActor
public final class MailThreadService {
    public static let maximumMessages = 500
    public static let maximumTextBytes = 32 * 1_024 * 1_024
    private let executor: ActionExecutor
    private struct RequestKey: Hashable { let accountID: UUID; let threadID: UUID }
    private var loading: Set<RequestKey> = []
    public init(executor: ActionExecutor) { self.executor = executor }

    @discardableResult
    public func load(message: MailMessage, provider: any ReadOnlyMailProvider) async throws -> MailThread {
        try Task.checkCancellation()
        guard provider.accountID == message.accountID else { throw MailSyncError.accountMismatch }
        guard let account = executor.state.accounts.first(where: { $0.id == message.accountID && $0.isRemote }) else { throw MailSyncError.accountNotFound }
        guard account.status != .disconnected else { throw MailSyncError.disconnected }
        guard sourceStillAvailable(message) else { throw MailThreadError.sourceUnavailable }
        guard let providerThreadID = message.providerThreadID, !providerThreadID.isEmpty else { throw MailThreadError.unavailable }
        let key = RequestKey(accountID: message.accountID, threadID: message.threadID)
        guard !loading.contains(key) else { throw MailThreadError.alreadyLoading }
        loading.insert(key)
        defer { loading.remove(key) }
        let thread = try await provider.fetchThread(message: message)
        try Task.checkCancellation()
        guard let currentAccount = executor.state.accounts.first(where: { $0.id == account.id }),
              currentAccount.status != .disconnected,
              currentAccount.credentialReference == account.credentialReference else { throw CancellationError() }
        guard sourceStillAvailable(message) else { throw MailThreadError.sourceUnavailable }
        try executor.commitRemoteThread(thread, sourceMessageID: message.id)
        return MailThread(id: message.threadID, messages: executor.state.messages.filter {
            $0.accountID == message.accountID && $0.threadID == message.threadID
        }.sorted { $0.date < $1.date })
    }

    private func sourceStillAvailable(_ source: MailMessage) -> Bool {
        executor.state.messages.contains {
            $0.id == source.id && $0.accountID == source.accountID && $0.providerID == source.providerID &&
            $0.threadID == source.threadID && $0.providerThreadID == source.providerThreadID
        }
    }
}
