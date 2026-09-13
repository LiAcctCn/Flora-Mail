import Foundation

public struct CategoryLearningEvidence: Equatable, Sendable {
    public let actionID: UUID
    public let messageID: UUID
    public let accountID: UUID
    public let categoryID: UUID
    public let confirmedAt: Date
    public let acceptedAISuggestion: Bool
}

public struct LearnedCategorySuggestion: Equatable, Sendable {
    public let classification: ClassificationSuggestion
    public let accountID: UUID
    public let senderEmail: String
    public let evidence: [CategoryLearningEvidence]
    public var supportingActionIDs: [UUID] { evidence.map(\.actionID) }
    public var supportingMessageIDs: [UUID] { evidence.map(\.messageID) }
    public var supportCount: Int { evidence.count }
    public var latestConfirmationAt: Date? { evidence.first?.confirmedAt }
    public var explanation: String { classification.explanation }
}

/// A transparent local preference rule, not model training. It reads confirmed
/// history only and has no executor, repository or provider reference.
public struct CategoryPreferenceLearningService: Sendable {
    public static let minimumExamples = 2
    public init() {}

    public func suggestion(for message: MailMessage, in snapshot: AppSnapshot, enabled: Bool) -> LearnedCategorySuggestion? {
        guard enabled, message.categoryID == nil,
              snapshot.accounts.contains(where: { $0.id == message.accountID }),
              let current = snapshot.messages.first(where: { $0.id == message.id }), current.accountID == message.accountID,
              current.categoryID == nil, Self.sender(current.from.email) == Self.sender(message.from.email),
              let sender = Self.sender(message.from.email) else { return nil }
        let messages = snapshot.messages.filter { $0.accountID == message.accountID && Self.sender($0.from.email) == sender }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let categories = Dictionary(snapshot.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latest: [UUID: Choice] = [:]
        // History is append-only; date plus position gives deterministic ordering
        // even when several actions share a timestamp or a fixture is unsorted.
        let ordered = snapshot.history.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset > $1.offset : $0.element.date > $1.element.date
        }
        for (position, action) in ordered {
            guard !action.undone, action.proposal.origin != .automation,
                  case .classify(let messageID, let categoryID) = action.proposal.type,
                  byID[messageID] != nil, latest[messageID] == nil else { continue }
            latest[messageID] = Choice(action: action, messageID: messageID, categoryID: categoryID, position: position)
        }
        // An explicit choice to leave this message uncategorized must not be
        // immediately contradicted by a learned sender-level suggestion.
        if let own = latest[message.id], own.categoryID == nil { return nil }
        let choices = latest.values.filter { choice in
            choice.messageID != message.id && byID[choice.messageID]?.categoryID == choice.categoryID
        }.sorted { left, right in
            left.action.date == right.action.date ? left.position > right.position : left.action.date > right.action.date
        }
        guard let first = choices.first, let categoryID = first.categoryID, let category = categories[categoryID] else { return nil }
        // A new conflicting correction suspends the previous pattern. Two
        // distinct, most-recent matching choices are needed to establish a new
        // pattern; repeated clicks on one message never count twice.
        let supporting = Array(choices.prefix(while: { $0.categoryID == categoryID }))
        guard supporting.count >= Self.minimumExamples else { return nil }
        let evidence = supporting.prefix(20).map {
            CategoryLearningEvidence(actionID: $0.action.id, messageID: $0.messageID, accountID: message.accountID,
                                     categoryID: categoryID, confirmedAt: $0.action.date, acceptedAISuggestion: $0.action.proposal.origin == .ai)
        }
        let explanation = "Learned preference · Your \(evidence.count) most recent matching choices for \(sender) in this account used \(category.name). This is a local suggestion based on confirmed history; accepting changes only this message's Flora category."
        let stableID = StableMailIdentity.message(accountID: message.accountID, providerID: "learned-category:\(message.id):\(categoryID)")
        // The existing classification type requires a confidence number. Here
        // it is observed agreement among the supporting choices, not a model
        // probability; the explanation and evidence are the meaningful signal.
        let classification = ClassificationSuggestion(id: stableID, messageID: message.id, categoryID: categoryID, explanation: explanation, confidence: 1)
        return LearnedCategorySuggestion(classification: classification, accountID: message.accountID, senderEmail: sender, evidence: evidence)
    }
    private struct Choice {
        let action: ExecutedAction
        let messageID: UUID
        let categoryID: UUID?
        let position: Int
    }
    private static func sender(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count <= 254, value.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              !value.hasPrefix("@"), !value.hasSuffix("@"), !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { return nil }
        return value
    }
}
