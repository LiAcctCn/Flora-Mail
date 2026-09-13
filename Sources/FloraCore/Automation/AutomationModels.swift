import Foundation

public enum AutomationLevel: Int, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case manual = 0, information = 1, suggestion = 2, rules = 3, delegated = 4
    public var id: Int { rawValue }
    public var label: String { title }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var title: String {
        switch self { case .manual: "Manual"; case .information: "Information"; case .suggestion: "Suggestions"; case .rules: "Approved rules"; case .delegated: "Narrow delegation" }
    }
}
public enum AutomationAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case archive, markRead
    public var id: String { rawValue }
    public var title: String { self == .archive ? "Archive" : "Mark read" }
    public func remoteAction(messageID: UUID) -> RemoteMailAction {
        self == .archive ? .archive(messageIDs: [messageID]) : .markRead(messageIDs: [messageID], isRead: true)
    }
    public func localAction(messageID: UUID) -> ActionType {
        self == .archive ? .archive(messageIDs: [messageID]) : .markRead(messageIDs: [messageID], isRead: true)
    }
}
public struct AutomationPreview: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let rule: AutomationRule
    public let accountID: UUID
    public let messageIDs: [UUID]
    public let totalMatchingCount: Int
    public let explanation: String
    let sourceFingerprint: String
}
public struct AutomationGrant: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let accountID: UUID
    public let messageIDs: [UUID]
    public let authorizedAt: Date
    public let expiresAt: Date
    public var consumedAt: Date?
    public var consumedByRunID: UUID?
    public var revokedAt: Date?
    let ruleFingerprint: String
    let sourceFingerprint: String
    public var isConsumed: Bool { consumedAt != nil }
    public var isRevoked: Bool { revokedAt != nil }
}
public enum AutomationRunStatus: String, Codable, Sendable { case running, completed, failed, cancelled, outcomeUnknown }
public struct AutomationRunRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let ruleName: String
    public let grantID: UUID?
    public let accountID: UUID
    public let messageIDs: [UUID]
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: AutomationRunStatus
    public var completedMessageIDs: [UUID]
    public var actionIDs: [UUID]
    public var errorMessage: String?
    let ruleFingerprint: String
    let messageFingerprints: [String: String]
    var activeDispatchID: UUID?
    var activeMessageID: UUID?
}
/// A single bounded dispatch capability. Its initializer is module-internal and
/// its authority is rechecked against the durable run and current rule at execution.
public struct AuthorizedAutomationDispatch: Sendable {
    public let id: UUID
    public let runID: UUID
    public let ruleID: UUID
    public let grantID: UUID?
    public let accountID: UUID
    public let messageID: UUID
    public let action: AutomationAction
    public let explanation: String
}
public struct AutomationDispatchReceipt: Sendable {
    public let actionID: UUID
    public let isRemote: Bool
    public init(actionID: UUID, isRemote: Bool) { self.actionID = actionID; self.isRemote = isRemote }
}
public enum AutomationError: LocalizedError, Equatable, Sendable {
    case invalidScope, levelNotAllowed, ruleUnavailable, stalePreview, expired, delegationConsumed, emptyMatch, alreadyRunning, invalidReceipt, persistenceFailed
    public var errorDescription: String? {
        switch self {
        case .invalidScope: "Choose one account, an exact sender, Inbox, a valid age and at most 50 messages."
        case .levelNotAllowed: "The current automation level does not permit this action."
        case .ruleUnavailable: "This rule is disabled, revoked or no longer available."
        case .stalePreview: "The rule or matching messages changed. Review a new preview."
        case .expired: "This authorization has expired. Review and authorize a new scope."
        case .delegationConsumed: "This one-run authorization was already consumed or revoked. Create a new authorization to run again."
        case .emptyMatch: "No cached messages currently match this scope."
        case .alreadyRunning: "An automation run for this account is already active."
        case .invalidReceipt: "Flora could not verify the result of this automation dispatch. Review action history and the account."
        case .persistenceFailed: "The automation could not be recorded safely. No further actions will run."
        }
    }
}
