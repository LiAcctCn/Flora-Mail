import CryptoKit
import Foundation

/// Separate from the Demo executor and from AI reasoning. An immutable preview
/// must be reviewed explicitly; its durable journal is committed before network IO.
@MainActor
public final class RemoteActionCoordinator {
    private let executor: ActionExecutor
    private var executingAccounts: Set<UUID> = []
    public init(executor: ActionExecutor) { self.executor = executor }

    public func propose(_ action: RemoteMailAction, accountID: UUID, explanation: String, origin: ActionOrigin = .user) throws -> RemoteMailProposal {
        let context = try validate(action, accountID: accountID, origin: origin)
        return RemoteMailProposal(accountID: accountID, action: action, explanation: explanation, origin: origin, sourceFingerprint: try fingerprint(context))
    }

    @discardableResult
    public func execute(_ proposal: RemoteMailProposal, confirmed: Bool = false, writer: any RemoteMailWriter, attachments: [OutgoingAttachment] = []) async throws -> RemoteActionRecord {
        try await executeApproved(proposal, confirmed: confirmed, writer: writer, attachments: attachments, automation: nil)
    }

    @discardableResult
    public func executeAutomation(_ dispatch: AuthorizedAutomationDispatch, writer: any RemoteMailWriter) async throws -> RemoteActionRecord {
        try AutomationPolicy.validateDispatch(dispatch, state: executor.state, now: Date())
        let action = dispatch.action.remoteAction(messageID: dispatch.messageID)
        let context = try validate(action, accountID: dispatch.accountID, origin: .automation, automation: dispatch)
        let proposal = RemoteMailProposal(id: dispatch.id, accountID: dispatch.accountID, action: action, explanation: dispatch.explanation, origin: .automation, sourceFingerprint: try fingerprint(context))
        return try await executeApproved(proposal, confirmed: false, writer: writer, attachments: [], automation: dispatch)
    }

    private func executeApproved(_ proposal: RemoteMailProposal, confirmed: Bool, writer: any RemoteMailWriter, attachments: [OutgoingAttachment], automation: AuthorizedAutomationDispatch?) async throws -> RemoteActionRecord {
        guard confirmed || automation != nil else { throw RemoteActionError.confirmationRequired }
        guard writer.accountID == proposal.accountID else { throw RemoteActionError.invalidRequest }
        guard !executingAccounts.contains(proposal.accountID) else { throw RemoteActionError.alreadyExecuting }
        let context = try validate(proposal.action, accountID: proposal.accountID, origin: proposal.origin, automation: automation)
        guard try fingerprint(context) == proposal.sourceFingerprint else { throw RemoteActionError.staleProposal }
        if let originalID = proposal.undoesRecordID {
            let (original, inverse) = try validateUndo(originalID)
            guard inverse == proposal.action, original.proposal.accountID == proposal.accountID else { throw RemoteActionError.invalidRequest }
        }
        try Task.checkCancellation()
        let outgoing: OutgoingMail?
        if let draft = context.draft {
            outgoing = try OutgoingMIMEComposer.compose(account: context.account, draft: draft, source: context.messages.first, attachments: attachments, allowEmptyRecipients: !proposal.action.isSend)
        } else {
            guard attachments.isEmpty else { throw RemoteActionError.invalidRequest }; outgoing = nil
        }
        let request = AuthorizedRemoteAction(id: proposal.id, account: context.account, action: proposal.action, messages: context.messages, draft: context.draft, outgoing: outgoing)
        executingAccounts.insert(proposal.accountID)
        defer { executingAccounts.remove(proposal.accountID) }
        // If this save fails, the writer is never called.
        try executor.beginRemoteAction(proposal)
        let receipt: RemoteActionReceipt
        do { receipt = try await writer.execute(request) }
        catch {
            // Once handed to a writer, unexpected errors (including cancellation)
            // are ambiguous unless that adapter explicitly guarantees no effect.
            let failure = error as? RemoteActionError ?? .outcomeUnknown
            do { try executor.failRemoteAction(proposal.id, error: failure) }
            catch { throw RemoteActionError.persistenceFailed }
            throw failure
        }
        do { return try executor.completeRemoteAction(request, receipt: receipt) }
        catch {
            // The remote acknowledgement cannot be undone by a failed local save.
            // A durable prepared record remains a restart-safe duplicate barrier.
            try? executor.failRemoteAction(proposal.id, error: .outcomeUnknown)
            throw error is MailSyncError ? RemoteActionError.outcomeUnknown : RemoteActionError.persistenceFailed
        }
    }

    public func proposeUndo(recordID: UUID) throws -> RemoteMailProposal {
        let (record, inverse) = try validateUndo(recordID)
        let preview = try propose(inverse, accountID: record.proposal.accountID, explanation: "Undo the previously confirmed read or flag change.")
        return RemoteMailProposal(accountID: preview.accountID, action: preview.action, explanation: preview.explanation, origin: .user, sourceFingerprint: preview.sourceFingerprint, undoesRecordID: recordID)
    }

    private func validateUndo(_ recordID: UUID) throws -> (RemoteActionRecord, RemoteMailAction) {
        guard let record = executor.state.remoteActionHistory.first(where: { $0.id == recordID }), record.canUndo,
              let previous = record.undoState, let first = previous.first else { throw RemoteActionError.unsupported }
        for old in previous {
            guard let current = executor.state.messages.first(where: { $0.id == old.messageID && $0.accountID == record.proposal.accountID && $0.providerID == old.providerID }) else { throw RemoteActionError.staleProposal }
            switch record.proposal.action {
            case .markRead(_, let value): guard current.isRead == value else { throw RemoteActionError.staleProposal }
            case .flag(_, let value): guard current.isFlagged == value else { throw RemoteActionError.staleProposal }
            default: throw RemoteActionError.unsupported
            }
        }
        switch record.proposal.action {
        case .markRead: return (record, .markRead(messageIDs: previous.map(\.messageID), isRead: first.isRead))
        case .flag: return (record, .flag(messageIDs: previous.map(\.messageID), isFlagged: first.isFlagged))
        default: throw RemoteActionError.unsupported
        }
    }

    /// Recovery is explicitly attributed to a user's observation of the server,
    /// rather than represented as a provider acknowledgement or an Undo.
    @discardableResult
    public func resolveUnknown(recordID: UUID, resolution: RemoteOutcomeResolution, confirmed: Bool = false) throws -> RemoteActionRecord {
        guard confirmed else { throw RemoteActionError.confirmationRequired }
        guard let record = executor.state.remoteActionHistory.first(where: { $0.id == recordID }) else { throw RemoteActionError.invalidRequest }
        guard !executingAccounts.contains(record.proposal.accountID) else { throw RemoteActionError.alreadyExecuting }
        return try executor.resolveRemoteOutcome(recordID, resolution: resolution)
    }

    private struct Context: Encodable {
        var account: MailAccount
        var action: RemoteMailAction
        var messages: [MailMessage]
        var draft: Draft?
    }
    private func validate(_ action: RemoteMailAction, accountID: UUID, origin: ActionOrigin, automation: AuthorizedAutomationDispatch? = nil) throws -> Context {
        if origin == .ai, executor.state.preferences.automationLevel < .suggestion || executor.state.preferences.researchMode == .traditional { throw MailActionError.assistanceDisabled }
        if origin == .automation {
            guard let automation, automation.accountID == accountID, action == automation.action.remoteAction(messageID: automation.messageID) else { throw RemoteActionError.permissionDenied }
            try AutomationPolicy.validateDispatch(automation, state: executor.state, now: Date())
        }
        guard let account = executor.state.accounts.first(where: { $0.id == accountID && $0.isRemote }) else { throw RemoteActionError.invalidRequest }
        guard account.writePermission == .userAuthorized, let granted = account.writeAuthorizedAt, granted <= Date() else { throw RemoteActionError.permissionDenied }
        guard account.credentialReference != nil, account.status != .disconnected, account.status != .reauthenticationRequired else { throw RemoteActionError.authenticationRequired }
        guard account.providerType == .iCloud || account.oauthAccessLevel == .readWrite else { throw RemoteActionError.authenticationRequired }
        guard !executor.state.remoteActionHistory.contains(where: { $0.proposal.accountID == accountID && $0.status == .prepared }) else { throw RemoteActionError.alreadyExecuting }
        if executor.state.remoteActionHistory.contains(where: { $0.proposal.accountID == accountID && $0.proposal.action == action && $0.status == .outcomeUnknown }) { throw RemoteActionError.outcomeUnknown }
        var messages: [MailMessage] = [], draft: Draft?
        if let draftID = action.draftID {
            guard let saved = executor.state.drafts.first(where: { $0.id == draftID }), saved.accountID == accountID else { throw RemoteActionError.invalidRequest }
            guard saved.draftSyncStatus != .outcomeUnknown,
                  !executor.state.remoteActionHistory.contains(where: { $0.proposal.accountID == accountID && $0.proposal.action.draftID == draftID && $0.status == .outcomeUnknown }) else { throw RemoteActionError.outcomeUnknown }
            if executor.state.remoteActionHistory.contains(where: { $0.proposal.accountID == accountID && $0.proposal.action == .sendDraft(draftID: draftID) && $0.status == .completed }) { throw RemoteActionError.duplicateSend }
            if action.isSend {
                guard saved.deliveryState == .notSent,
                      !executor.state.remoteActionHistory.contains(where: { $0.proposal.accountID == accountID && $0.proposal.action == .sendDraft(draftID: draftID) && $0.status != .failed }) else { throw RemoteActionError.duplicateSend }
            } else {
                guard saved.deliveryState == .notSent, saved.draftSyncStatus != .outcomeUnknown else { throw RemoteActionError.outcomeUnknown }
            }
            if let sourceID = saved.replyToMessageID {
                guard let source = executor.state.messages.first(where: { $0.id == sourceID && $0.accountID == accountID }) else { throw RemoteActionError.invalidRequest }
                messages = [source]
            }
            draft = saved
        } else {
            let ids = action.messageIDs
            guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count else { throw RemoteActionError.invalidRequest }
            for id in ids {
                guard let message = executor.state.messages.first(where: { $0.id == id && $0.accountID == accountID }), !message.providerID.isEmpty else { throw RemoteActionError.invalidRequest }
                messages.append(message)
            }
            if case .move(_, let destination) = action {
                guard destination.accountID == accountID, executor.state.remoteFolders.contains(destination) else { throw RemoteActionError.invalidRequest }
            }
            if case .archive = action, account.providerType != .gmail {
                guard executor.state.remoteFolders.contains(where: { $0.accountID == accountID && $0.role == .archive }) else { throw RemoteActionError.invalidRequest }
            }
        }
        return Context(account: account, action: action, messages: messages, draft: draft)
    }
    private func fingerprint(_ context: Context) throws -> String {
        var stable = context
        // Sync progress does not change the reviewed permission or mail content.
        stable.account.status = .connected; stable.account.syncState = MailSyncState()
        stable.draft?.updatedAt = .distantPast
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
    }
}
