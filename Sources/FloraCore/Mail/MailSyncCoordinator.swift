import Foundation

public struct MailSyncSettings: Codable, Equatable, Sendable {
    public var recentDays: Int
    public var maximumMessages: Int
    public var pageSize: Int
    public init(recentDays: Int = 30, maximumMessages: Int = 200, pageSize: Int = 50) {
        self.recentDays = min(max(recentDays, 1), 365)
        self.maximumMessages = min(max(maximumMessages, 1), 2_000)
        self.pageSize = min(max(pageSize, 1), 100)
    }
}

public struct SyncProgress: Sendable {
    public var receivedMessages: Int
    public var pages: Int
    public init(receivedMessages: Int, pages: Int) { self.receivedMessages = receivedMessages; self.pages = pages }
}

public struct SyncResult: Sendable {
    public var receivedMessages: Int
    public var pages: Int
    public var hasMore: Bool
    public init(receivedMessages: Int, pages: Int, hasMore: Bool) { self.receivedMessages = receivedMessages; self.pages = pages; self.hasMore = hasMore }
}

/// Explicit, cancellable sync. Each successful page survives subsequent failure;
/// checkpoints never advance ahead of the corresponding local mail commit.
@MainActor
public final class MailSyncCoordinator {
    private let executor: ActionExecutor
    private let now: () -> Date
    private var activeAccounts: Set<UUID> = []
    public init(executor: ActionExecutor, now: @escaping () -> Date = Date.init) { self.executor = executor; self.now = now }

    public func sync(provider: any ReadOnlyMailProvider, settings: MailSyncSettings = MailSyncSettings(), onProgress: @MainActor (SyncProgress) -> Void = { _ in }) async throws -> SyncResult {
        let accountID = provider.accountID
        guard let account = executor.state.accounts.first(where: { $0.id == accountID && $0.isRemote }) else { throw MailSyncError.accountNotFound }
        guard account.status != .disconnected else { throw MailSyncError.disconnected }
        guard !activeAccounts.contains(accountID) else { throw MailSyncError.alreadySyncing }
        activeAccounts.insert(accountID)
        defer { activeAccounts.remove(accountID) }
        let bounded = MailSyncSettings(recentDays: settings.recentDays, maximumMessages: settings.maximumMessages, pageSize: settings.pageSize)
        var checkpoint = account.syncState.checkpoint
        var received = 0
        var pages = 0
        var hasMore = false
        let since = now().addingTimeInterval(-Double(bounded.recentDays) * 86_400)
        try executor.setAccountSyncStatus(accountID: accountID, status: .syncing)
        do {
            try Task.checkCancellation()
            let folders = try await provider.fetchRemoteFolders()
            try Task.checkCancellation()
            try ensureConnected(accountID)
            try executor.updateRemoteFolders(folders, accountID: accountID)
            repeat {
                try Task.checkCancellation()
                let limit = min(bounded.pageSize, bounded.maximumMessages - received)
                let request = MailSyncRequest(checkpoint: checkpoint, limit: limit, since: since)
                let page = try await provider.fetchPage(request)
                try Task.checkCancellation()
                try ensureConnected(accountID)
                guard page.messages.count <= limit else { throw MailSyncError.malformedResponse }
                guard !page.hasMore || page.checkpoint != checkpoint else { throw MailSyncError.invalidCheckpoint }
                try executor.commitSyncPage(page, accountID: accountID)
                checkpoint = page.checkpoint; received += page.messages.count; pages += 1; hasMore = page.hasMore
                onProgress(SyncProgress(receivedMessages: received, pages: pages))
                // Bound work even if a server yields many empty delta pages.
            } while hasMore && received < bounded.maximumMessages && pages < 100
            try Task.checkCancellation()
            try executor.setAccountSyncStatus(accountID: accountID, status: .connected, lastSuccessfulSync: now())
            return SyncResult(receivedMessages: received, pages: pages, hasMore: hasMore)
        } catch {
            // Errors are mapped to controlled UI text; arbitrary provider bodies
            // and OAuth error descriptions are never stored in normal persistence.
            let cancelled = error is CancellationError || Task.isCancelled
            if executor.state.accounts.first(where: { $0.id == accountID })?.status != .disconnected {
                let normalized = (error as? MailSyncError) ?? (error as? any MailSyncFailure)?.syncError ?? .unavailable
                let status: MailAccountStatus = cancelled ? .connected : (normalized == .authenticationRequired || normalized == .invalidCredentials ? .reauthenticationRequired : .error)
                try executor.setAccountSyncStatus(accountID: accountID, status: status, errorMessage: cancelled ? "Sync cancelled. Already retrieved mail remains available." : normalized.localizedDescription)
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    private func ensureConnected(_ accountID: UUID) throws {
        guard let account = executor.state.accounts.first(where: { $0.id == accountID }) else { throw MailSyncError.accountNotFound }
        guard account.status != .disconnected else { throw MailSyncError.disconnected }
    }
}
