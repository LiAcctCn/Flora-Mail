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
    case assistanceDisabled

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
        case .assistanceDisabled: "This interaction mode does not allow AI-assisted changes. Manual controls remain available."
        case .readOnlyAccount: "Review a real account action and authorize mailbox changes in Accounts settings."
        }
    }
}

/// Execution authority is evaluated here, independently of AI explanations.
public enum ActionPermissionPolicy {
    public static func validate(_ proposal: ProposedAction, confirmed: Bool, ruleID: UUID?, state: AppSnapshot, now: Date, automation: AuthorizedAutomationDispatch? = nil) throws {
        // This gate runs before confirmation or automation checks. Neither user
        // confirmation nor a saved automation rule upgrades a real account.
        switch proposal.type {
        case .archive(let ids), .move(let ids, _), .markRead(let ids, _), .flag(let ids, _):
            for id in ids {
                guard let message = state.messages.first(where: { $0.id == id }) else { throw MailActionError.messageNotFound }
                guard state.accounts.contains(where: { $0.id == message.accountID && !$0.isRemote }) else { throw MailActionError.readOnlyAccount }
            }
        case .sendDraft(let id):
            guard let draft = state.drafts.first(where: { $0.id == id }) else { throw MailActionError.draftNotFound }
            if let accountID = draft.accountID {
                guard state.accounts.contains(where: { $0.id == accountID && !$0.isRemote }) else { throw MailActionError.readOnlyAccount }
            }
            if let replyID = draft.replyToMessageID {
                guard let message = state.messages.first(where: { $0.id == replyID }),
                      state.accounts.contains(where: { $0.id == message.accountID && !$0.isRemote }) else { throw MailActionError.readOnlyAccount }
            }
        default: break // Categories, classification and saved drafts are local annotations.
        }
        if proposal.origin == .ai, state.preferences.automationLevel < .suggestion || state.preferences.researchMode == .traditional {
            throw MailActionError.assistanceDisabled
        }
        if proposal.origin == .automation {
            guard let automation, ruleID == automation.ruleID else { throw MailActionError.invalidAutomation }
            try AutomationPolicy.validateDispatch(automation, state: state, now: now)
            guard proposal.id == automation.id, proposal.type == automation.action.localAction(messageID: automation.messageID) else { throw MailActionError.outsideAutomationScope }
            return
        }
        // A supplied rule never grants authority to a different action origin.
        guard !proposal.requiresConfirmation || confirmed else { throw MailActionError.confirmationRequired }
    }
}
