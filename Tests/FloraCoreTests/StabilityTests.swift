import Foundation
import XCTest
@testable import FloraCore

@MainActor
final class StabilityTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() -> AppSnapshot {
        let account = MailAccount(name: "Demo", address: MailAddress(name: "Alex", email: "alex@example.com"))
        let message = MailMessage(accountID: account.id,
                                  from: MailAddress(name: "Research Weekly", email: "news@example.com"),
                                  to: [account.address], subject: "Research proposal review",
                                  body: "Please review the proposal before Friday.",
                                  date: timestamp.addingTimeInterval(-40 * 86_400))
        return AppSnapshot(accounts: [account], messages: [message], categories: [
            MailCategory(name: "School"), MailCategory(name: "Work"), MailCategory(name: "Other")
        ])
    }

    func testCommittedWorkflowSurvivesRepositoryAndExecutorRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraStability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.json")
        let original = fixture()
        let executor = ActionExecutor(repository: JSONMailRepository(url: url), initialState: original, now: { self.timestamp })
        let messageID = original.messages[0].id
        let research = MailCategory(name: "Research", color: "blue")
        try executor.execute(ProposedAction(type: .createCategory(research), explanation: "Created Research"))
        let prediction = ClassificationSuggestion(messageID: messageID, categoryID: research.id, explanation: "Proposal review")
        let summary = MessageSummary(messageID: messageID, headline: "Review requested before Friday", facts: [])
        try executor.cache(summary: summary, classification: prediction)
        try executor.acceptClassification(prediction)
        try executor.execute(ProposedAction(type: .markRead(messageIDs: [messageID], isRead: true), explanation: "Marked read"))
        try executor.execute(ProposedAction(type: .flag(messageIDs: [messageID], isFlagged: true), explanation: "Flagged"))
        try executor.execute(ProposedAction(type: .archive(messageIDs: [messageID]), explanation: "Archived"))
        let draft = Draft(to: "news@example.com", subject: "Re: Proposal", body: "I will review it on Thursday.")
        try executor.execute(ProposedAction(type: .saveDraft(draft), explanation: "Saved reply"))
        try executor.updatePreferences(UserPreferences(aiMode: .off, automationLevel: .rules))
        let enabled = AutomationRule(name: "Old research updates", senderEmail: "news@example.com", olderThanDays: 30, enabled: true, accountID: original.accounts[0].id, expiresAt: timestamp.addingTimeInterval(86_400))
        let disabled = AutomationRule(name: "Shopping updates", senderEmail: "shop@example.com", olderThanDays: 60, accountID: original.accounts[0].id)
        try executor.saveAutomationRule(enabled, confirmed: true)
        try executor.saveAutomationRule(disabled)
        let committed = executor.state

        // Use a fresh file repository and executor, as a new app process would.
        let reopenedRepository = JSONMailRepository(url: url)
        let loaded = try XCTUnwrap(reopenedRepository.load())
        XCTAssertEqual(loaded, committed)
        let restarted = ActionExecutor(repository: reopenedRepository, initialState: loaded, now: { self.timestamp })
        XCTAssertEqual(restarted.state.categories, original.categories + [research])
        let message = try XCTUnwrap(restarted.state.messages.first { $0.id == messageID })
        XCTAssertEqual(message.categoryID, research.id)
        XCTAssertEqual(message.folder, .archive)
        XCTAssertTrue(message.isRead)
        XCTAssertTrue(message.isFlagged)
        XCTAssertTrue(restarted.state.classifications.isEmpty)
        XCTAssertEqual(restarted.state.summaries, [summary])
        XCTAssertEqual(restarted.state.drafts.first?.body, draft.body)
        XCTAssertEqual(restarted.state.preferences.aiMode, .off)
        XCTAssertEqual(restarted.state.rules.first { $0.id == enabled.id }?.authorizedAt, timestamp)
        XCTAssertTrue(try XCTUnwrap(restarted.state.rules.first { $0.id == enabled.id }).enabled)
        XCTAssertFalse(try XCTUnwrap(restarted.state.rules.first { $0.id == disabled.id }).enabled)
        XCTAssertNil(restarted.state.rules.first { $0.id == disabled.id }?.authorizedAt)
        XCTAssertEqual(restarted.state.history.map(\.proposal), committed.history.map(\.proposal))
        XCTAssertFalse(restarted.canUndo)
        XCTAssertTrue(restarted.state.history.allSatisfy { !$0.canUndo })
    }

    func testUndoAndRemovedCategoryRemainDurableAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraStability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.json")
        let executor = ActionExecutor(repository: JSONMailRepository(url: url), initialState: fixture())
        let messageID = executor.state.messages[0].id
        let removedID = executor.state.categories[1].id
        try executor.execute(ProposedAction(type: .archive(messageIDs: [messageID]), explanation: "Archive"))
        try executor.undo()
        try executor.execute(ProposedAction(type: .deleteCategory(id: removedID), explanation: "Remove Work"))

        let loaded = try XCTUnwrap(JSONMailRepository(url: url).load())
        XCTAssertEqual(loaded.messages[0].folder, .inbox)
        XCTAssertFalse(loaded.categories.contains { $0.id == removedID })
        XCTAssertTrue(try XCTUnwrap(loaded.history.first).undone)
        XCTAssertFalse(try XCTUnwrap(loaded.history.first).canUndo)
        XCTAssertEqual(loaded.history.count, 2)
    }

    func testUndoRenameAndRemovalPreserveCategoryOrder() async throws {
        let initial = fixture()
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let middle = initial.categories[1]
        try executor.execute(ProposedAction(type: .renameCategory(id: middle.id, name: "Research"), explanation: "Rename"))
        try executor.undo()
        XCTAssertEqual(executor.state.categories, initial.categories)
        try executor.execute(ProposedAction(type: .deleteCategory(id: middle.id), explanation: "Remove"))
        try executor.undo()
        XCTAssertEqual(executor.state.categories, initial.categories)
    }

    func testDisabledRuleCannotRegainAuthorityAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraStability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.json")
        let executor = ActionExecutor(repository: JSONMailRepository(url: url), initialState: fixture(), now: { self.timestamp })
        try executor.updatePreferences(UserPreferences(automationLevel: .rules))
        var rule = AutomationRule(name: "Old newsletters", senderEmail: "news@example.com", olderThanDays: 30, enabled: true, accountID: executor.state.accounts[0].id, expiresAt: timestamp.addingTimeInterval(86_400))
        try executor.saveAutomationRule(rule, confirmed: true)
        rule.enabled = false
        try executor.saveAutomationRule(rule)
        let repository = JSONMailRepository(url: url)
        let restarted = ActionExecutor(repository: repository, initialState: try XCTUnwrap(repository.load()), now: { self.timestamp })
        let proposal = ProposedAction(type: .archive(messageIDs: [restarted.state.messages[0].id]), explanation: "Archive using disabled rule", origin: .automation)
        XCTAssertThrowsError(try restarted.execute(proposal, confirmed: true, ruleID: rule.id)) {
            XCTAssertEqual($0 as? MailActionError, .invalidAutomation)
        }
        XCTAssertEqual(restarted.state.messages[0].folder, .inbox)
        XCTAssertTrue(restarted.state.history.isEmpty)
    }

    func testEveryAIWriteRequiresExplicitConfirmation() async throws {
        var state = fixture()
        let existingDraft = Draft(to: "colleague@example.com", subject: "Review update", body: "Please review the notes.", accountID: state.accounts[0].id)
        state.drafts = [existingDraft]
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: state)
        let messageID = state.messages[0].id
        let actions: [ActionType] = [
            .archive(messageIDs: [messageID]), .move(messageIDs: [messageID], folder: .trash),
            .markRead(messageIDs: [messageID], isRead: true), .flag(messageIDs: [messageID], isFlagged: true),
            .classify(messageID: messageID, categoryID: state.categories[0].id),
            .createCategory(MailCategory(name: "Unauthorized")),
            .renameCategory(id: state.categories[0].id, name: "Unauthorized"),
            .deleteCategory(id: state.categories[0].id), .saveDraft(Draft(body: "Generated text")),
            .deleteDraft(id: existingDraft.id), .sendDraft(id: existingDraft.id)
        ]
        for action in actions {
            XCTAssertThrowsError(try executor.execute(ProposedAction(type: action, explanation: "Model recommendation", origin: .ai))) {
                XCTAssertEqual($0 as? MailActionError, .confirmationRequired)
            }
            XCTAssertEqual(executor.state, state)
            XCTAssertFalse(executor.canUndo)
        }
    }
}
