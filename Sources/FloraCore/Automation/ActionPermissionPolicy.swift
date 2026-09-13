import Foundation

public enum MailActionError: LocalizedError, Equatable {
    case confirmationRequired
    case messageNotFound
    case categoryNotFound
    case invalidCategoryName
    case duplicateCategory
    case draftNotFound
    case invalidRecipient
    case emptySubject
    case accountNotFound
    case staleClassification
    case invalidAutomation
    case outsideAutomationScope
    case noUndo
    case emptySelection
    case readOnlyAccount

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Review and confirm this action before it is applied."
        case .messageNotFound: "This message is no longer available."
        case .categoryNotFound: "This category is no longer available."
        case .invalidCategoryName: "Enter a category name between 1 and 50 characters."
        case .duplicateCategory: "A category with this name already exists."
        case .draftNotFound: "This draft is no longer available."
        case .invalidRecipient: "Enter valid email addresses separated by commas."
        case .emptySubject: "Add a subject before sending."
        case .accountNotFound: "No demo account is available."
        case .staleClassification: "This suggestion has changed or is no longer available. Generate a new suggestion."
        case .invalidAutomation: "Automation requires a saved, enabled rule explicitly authorized by you."
        case .outsideAutomationScope: "The proposed action falls outside this rule’s sender, age, or Inbox scope."
        case .noUndo: "There is no action to undo in this session."
        case .emptySelection: "Select at least one message."
        case .readOnlyAccount: "Real accounts are read-only in this version. Mailbox changes and sending are available only in Demo Mode."
        }
    }
}

/// Execution authority is evaluated here, independently of AI explanations.
public enum ActionPermissionPolicy {
    public static func validate(_ proposal: ProposedAction, confirmed: Bool, ruleID: UUID?, state: AppSnapshot, now: Date) throws {
        // This gate runs before confirmation or automation checks. Neither user
        // confirmation nor a saved automation rule upgrades a real account.
        switch proposal.type {
        case .archive(let ids), .move(let ids, _), .markRead(let ids, _), .flag(let ids, _):
            for id in ids {
                guard let message = state.messages.first(where: { $0.id == id }) else { throw MailActionError.messageNotFound }
                guard state.accounts.contains(where: { $0.id == message.accountID && !$0.isReadOnly }) else { throw MailActionError.readOnlyAccount }
            }
        case .sendDraft(let id):
            guard let draft = state.drafts.first(where: { $0.id == id }) else { throw MailActionError.draftNotFound }
            if let accountID = draft.accountID {
                guard state.accounts.contains(where: { $0.id == accountID && !$0.isReadOnly }) else { throw MailActionError.readOnlyAccount }
            }
            if let replyID = draft.replyToMessageID {
                guard let message = state.messages.first(where: { $0.id == replyID }),
                      state.accounts.contains(where: { $0.id == message.accountID && !$0.isReadOnly }) else { throw MailActionError.readOnlyAccount }
            }
        default: break // Categories, classification and saved drafts are local annotations.
        }
        if proposal.origin == .automation {
            guard let ruleID,
                  let rule = state.rules.first(where: { $0.id == ruleID }),
                  rule.enabled, let authorizedAt = rule.authorizedAt, authorizedAt <= now,
                  rule.olderThanDays >= 1, !rule.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw MailActionError.invalidAutomation }
            guard case .archive(let ids) = proposal.type, !ids.isEmpty else {
                throw MailActionError.outsideAutomationScope
            }
            let cutoff = now.addingTimeInterval(-Double(rule.olderThanDays) * 86_400)
            let sender = rule.senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for id in ids {
                guard let message = state.messages.first(where: { $0.id == id }),
                      message.folder == .inbox, message.date < cutoff,
                      message.from.email.lowercased() == sender else {
                    throw MailActionError.outsideAutomationScope
                }
            }
            return
        }
        // A supplied rule never grants authority to a different action origin.
        guard !proposal.requiresConfirmation || confirmed else { throw MailActionError.confirmationRequired }
    }
}
