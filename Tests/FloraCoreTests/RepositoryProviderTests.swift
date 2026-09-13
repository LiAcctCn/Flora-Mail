import Foundation
import XCTest
@testable import FloraCore

@MainActor
final class RepositoryProviderTests: XCTestCase {
    private func fixture() -> AppSnapshot {
        let account = MailAccount(name: "Demo", address: MailAddress(name: "Alex", email: "alex@example.com"))
        let category = MailCategory(name: "Work")
        let message = MailMessage(accountID: account.id, from: MailAddress(name: "John", email: "john@example.com"), to: [account.address], subject: "Meeting update", body: "Let's meet Wednesday.")
        let suggestion = ClassificationSuggestion(messageID: message.id, categoryID: category.id, explanation: "Work meeting")
        return AppSnapshot(accounts: [account], messages: [message], categories: [category], drafts: [Draft(to: "john@example.com", subject: "Re: Meeting", body: "Wednesday works.")],
                           summaries: [MessageSummary(messageID: message.id, headline: "Wednesday meeting", facts: [])], classifications: [suggestion],
                           rules: [AutomationRule(name: "Archive newsletters", senderEmail: "news@example.com", olderThanDays: 30)], preferences: UserPreferences(aiMode: .local))
    }

    func testJSONPersistenceRoundTripsAllStateAndMissingStoreReturnsNil() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMailTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONMailRepository(url: directory.appendingPathComponent("mail.json"))
        XCTAssertNil(try repository.load())
        let snapshot = fixture()
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load(), snapshot)
    }

    func testCorruptAndFutureStoresAreRejectedAndPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMailTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.json")
        let repository = JSONMailRepository(url: url)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual($0 as? RepositoryError, .unreadableStore) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let future = Data(#"{"schemaVersion":999}"#.utf8)
        try future.write(to: url)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual($0 as? RepositoryError, .unsupportedSchema(999)) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testFailedSaveDoesNotPublishActionOrConsumeUndo() async throws {
        let repository = FailableRepository()
        let executor = ActionExecutor(repository: repository, initialState: fixture())
        let initial = executor.state
        let proposal = ProposedAction(type: .archive(messageIDs: [initial.messages[0].id]), explanation: "Archive")
        repository.shouldFail = true
        XCTAssertThrowsError(try executor.execute(proposal))
        XCTAssertEqual(executor.state, initial)
        XCTAssertFalse(executor.canUndo)
        repository.shouldFail = false
        try executor.execute(proposal)
        let archived = executor.state
        repository.shouldFail = true
        XCTAssertThrowsError(try executor.undo())
        XCTAssertEqual(executor.state, archived)
        XCTAssertTrue(executor.canUndo)
        XCTAssertThrowsError(try executor.updatePreferences(UserPreferences(aiMode: .off)))
        XCTAssertEqual(executor.state, archived)
        repository.shouldFail = false
        try executor.undo()
        XCTAssertEqual(executor.state.messages[0].folder, .inbox)
    }

    func testProviderReadsAndWritesUseOneStateAndRetainPermissionBoundary() async throws {
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: fixture())
        let provider: any MailProvider = DemoMailProvider(executor: executor)
        let messages = try await provider.fetchMessages(folder: .inbox)
        XCTAssertEqual(messages, executor.state.messages)
        let thread = try await provider.fetchThread(id: messages[0].threadID)
        XCTAssertEqual(thread.messages, messages)
        do {
            try await provider.perform(ProposedAction(type: .archive(messageIDs: [messages[0].id]), explanation: "AI archive", origin: .ai), confirmed: false)
            XCTFail("Provider bypassed AI confirmation")
        } catch { XCTAssertEqual(error as? MailActionError, .confirmationRequired) }
        try await provider.perform(ProposedAction(type: .archive(messageIDs: [messages[0].id]), explanation: "User archive"), confirmed: false)
        let inbox = try await provider.fetchMessages(folder: .inbox)
        let archive = try await provider.fetchMessages(folder: .archive)
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(archive[0].id, messages[0].id)
        XCTAssertEqual(executor.state.messages[0].folder, .archive)
    }

    func testDemoSendRequiresConfirmationAndOnlyCreatesLocalSentRecord() async throws {
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: fixture())
        let draft = executor.state.drafts[0]
        let send = ProposedAction(type: .sendDraft(id: draft.id), explanation: "Send to demo Sent folder")
        XCTAssertThrowsError(try executor.execute(send)) { XCTAssertEqual($0 as? MailActionError, .confirmationRequired) }
        try executor.execute(send, confirmed: true)
        XCTAssertTrue(executor.state.drafts.isEmpty)
        let sent = try XCTUnwrap(executor.state.messages.first(where: { $0.folder == .sent }))
        XCTAssertEqual(sent.to.map(\.email), [draft.to])
        XCTAssertEqual(sent.body, draft.body)
        try executor.undo()
        XCTAssertEqual(executor.state.drafts, [draft])
        XCTAssertFalse(executor.state.messages.contains(where: { $0.folder == .sent }))
    }

    func testDemoSendValidatesRecipientAndSubject() async throws {
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: fixture())
        var draft = executor.state.drafts[0]
        draft.to = "invalid-address"
        try executor.execute(ProposedAction(type: .saveDraft(draft), explanation: "Save draft"))
        XCTAssertThrowsError(try executor.execute(ProposedAction(type: .sendDraft(id: draft.id), explanation: "Send"), confirmed: true)) {
            XCTAssertEqual($0 as? MailActionError, .invalidRecipient)
        }
        draft.to = "john@example.com"
        draft.subject = " \n"
        try executor.execute(ProposedAction(type: .saveDraft(draft), explanation: "Save draft"))
        XCTAssertThrowsError(try executor.execute(ProposedAction(type: .sendDraft(id: draft.id), explanation: "Send"), confirmed: true)) {
            XCTAssertEqual($0 as? MailActionError, .emptySubject)
        }
        XCTAssertFalse(executor.state.messages.contains(where: { $0.folder == .sent }))
    }

    func testDemoReplyUsesSourceAccountAndPreservesThread() async throws {
        var state = fixture()
        let university = MailAccount(name: "University", address: MailAddress(name: "Alex", email: "alex@university.example.com"))
        state.accounts.append(university)
        state.messages[0].accountID = university.id
        state.messages[0].to = [university.address]
        state.drafts[0].replyToMessageID = state.messages[0].id
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: state)
        try executor.execute(ProposedAction(type: .sendDraft(id: state.drafts[0].id), explanation: "Reply locally"), confirmed: true)
        let sent = try XCTUnwrap(executor.state.messages.first { $0.folder == .sent })
        XCTAssertEqual(sent.accountID, university.id)
        XCTAssertEqual(sent.from, university.address)
        XCTAssertEqual(sent.threadID, state.messages[0].threadID)
    }

    func testUndoDemoSendRemovesOnlyCachesForRemovedSentMessage() async throws {
        let original = fixture()
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: original)
        try executor.execute(ProposedAction(type: .sendDraft(id: original.drafts[0].id), explanation: "Send locally"), confirmed: true)
        let sent = try XCTUnwrap(executor.state.messages.first { $0.folder == .sent })
        try executor.cache(summary: MessageSummary(messageID: sent.id, headline: "Wednesday works", facts: []),
                           classification: ClassificationSuggestion(messageID: sent.id, categoryID: original.categories[0].id, explanation: "Work reply"))
        try executor.undo()
        XCTAssertEqual(executor.state.summaries, original.summaries)
        XCTAssertEqual(executor.state.classifications, original.classifications)
        XCTAssertEqual(executor.state.drafts, original.drafts)
    }

    func testUndoIsSessionOnlyWhileHistoryPersists() async throws {
        let repository = MemoryMailRepository()
        let first = ActionExecutor(repository: repository, initialState: fixture())
        try first.execute(ProposedAction(type: .archive(messageIDs: [first.state.messages[0].id]), explanation: "Archive"))
        let restored = ActionExecutor(repository: repository, initialState: try XCTUnwrap(repository.load()))
        XCTAssertFalse(restored.canUndo)
        XCTAssertFalse(try XCTUnwrap(restored.state.history.last).canUndo)
        XCTAssertEqual(restored.state.history.count, 1)
        XCTAssertEqual(restored.state.messages[0].folder, .archive)
    }
}

@MainActor
private final class FailableRepository: MailRepository {
    var shouldFail = false
    var snapshot: AppSnapshot?
    struct Failure: Error {}
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if shouldFail { throw Failure() }
        self.snapshot = snapshot
    }
}
