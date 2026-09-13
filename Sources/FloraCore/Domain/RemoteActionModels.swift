import Foundation

public enum MailWritePermission: String, Codable, Sendable { case readOnly, userAuthorized }
public enum DraftSyncStatus: String, Codable, Sendable { case localOnly, synced, outcomeUnknown }
public enum DraftDeliveryState: String, Codable, Sendable { case notSent, sending, sent, outcomeUnknown }
public struct DraftAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var size: Int
    public var localRelativePath: String
    /// Digest of the bytes explicitly selected by the user, bound to the preview.
    /// A legacy missing digest requires reselecting the attachment before a write.
    public var contentHash: String?
    public init(id: UUID = UUID(), name: String, mimeType: String, size: Int, localRelativePath: String, contentHash: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.localRelativePath = localRelativePath; self.contentHash = contentHash
    }
}
public enum RemoteMailAction: Codable, Equatable, Sendable {
    case markRead(messageIDs: [UUID], isRead: Bool)
    case flag(messageIDs: [UUID], isFlagged: Bool)
    case archive(messageIDs: [UUID])
    case move(messageIDs: [UUID], destination: MailFolderDescriptor)
    case syncDraft(draftID: UUID)
    case sendDraft(draftID: UUID)
    public var messageIDs: [UUID] {
        switch self { case .markRead(let ids, _), .flag(let ids, _), .archive(let ids), .move(let ids, _): ids; default: [] }
    }
    public var draftID: UUID? { switch self { case .syncDraft(let id), .sendDraft(let id): id; default: nil } }
    public var isSend: Bool { if case .sendDraft = self { true } else { false } }
}
public struct RemoteMailProposal: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let action: RemoteMailAction
    public let explanation: String
    public let origin: ActionOrigin
    let sourceFingerprint: String
    public let undoesRecordID: UUID?
    public var requiresConfirmation: Bool { true }
    public var risk: ActionRisk { action.isSend ? .externalEffect : .reversible }
    init(id: UUID = UUID(), accountID: UUID, action: RemoteMailAction, explanation: String, origin: ActionOrigin, sourceFingerprint: String, undoesRecordID: UUID? = nil) {
        self.id = id; self.accountID = accountID; self.action = action; self.explanation = explanation; self.origin = origin; self.sourceFingerprint = sourceFingerprint; self.undoesRecordID = undoesRecordID
    }
}
public enum RemoteOutcomeResolution: String, Codable, Sendable { case confirmedApplied, confirmedNotApplied }
public enum RemoteActionStatus: String, Codable, Sendable { case prepared, completed, failed, outcomeUnknown }
public struct RemoteUndoState: Codable, Equatable, Sendable {
    public let messageID: UUID
    public let providerID: String
    public let isRead: Bool
    public let isFlagged: Bool
    init(_ message: MailMessage) { messageID = message.id; providerID = message.providerID; isRead = message.isRead; isFlagged = message.isFlagged }
}
public struct RemoteActionRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let proposal: RemoteMailProposal
    public let date: Date
    public var status: RemoteActionStatus
    public var errorMessage: String?
    public var sentProviderMessageID: String?
    public var resolution: RemoteOutcomeResolution?
    public var resolvedAt: Date?
    public var undoState: [RemoteUndoState]?
    public var undoneByActionID: UUID?
    public var canUndo: Bool {
        guard status == .completed, resolution == nil, proposal.undoesRecordID == nil, undoneByActionID == nil,
              let undoState, !undoState.isEmpty else { return false }
        switch proposal.action {
        case .markRead: return Set(undoState.map(\.isRead)).count == 1
        case .flag: return Set(undoState.map(\.isFlagged)).count == 1
        default: return false
        }
    }
    public init(proposal: RemoteMailProposal, date: Date = Date(), status: RemoteActionStatus = .prepared, errorMessage: String? = nil, sentProviderMessageID: String? = nil) {
        id = proposal.id; self.proposal = proposal; self.date = date; self.status = status
        self.errorMessage = errorMessage; self.sentProviderMessageID = sentProviderMessageID
    }
}
public struct RemoteDraftReference: Codable, Equatable, Sendable {
    public let providerDraftID: String
    public let providerMessageID: String?
    public init(providerDraftID: String, providerMessageID: String? = nil) { self.providerDraftID = providerDraftID; self.providerMessageID = providerMessageID }
}
public struct OutgoingAttachment: Sendable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data
    public init(id: UUID, name: String, mimeType: String, data: Data) { self.id = id; self.name = name; self.mimeType = mimeType; self.data = data }
}
public struct OutgoingMail: Sendable {
    public let from: MailAddress
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let bcc: [MailAddress]
    public let subject: String
    public let body: String
    public let attachments: [OutgoingAttachment]
    public let messageID: String
    public let inReplyTo: String?
    public let references: [String]
    public let providerThreadID: String?
    public let rawData: Data
    public let smtpData: Data
}
/// Only the coordinator can construct this capability after validation and a
/// durable write-ahead record. AI providers have no writer or coordinator handle.
public struct AuthorizedRemoteAction: Sendable {
    public let id: UUID
    public let account: MailAccount
    public let action: RemoteMailAction
    public let messages: [MailMessage]
    public let draft: Draft?
    public let outgoing: OutgoingMail?
    init(id: UUID, account: MailAccount, action: RemoteMailAction, messages: [MailMessage], draft: Draft?, outgoing: OutgoingMail?) {
        self.id = id; self.account = account; self.action = action; self.messages = messages; self.draft = draft; self.outgoing = outgoing
    }
}
public struct RemoteActionReceipt: Sendable {
    public let messages: [MailMessage]
    public let removedProviderMessageIDs: [String]
    public let draftReference: RemoteDraftReference?
    public let sentProviderMessageID: String?
    /// Static adapter-authored guidance after an acknowledged action, never raw
    /// server responses. An advisory does not revoke a successful send receipt.
    public let advisories: [String]
    public init(messages: [MailMessage] = [], removedProviderMessageIDs: [String] = [], draftReference: RemoteDraftReference? = nil, sentProviderMessageID: String? = nil, advisories: [String] = []) {
        self.messages = messages; self.removedProviderMessageIDs = removedProviderMessageIDs; self.draftReference = draftReference; self.sentProviderMessageID = sentProviderMessageID; self.advisories = advisories
    }
}
@MainActor
public protocol RemoteMailWriter {
    var accountID: UUID { get }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt
}
public enum RemoteActionError: LocalizedError, Equatable, Sendable {
    case authenticationRequired, permissionDenied, invalidRequest, unsupported, rateLimited, unavailable, outcomeUnknown
    case confirmationRequired, staleProposal, duplicateSend, persistenceFailed, alreadyExecuting
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Reconnect this account with the required mail permissions."
        case .permissionDenied: "Enable and explicitly authorize mail changes for this account in Settings."
        case .invalidRequest: "This mail action contains invalid or unavailable data. Review the message or draft again."
        case .unsupported: "This account does not support the requested mail action."
        case .rateLimited: "The mail service is limiting requests. Review the action and try again later."
        case .unavailable: "The mail service could not be reached before the action began."
        case .outcomeUnknown: "The server may have applied this action, but Flora could not confirm the outcome. Check the account before taking another action. Sending again is blocked to avoid duplicates."
        case .confirmationRequired: "Review and confirm this exact mail action before execution."
        case .staleProposal: "The account, message or draft changed after this preview. Review a new preview."
        case .duplicateSend: "This draft has already been submitted or its delivery outcome is unknown. Check Sent in the account; Flora will not send it again."
        case .persistenceFailed: "Flora could not safely record this action. Check local storage and the account before retrying."
        case .alreadyExecuting: "An action for this account is already running."
        }
    }
}
