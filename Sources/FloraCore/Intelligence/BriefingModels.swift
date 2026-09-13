import Foundation

public enum MailIntelligenceScope: Equatable, Sendable {
    case account(UUID)
    case demo
    case realAccounts
}
public enum BriefingPriority: Int, Equatable, Sendable { case low, normal, attention, urgent }
public enum BriefingSignalKind: String, Equatable, Sendable {
    case flagged, important, replyRequested, deadline, actionSuggested, unread, update, lowPriority, replySent
}
public enum BriefingProvenance: String, Equatable, Sendable {
    case mailState, textRule, generated
    public var label: String {
        switch self { case .mailState: "Mail status"; case .textRule: "Local text rule"; case .generated: "AI suggestion" }
    }
}
public struct BriefingSignal: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: BriefingSignalKind
    public let title: String
    public let explanation: String
    public let provenance: BriefingProvenance
    public let provider: String?
    public let sourceMessageID: UUID
    public let sourceQuote: String?
    public let dueDate: Date?
    public var label: String { provider.map { "\($0) suggestion" } ?? provenance.label }
    init(messageID: UUID, kind: BriefingSignalKind, title: String, explanation: String, provenance: BriefingProvenance,
         provider: String? = nil, sourceMessageID: UUID? = nil, sourceQuote: String? = nil, dueDate: Date? = nil) {
        let identity = "\(kind.rawValue):\(provenance.rawValue):\(provider ?? ""):\(title):\(sourceQuote ?? "")"
        id = StableMailIdentity.message(accountID: messageID, providerID: "briefing-signal:" + identity).uuidString
        self.kind = kind; self.title = title; self.explanation = explanation; self.provenance = provenance
        self.provider = provider; self.sourceMessageID = sourceMessageID ?? messageID; self.sourceQuote = sourceQuote; self.dueDate = dueDate
    }
}
public struct BriefingItem: Identifiable, Equatable, Sendable {
    public let message: MailMessage
    public let priority: BriefingPriority
    public let signals: [BriefingSignal]
    public let summary: MessageSummary?
    public var id: UUID { message.id }
    public var messageID: UUID { message.id }
    public var accountID: UUID { message.accountID }
    public var headline: String { signals.first?.title ?? message.subject }
    public var explanation: String { signals.first?.explanation ?? "Open the original email to review this update." }
    public var needsReply: Bool { signals.contains { $0.kind == .replyRequested } }
    public var deadline: Date? { signals.first { $0.kind == .deadline }?.dueDate }
}
public struct DailyBriefingSnapshot: Equatable, Sendable {
    public let scope: MailIntelligenceScope
    public let generatedAt: Date
    public let needsAttention: [BriefingItem]
    public let updates: [BriefingItem]
    public let lowPriority: [BriefingItem]
    public let availableInboxCount: Int
    public let consideredMessageCount: Int
    public var isTruncated: Bool { consideredMessageCount < availableInboxCount }
    public var replyNeededCount: Int { needsAttention.filter(\.needsReply).count }
    public var deadlineCount: Int { needsAttention.filter { $0.signals.contains { $0.kind == .deadline } }.count }
}
