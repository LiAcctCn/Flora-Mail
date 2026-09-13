import AppKit
import Foundation
import Observation
import FloraCore

/// Account workflows coordinate authentication and sync; views receive only
/// persisted metadata and human-readable progress, never token values.
@MainActor @Observable
final class AccountController {
    private let executor: ActionExecutor
    private let credentials: any CredentialStore
    private let coordinator: MailSyncCoordinator
    private let threadService: MailThreadService
    private let remoteActions: RemoteActionCoordinator
    private let attachments: AttachmentStorage
    private let storageAvailable: Bool
    private let providerOverride: (@MainActor (MailAccount) throws -> any ReadOnlyMailProvider)?
    var onChange: (@MainActor () -> Void)?
    var onConnected: (@MainActor (UUID) -> Void)?
    private(set) var writingAccounts: Set<UUID> = []
    private(set) var connecting = false
    private(set) var connectionMessage: String?
    private(set) var connectionError: String?
    private(set) var syncProgress: [UUID: String] = [:]
    private(set) var moreAvailable: Set<UUID> = []
    private(set) var downloading: Set<UUID> = []
    private(set) var attachmentErrors: [UUID: String] = [:]
    private(set) var loadingThreads: Set<UUID> = []
    private(set) var threadErrors: [UUID: String] = [:]
    private(set) var imagePreviews: [UUID: Data] = [:]
    private var threadTasks: [UUID: Task<Void, Never>] = [:]
    private var threadAccountIDs: [UUID: UUID] = [:]
    private var connectionTask: Task<Bool, Never>?
    private var browser: OAuthBrowserSession?
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadAccountIDs: [UUID: UUID] = [:]
    private var disconnectingIDs: Set<UUID> = []

    init(executor: ActionExecutor, storageURL: URL, storageAvailable: Bool,
         credentials: any CredentialStore = KeychainCredentialStore(),
         providerOverride: (@MainActor (MailAccount) throws -> any ReadOnlyMailProvider)? = nil) {
        self.executor = executor; self.credentials = credentials; self.storageAvailable = storageAvailable
        self.providerOverride = providerOverride
        coordinator = MailSyncCoordinator(executor: executor)
        threadService = MailThreadService(executor: executor)
        remoteActions = RemoteActionCoordinator(executor: executor)
        attachments = AttachmentStorage(root: storageURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true))
    }

    func clearConnectionError() { connectionError = nil }
    func cancelConnection() { guard connecting else { return }; connectionTask?.cancel(); browser?.cancel(); connectionMessage = "Sign-in cancelled." }

    func connectOAuth(provider: MailProviderType, clientID: String, existingAccount: MailAccount? = nil, allowWrites: Bool = false) async -> Bool {
        guard !connecting, existingAccount.map({ !disconnectingIDs.contains($0.id) && !writingAccounts.contains($0.id) }) ?? true else { return false }
        connecting = true; connectionError = nil; connectionMessage = "Preparing secure browser sign-in…"
        let task = Task { @MainActor in
            let reference = MailCredentialReference(id: "account-\(UUID().uuidString)")
            var retained = false
            let browser = OAuthBrowserSession(); self.browser = browser
            defer { self.browser = nil; browser.cancel(); connecting = false }
            do {
                guard storageAvailable else { throw AccountConnectionError.storageUnavailable }
                if let existingAccount { await stopRequests(for: existingAccount.id) }
                try Task.checkCancellation()
                let accessLevel: OAuthAccessLevel = allowWrites ? .readWrite : (existingAccount?.oauthAccessLevel ?? .readOnly)
                let configuration = try OAuthClientConfiguration(provider: provider, clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), accessLevel: accessLevel).validated()
                let service = OAuthService(credentials: credentials)
                let redirect = try await browser.prepare(callbackHost: provider == .microsoft ? "localhost" : "127.0.0.1")
                let request = try service.makeAuthorizationRequest(configuration: configuration, redirectURI: redirect)
                connectionMessage = accessLevel == .readWrite ? "Complete sign-in in your browser to authorize mail reading, changes and sending." : "Complete sign-in in your browser. Flora requests read-only mail access."
                let callback = try await browser.authenticate(authorizationURL: request.authorizationURL)
                connectionMessage = "Checking account identity…"
                try await service.exchange(callbackURL: callback, request: request, credentialReference: reference)
                var provisional = MailAccount(id: existingAccount?.id ?? UUID(), name: provider.title,
                    address: MailAddress(name: "", email: ""), provider: provider.title, providerType: provider,
                    credentialReference: reference, oauthClientID: configuration.clientID)
                provisional.oauthAccessLevel = accessLevel
                let remote = try makeProvider(provisional)
                guard var account = try await remote.fetchAccounts().first else { throw AccountConnectionError.invalidAccount }
                try Task.checkCancellation()
                account.credentialReference = reference; account.oauthClientID = configuration.clientID
                account.oauthAccessLevel = accessLevel
                try validateConnection(account, replacing: existingAccount)
                if let existingAccount { account.syncState = executor.state.accounts.first { $0.id == existingAccount.id }?.syncState ?? existingAccount.syncState }
                account.writePermission = allowWrites ? .userAuthorized : .readOnly
                account.writeAuthorizedAt = allowWrites ? Date() : nil
                account.status = .connected; account.syncState.errorMessage = nil
                try executor.upsertAccount(account); retained = true; onChange?()
                if let old = existingAccount?.credentialReference {
                    do { try await credentials.delete(reference: old) }
                    catch { connectionError = "Connected, but the previous unused Keychain credential could not be removed. Retry cleanup in Keychain Access." }
                }
                connectionMessage = "Connected. Retrieving recent mail…"
                connecting = false
                onConnected?(account.id)
                syncNow(account.id)
                return true
            } catch {
                if error is CancellationError || Task.isCancelled { connectionMessage = "Sign-in cancelled." }
                else { connectionError = error.localizedDescription; connectionMessage = nil }
                if !retained {
                    do { try await credentials.delete(reference: reference) }
                    catch { connectionError = (connectionError ?? "Sign-in ended.") + " An unused Keychain credential could not be removed; review Flora entries in Keychain Access." }
                }
                return false
            }
        }
        connectionTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        connectionTask = nil
        return result
    }

    func connectICloud(email: String, appSpecificPassword: String, existingAccount: MailAccount? = nil, allowWrites: Bool = false) async -> Bool {
        guard !connecting, existingAccount.map({ !disconnectingIDs.contains($0.id) && !writingAccounts.contains($0.id) }) ?? true else { return false }
        connecting = true; connectionError = nil; connectionMessage = "Connecting securely to iCloud Mail…"
        let task = Task { @MainActor in
            let reference = MailCredentialReference(id: "account-\(UUID().uuidString)")
            var retained = false
            defer { connecting = false }
            do {
                guard storageAvailable else { throw AccountConnectionError.storageUnavailable }
                if let existingAccount { await stopRequests(for: existingAccount.id) }
                try Task.checkCancellation()
                let credential = try IMAPCredential(username: email, appSpecificPassword: appSpecificPassword).validated()
                let address = credential.username.lowercased()
                let provisional = MailAccount(id: existingAccount?.id ?? UUID(), name: "iCloud Mail",
                    address: MailAddress(name: address, email: address), provider: "iCloud", providerType: .iCloud,
                    providerAccountID: address, credentialReference: reference)
                try validateConnection(provisional, replacing: existingAccount)
                try await credentials.write(JSONEncoder().encode(credential), reference: reference)
                let remote = try makeProvider(provisional)
                guard var account = try await remote.fetchAccounts().first else { throw AccountConnectionError.invalidAccount }
                try Task.checkCancellation()
                try validateConnection(account, replacing: existingAccount)
                if let existingAccount { account.syncState = executor.state.accounts.first { $0.id == existingAccount.id }?.syncState ?? existingAccount.syncState }
                account.writePermission = allowWrites ? .userAuthorized : .readOnly
                account.writeAuthorizedAt = allowWrites ? Date() : nil
                account.status = .connected; account.syncState.errorMessage = nil
                try executor.upsertAccount(account); retained = true; onChange?()
                if let old = existingAccount?.credentialReference {
                    do { try await credentials.delete(reference: old) }
                    catch { connectionError = "Connected, but the previous unused Keychain credential could not be removed. Retry cleanup in Keychain Access." }
                }
                connectionMessage = "Connected. Retrieving recent mail…"
                connecting = false
                onConnected?(account.id)
                syncNow(account.id)
                return true
            } catch {
                if error is CancellationError || Task.isCancelled { connectionMessage = "Sign-in cancelled." }
                else { connectionError = error.localizedDescription; connectionMessage = nil }
                if !retained {
                    do { try await credentials.delete(reference: reference) }
                    catch { connectionError = (connectionError ?? "Sign-in ended.") + " An unused Keychain credential could not be removed; review Flora entries in Keychain Access." }
                }
                return false
            }
        }
        connectionTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        connectionTask = nil
        return result
    }

    private func validateConnection(_ account: MailAccount, replacing old: MailAccount?) throws {
        guard !account.address.email.isEmpty, account.providerType != .demo else { throw AccountConnectionError.invalidAccount }
        if let old {
            guard old.id == account.id, old.providerType == account.providerType,
                  (old.providerAccountID ?? old.address.email).lowercased() == (account.providerAccountID ?? account.address.email).lowercased() else {
                throw AccountConnectionError.wrongAccount
            }
        } else if executor.state.accounts.contains(where: {
            $0.providerType == account.providerType && ($0.providerAccountID ?? $0.address.email).lowercased() == (account.providerAccountID ?? account.address.email).lowercased()
        }) { throw AccountConnectionError.alreadyConnected }
    }

    func makeProvider(_ account: MailAccount) throws -> any ReadOnlyMailProvider {
        if let providerOverride { return try providerOverride(account) }
        guard let reference = account.credentialReference else { throw MailSyncError.disconnected }
        switch account.providerType {
        case .gmail, .microsoft:
            let configuration = try OAuthClientConfiguration(provider: account.providerType, clientID: account.oauthClientID ?? "", accessLevel: account.oauthAccessLevel).validated()
            if account.providerType == .gmail {
                return GmailMailProvider(accountID: account.id, credentialReference: reference, configuration: configuration, credentials: credentials)
            }
            return MicrosoftMailProvider(accountID: account.id, credentialReference: reference, configuration: configuration, credentials: credentials)
        case .iCloud: return ICloudMailProvider(account: account, credentials: credentials)
        case .demo: throw MailSyncError.accountMismatch
        }
    }

    func propose(_ action: RemoteMailAction, accountID: UUID, explanation: String, origin: ActionOrigin = .user) throws -> RemoteMailProposal {
        guard storageAvailable else { throw AccountConnectionError.storageUnavailable }
        guard !connecting, !writingAccounts.contains(accountID), !isDisconnecting(accountID), !isSyncing(accountID) else { throw AccountActionError.busy }
        return try remoteActions.propose(action, accountID: accountID, explanation: explanation, origin: origin)
    }

    @discardableResult
    func execute(_ proposal: RemoteMailProposal) async throws -> RemoteActionRecord {
        guard storageAvailable else { throw AccountConnectionError.storageUnavailable }
        guard !connecting, !writingAccounts.contains(proposal.accountID), !isDisconnecting(proposal.accountID) else { throw AccountActionError.busy }
        writingAccounts.insert(proposal.accountID)
        defer { writingAccounts.remove(proposal.accountID); onChange?() }
        await stopRequests(for: proposal.accountID)
        try Task.checkCancellation()
        guard let account = executor.state.accounts.first(where: { $0.id == proposal.accountID }) else { throw MailActionError.accountNotFound }
        let writer: any RemoteMailWriter
        if account.providerType == .iCloud {
            writer = ICloudMailWriter(account: account, credentials: credentials)
        } else {
            guard let adapter = try makeProvider(account) as? any RemoteMailWriter else { throw MailActionError.readOnlyAccount }
            writer = adapter
        }
        let payloads: [OutgoingAttachment]
        switch proposal.action {
        case .syncDraft(let id), .sendDraft(let id):
            guard let draft = executor.state.drafts.first(where: { $0.id == id && $0.accountID == account.id }) else { throw MailActionError.draftNotFound }
            payloads = try await attachments.outgoingPayloads(for: draft)
        default: payloads = []
        }
        return try await remoteActions.execute(proposal, confirmed: true, writer: writer, attachments: payloads)
    }

    func disableMailboxActions(_ accountID: UUID) {
        guard !writingAccounts.contains(accountID), var account = executor.state.accounts.first(where: { $0.id == accountID && $0.isRemote }) else { return }
        account.writePermission = .readOnly; account.writeAuthorizedAt = nil
        do { try executor.updateAccount(account); onChange?() }
        catch { connectionError = "The permission change could not be saved. Restore local storage access and retry." }
    }

    func authorizeExistingMailboxAccess(_ accountID: UUID) {
        guard !writingAccounts.contains(accountID), !connecting, !isDisconnecting(accountID),
              var account = executor.state.accounts.first(where: { $0.id == accountID && $0.isRemote }),
              account.credentialReference != nil, account.status != .disconnected, account.status != .reauthenticationRequired,
              account.providerType == .iCloud || account.oauthAccessLevel == .readWrite else { return }
        account.writePermission = .userAuthorized; account.writeAuthorizedAt = Date()
        do { try executor.updateAccount(account); onChange?() }
        catch { connectionError = "The permission could not be saved. Restore local storage access and retry." }
    }

    func proposeUndo(recordID: UUID) throws -> RemoteMailProposal {
        try remoteActions.proposeUndo(recordID: recordID)
    }

    func resolveUnknown(recordID: UUID, resolution: RemoteOutcomeResolution) throws {
        _ = try remoteActions.resolveUnknown(recordID: recordID, resolution: resolution, confirmed: true)
        onChange?()
    }

    func importAttachment(_ url: URL, draft: Draft) async throws -> DraftAttachment {
        guard storageAvailable, let accountID = draft.accountID, executor.state.accounts.contains(where: { $0.id == accountID }) else { throw AccountConnectionError.storageUnavailable }
        guard draft.attachments.count < 10 else { throw AttachmentStorageError.outgoingTooLarge }
        let attachment = try await attachments.importForDraft(url, accountID: accountID, draftID: draft.id)
        guard draft.attachments.reduce(attachment.size, { $0 + max(0, $1.size) }) <= AttachmentStorage.maximumOutgoingTotalBytes else { throw AttachmentStorageError.outgoingTooLarge }
        return attachment
    }

    func syncNow(_ accountID: UUID) {
        guard !connecting, !writingAccounts.contains(accountID), !disconnectingIDs.contains(accountID), syncTasks[accountID] == nil, let account = executor.state.accounts.first(where: { $0.id == accountID }),
              account.isRemote, account.credentialReference != nil, account.status != .disconnected else { return }
        syncProgress[accountID] = "Connecting…"
        syncTasks[accountID] = Task { @MainActor in
            defer { syncTasks[accountID] = nil; syncProgress[accountID] = nil; onChange?() }
            do {
                let provider = try makeProvider(account)
                let result = try await coordinator.sync(provider: provider, settings: executor.state.preferences.mailSyncSettings) { [weak self] progress in
                    self?.syncProgress[accountID] = "Syncing \(progress.receivedMessages) messages…"
                    self?.onChange?()
                }
                if result.hasMore { moreAvailable.insert(accountID) } else { moreAvailable.remove(accountID) }
            } catch {
                // The coordinator persists controlled error/recovery state for
                // provider failures; errors before it starts need the same UI.
                if !(error is CancellationError), !Task.isCancelled,
                   executor.state.accounts.first(where: { $0.id == accountID })?.status != .error,
                   executor.state.accounts.first(where: { $0.id == accountID })?.status != .reauthenticationRequired {
                    let failure = (error as? MailSyncError) ?? (error as? any MailSyncFailure)?.syncError ?? .unavailable
                    let status: MailAccountStatus = failure == .authenticationRequired || failure == .invalidCredentials ? .reauthenticationRequired : .error
                    do { try executor.setAccountSyncStatus(accountID: accountID, status: status, errorMessage: failure.localizedDescription) }
                    catch { connectionError = "Local storage could not save the sync status. Cached mail is preserved; restore storage access and retry." }
                }
            }
        }
    }
    func isDisconnecting(_ accountID: UUID) -> Bool { disconnectingIDs.contains(accountID) }
    func isSyncing(_ accountID: UUID) -> Bool { syncTasks[accountID] != nil }
    func cancelSync(_ accountID: UUID) { syncTasks[accountID]?.cancel() }
    private func stopRequests(for accountID: UUID) async {
        let sync = syncTasks[accountID]
        let downloads = downloadAccountIDs.filter { $0.value == accountID }.keys.compactMap { downloadTasks[$0] }
        let threads = threadAccountIDs.filter { $0.value == accountID }.keys.compactMap { threadTasks[$0] }
        sync?.cancel()
        for task in threads { task.cancel() }
        for task in downloads { task.cancel() }
        await sync?.value
        for task in downloads { await task.value }
        for task in threads { await task.value }
    }
    func disconnect(_ accountID: UUID) async {
        guard !connecting, !writingAccounts.contains(accountID), !disconnectingIDs.contains(accountID) else { return }
        disconnectingIDs.insert(accountID)
        defer { disconnectingIDs.remove(accountID) }
        await stopRequests(for: accountID)
        // Sync may have committed a page before cancellation. Preserve its new
        // checkpoint rather than rewriting a snapshot captured before await.
        guard var account = executor.state.accounts.first(where: { $0.id == accountID && $0.isRemote }) else { return }
        do {
            if let reference = account.credentialReference { try await credentials.delete(reference: reference) }
            account.credentialReference = nil; account.status = .disconnected; account.syncState.errorMessage = nil
            try executor.updateAccount(account); onChange?()
        } catch { connectionError = "Could not disconnect securely. Retry from Accounts settings." }
    }
    func restartRecentSync(_ accountID: UUID) {
        guard !connecting, !writingAccounts.contains(accountID), !disconnectingIDs.contains(accountID), syncTasks[accountID] == nil,
              var account = executor.state.accounts.first(where: { $0.id == accountID }), account.credentialReference != nil else { return }
        do {
            account.syncState.checkpoint = nil; account.syncState.errorMessage = nil
            try executor.updateAccount(account); onChange?(); syncNow(accountID)
        } catch { connectionError = "The sync position could not be reset. Existing mail is preserved." }
    }

    func download(_ attachment: MailAttachment, message: MailMessage) {
        guard !connecting, !writingAccounts.contains(message.accountID), !disconnectingIDs.contains(message.accountID), downloadTasks[attachment.id] == nil else { return }
        downloading.insert(attachment.id); downloadAccountIDs[attachment.id] = message.accountID; attachmentErrors[attachment.id] = nil
        downloadTasks[attachment.id] = Task { @MainActor in
            defer { downloading.remove(attachment.id); downloadTasks[attachment.id] = nil; downloadAccountIDs[attachment.id] = nil; onChange?() }
            do {
                guard let account = executor.state.accounts.first(where: { $0.id == message.accountID }), account.status != .disconnected else { throw MailSyncError.disconnected }
                guard attachment.size <= AttachmentStorage.maximumBytes else { throw AttachmentStorageError.tooLarge }
                let provider = try makeProvider(account)
                let data = try await provider.downloadAttachment(message: message, attachment: attachment)
                try Task.checkCancellation()
                guard executor.state.accounts.first(where: { $0.id == account.id })?.credentialReference == account.credentialReference else { throw CancellationError() }
                let relative = try await attachments.save(data, accountID: account.id, messageID: message.id, attachmentID: attachment.id, fileName: attachment.name)
                try Task.checkCancellation()
                try executor.markAttachmentDownloaded(messageID: message.id, attachmentID: attachment.id, relativePath: relative)
            } catch is CancellationError {} catch { attachmentErrors[attachment.id] = error.localizedDescription }
        }
    }
    func loadConversation(_ message: MailMessage) {
        guard !connecting, !writingAccounts.contains(message.accountID), !isDisconnecting(message.accountID), threadTasks[message.id] == nil,
              let account = executor.state.accounts.first(where: { $0.id == message.accountID }), account.credentialReference != nil else { return }
        loadingThreads.insert(message.id); threadAccountIDs[message.id] = message.accountID; threadErrors[message.id] = nil
        threadTasks[message.id] = Task { @MainActor in
            defer { loadingThreads.remove(message.id); threadTasks[message.id] = nil; threadAccountIDs[message.id] = nil; onChange?() }
            do { _ = try await threadService.load(message: message, provider: makeProvider(account)) }
            catch is CancellationError {} catch { threadErrors[message.id] = error.localizedDescription }
        }
    }
    func cancelConversation(_ id: UUID) { threadTasks[id]?.cancel() }
    func previewImage(_ attachment: MailAttachment) async {
        guard let path = attachment.localRelativePath, attachment.mimeType.lowercased().hasPrefix("image/") else { return }
        do {
            let png = try await attachments.imagePreview(path)
            if imagePreviews.count >= 16 { imagePreviews = [:] }
            imagePreviews[attachment.id] = png
        } catch { attachmentErrors[attachment.id] = error.localizedDescription }
    }

    func cancelDownload(_ id: UUID) { downloadTasks[id]?.cancel() }
    func reveal(_ attachment: MailAttachment) async {
        guard let relative = attachment.localRelativePath else { return }
        do { let file = try await attachments.existingFile(relative); NSWorkspace.shared.activateFileViewerSelecting([file]) }
        catch { attachmentErrors[attachment.id] = error.localizedDescription }
    }
}

enum AccountActionError: LocalizedError {
    case busy, folderUnavailable, draftSaveFailed
    var errorDescription: String? {
        switch self {
        case .busy: "Another account operation is in progress. Wait for it to finish before continuing."
        case .folderUnavailable: "This destination is not cached yet. Sync the account and choose a folder again."
        case .draftSaveFailed: "The draft could not be saved locally. Your text remains in the composer. Restore storage access and retry."
        }
    }
}
