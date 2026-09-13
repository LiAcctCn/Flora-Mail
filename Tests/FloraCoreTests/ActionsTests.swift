import Foundation
import XCTest
@testable import FloraCore

@MainActor
final class ActionsTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> AppSnapshot {
        let account = MailAccount(name: "Demo", address: MailAddress(name: "Alex", email: "alex@example.com"))
        let category = MailCategory(name: "Research")
        let message = MailMessage(accountID: account.id, from: MailAddress(name: "Newsletter", email: "news@example.com"),
                                  to: [account.address], subject: "Research updates", body: "Please review the project update.",
                                  date: timestamp.addingTimeInterval(-40 * 86_400))
        return AppSnapshot(accounts: [account], messages: [message], categories: [category])
    }

    private func executor(_ snapshot: AppSnapshot? = nil) -> ActionExecutor {
        ActionExecutor(repository: MemoryMailRepository(), initialState: snapshot ?? fixture(), now: { self.timestamp })
    }

    func testCategoryCreationNormalizesAndRejectsDuplicates() async throws {
        let executor = executor()
        try executor.execute(ProposedAction(type: .createCategory(MailCategory(name: "  School  ")), explanation: "Create category"))
        XCTAssertEqual(executor.state.categories.last?.name, "School")
        XCTAssertThrowsError(try executor.execute(ProposedAction(type: .createCategory(MailCategory(name: "school")), explanation: "Duplicate"))) {
            XCTAssertEqual($0 as? MailActionError, .duplicateCategory)
        }
        XCTAssertThrowsError(try executor.execute(ProposedAction(type: .createCategory(MailCategory(name: " \n")), explanation: "Empty")))
    }

    func testCategoryRemovalClearsConfirmedAndPredictedReferencesAndUndoRestoresThem() async throws {
        var state = fixture()
        let categoryID = state.categories[0].id
        state.messages[0].categoryID = categoryID
        var predictedMessage = state.messages[0]
        predictedMessage.id = UUID()
        predictedMessage.categoryID = nil
        state.messages.append(predictedMessage)
        state.classifications = [ClassificationSuggestion(messageID: predictedMessage.id, categoryID: categoryID, explanation: "Research topic")]
        let executor = executor(state)
        try executor.execute(ProposedAction(type: .deleteCategory(id: categoryID), explanation: "Delete Research"))
        XCTAssertTrue(executor.state.categories.isEmpty)
        XCTAssertNil(executor.state.messages[0].categoryID)
        XCTAssertTrue(executor.state.classifications.isEmpty)
        try executor.undo()
        XCTAssertEqual(executor.state.categories, state.categories)
        XCTAssertEqual(Set(executor.state.messages.map(\.id)), Set(state.messages.map(\.id)))
        XCTAssertEqual(executor.state.messages.first { $0.id == state.messages[0].id }?.categoryID, categoryID)
        XCTAssertEqual(executor.state.classifications, state.classifications)
    }

    func testAISuggestionCannotMutateWithoutConfirmation() async throws {
        let executor = executor()
        let proposal = ProposedAction(type: .archive(messageIDs: [executor.state.messages[0].id]), explanation: "AI recommends archiving", origin: .ai)
        XCTAssertThrowsError(try executor.execute(proposal)) { XCTAssertEqual($0 as? MailActionError, .confirmationRequired) }
        XCTAssertEqual(executor.state.messages[0].folder, .inbox)
        XCTAssertTrue(executor.state.history.isEmpty)
        try executor.execute(proposal, confirmed: true)
        XCTAssertEqual(executor.state.messages[0].folder, .archive)
    }

    func testSerializedProposalCannotForgeConfirmationRequirement() async throws {
        let executor = executor()
        let original = ProposedAction(type: .archive(messageIDs: [executor.state.messages[0].id]), explanation: "Untrusted proposal", origin: .ai)
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["requiresConfirmation"] = false
        object["risk"] = "informational"
        let forged = try JSONDecoder().decode(ProposedAction.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(forged.requiresConfirmation)
        XCTAssertEqual(forged.risk, .reversible)
        XCTAssertThrowsError(try executor.execute(forged))
    }

    func testClassificationPredictionDoesNotChangeMessageUntilAccepted() async throws {
        let executor = executor()
        let messageID = executor.state.messages[0].id
        let suggestion = ClassificationSuggestion(messageID: messageID, categoryID: executor.state.categories[0].id, explanation: "Research topic")
        try executor.cache(summary: MessageSummary(messageID: messageID, headline: "Project update", facts: []), classification: suggestion)
        XCTAssertNil(executor.state.messages[0].categoryID)
        try executor.acceptClassification(suggestion)
        XCTAssertEqual(executor.state.messages[0].categoryID, suggestion.categoryID)
        XCTAssertTrue(executor.state.classifications.isEmpty)
        XCTAssertEqual(executor.state.history.last?.proposal.origin, .ai)
    }

    func testStaleClassificationCannotBeAccepted() async throws {
        let executor = executor()
        let messageID = executor.state.messages[0].id
        let summary = MessageSummary(messageID: messageID, headline: "Update", facts: [])
        let old = ClassificationSuggestion(messageID: messageID, categoryID: executor.state.categories[0].id, explanation: "Old prediction")
        let fresh = ClassificationSuggestion(messageID: messageID, categoryID: old.categoryID, explanation: "Fresh prediction")
        try executor.cache(summary: summary, classification: old)
        try executor.cache(summary: summary, classification: fresh)
        XCTAssertThrowsError(try executor.acceptClassification(old)) { XCTAssertEqual($0 as? MailActionError, .staleClassification) }
        XCTAssertNil(executor.state.messages[0].categoryID)
        try executor.execute(ProposedAction(type: .deleteCategory(id: old.categoryID), explanation: "Remove category"))
        XCTAssertThrowsError(try executor.acceptClassification(fresh))
        XCTAssertThrowsError(try executor.cache(summary: summary, classification: fresh))
    }

    func testPredictionNeverOverwritesUserCategory() async throws {
        let executor = executor()
        let messageID = executor.state.messages[0].id
        let categoryID = executor.state.categories[0].id
        try executor.execute(ProposedAction(type: .classify(messageID: messageID, categoryID: categoryID), explanation: "Manual category"))
        let suggestion = ClassificationSuggestion(messageID: messageID, categoryID: categoryID, explanation: "AI topic")
        try executor.cache(summary: MessageSummary(messageID: messageID, headline: "Update", facts: []), classification: suggestion)
        XCTAssertTrue(executor.state.classifications.isEmpty)
        XCTAssertEqual(executor.state.messages[0].categoryID, categoryID)
    }

    func testUndoArchivePreservesLaterAICacheAndPreferences() async throws {
        let executor = executor()
        let id = executor.state.messages[0].id
        try executor.execute(ProposedAction(type: .archive(messageIDs: [id]), explanation: "Archive"))
        let summary = MessageSummary(messageID: id, headline: "Project update", facts: [])
        try executor.cache(summary: summary, classification: nil)
        try executor.updatePreferences(UserPreferences(aiMode: .off))
        try executor.undo()
        XCTAssertEqual(executor.state.messages[0].folder, .inbox)
        XCTAssertEqual(executor.state.summaries, [summary])
        XCTAssertEqual(executor.state.preferences.aiMode, .off)
        XCTAssertEqual(executor.state.history.last?.undone, true)
        XCTAssertFalse(executor.canUndo)
    }

    func testUndoCategoryRemovalDiscardsNewPredictionWhenRestoringConfirmedCategory() async throws {
        var state = fixture()
        state.messages[0].categoryID = state.categories[0].id
        let other = MailCategory(name: "Other")
        state.categories.append(other)
        let executor = executor(state)
        let id = state.messages[0].id
        try executor.execute(ProposedAction(type: .deleteCategory(id: state.categories[0].id), explanation: "Remove Research"))
        let summary = MessageSummary(messageID: id, headline: "Update", facts: [])
        try executor.cache(summary: summary, classification: ClassificationSuggestion(messageID: id, categoryID: other.id, explanation: "Remaining category"))
        XCTAssertEqual(executor.state.classifications.count, 1)
        try executor.undo()
        XCTAssertEqual(executor.state.messages[0].categoryID, state.categories[0].id)
        XCTAssertTrue(executor.state.classifications.isEmpty)
        XCTAssertEqual(executor.state.summaries, [summary])
    }

    func testMessageStateTransitionsAndUndo() async throws {
        let executor = executor()
        let id = executor.state.messages[0].id
        try executor.execute(ProposedAction(type: .markRead(messageIDs: [id], isRead: true), explanation: "Read"))
        try executor.execute(ProposedAction(type: .flag(messageIDs: [id], isFlagged: true), explanation: "Flag"))
        try executor.execute(ProposedAction(type: .move(messageIDs: [id], folder: .trash), explanation: "Move to Trash"))
        XCTAssertTrue(executor.state.messages[0].isRead)
        XCTAssertTrue(executor.state.messages[0].isFlagged)
        XCTAssertEqual(executor.state.messages[0].folder, .trash)
        try executor.undo()
        XCTAssertEqual(executor.state.messages[0].folder, .inbox)
        try executor.undo()
        XCTAssertFalse(executor.state.messages[0].isFlagged)
        try executor.undo()
        XCTAssertFalse(executor.state.messages[0].isRead)
    }

    func testInvalidBatchDoesNotPartiallyMutate() async throws {
        let executor = executor()
        let before = executor.state
        XCTAssertThrowsError(try executor.execute(ProposedAction(type: .archive(messageIDs: [before.messages[0].id, UUID()]), explanation: "Archive batch")))
        XCTAssertEqual(executor.state, before)
        XCTAssertFalse(executor.canUndo)
    }

    func testAutomationRequiresPersistedEnabledAuthorizedRule() async throws {
        let executor = executor()
        let proposal = ProposedAction(type: .archive(messageIDs: [executor.state.messages[0].id]), explanation: "Archive newsletters", origin: .automation)
        let rule = AutomationRule(name: "Old newsletters", senderEmail: "news@example.com", olderThanDays: 30, enabled: true)
        XCTAssertThrowsError(try executor.execute(proposal, confirmed: true, ruleID: rule.id))
        XCTAssertThrowsError(try executor.saveAutomationRule(rule))
        try executor.saveAutomationRule(rule, confirmed: true)
        try executor.execute(proposal, ruleID: rule.id)
        XCTAssertEqual(executor.state.messages[0].folder, .archive)
        XCTAssertTrue(executor.state.history.last?.proposal.explanation.contains(rule.name) == true)
    }

    func testAutomationEnforcesSenderAgeInboxAndActionScope() async throws {
        let initial = fixture()
        for violation in ["sender", "age", "folder", "action"] {
            var state = initial
            let rule = AutomationRule(name: "Old newsletters", senderEmail: "news@example.com", olderThanDays: 30, enabled: true, authorizedAt: timestamp.addingTimeInterval(-100))
            state.rules = [rule]
            if violation == "sender" { state.messages[0].from.email = "someone@example.com" }
            if violation == "age" { state.messages[0].date = timestamp.addingTimeInterval(-2 * 86_400) }
            if violation == "folder" { state.messages[0].folder = .sent }
            let executor = executor(state)
            let action: ActionType = violation == "action" ? .move(messageIDs: [state.messages[0].id], folder: .trash) : .archive(messageIDs: [state.messages[0].id])
            XCTAssertThrowsError(try executor.execute(ProposedAction(type: action, explanation: "Outside scope", origin: .automation), confirmed: true, ruleID: rule.id), violation) {
                XCTAssertEqual($0 as? MailActionError, .outsideAutomationScope)
            }
            XCTAssertEqual(executor.state, state)
        }
    }

    func testAutomationChangesRequireNewExplicitConfirmation() async throws {
        let executor = executor()
        var rule = AutomationRule(name: "Newsletters", senderEmail: "news@example.com", olderThanDays: 30, enabled: true)
        try executor.saveAutomationRule(rule, confirmed: true)
        rule.olderThanDays = 1
        XCTAssertThrowsError(try executor.saveAutomationRule(rule))
        XCTAssertEqual(executor.state.rules[0].olderThanDays, 30)
    }
}
