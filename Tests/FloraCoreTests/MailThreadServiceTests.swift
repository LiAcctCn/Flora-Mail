import Foundation
import XCTest
@testable import FloraCore

@MainActor
private final class ThreadFixtureProvider: ReadOnlyMailProvider {
    let accountID: UUID
    let name = "Conversation fixture"
    private(set) var requestedSources: [MailMessage] = []
    var fetch: (MailMessage) async throws -> MailThread
    init(accountID: UUID, fetch: @escaping (MailMessage) async throws -> MailThread) { self.accountID = accountID; self.fetch = fetch }
    func fetchAccounts() async throws -> [MailAccount] { [] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage { throw MailSyncError.unavailable }
    func fetchThread(id: UUID) async throws -> MailThread { throw MailThreadError.unavailable }
    func fetchThread(message: MailMessage) async throws -> MailThread {
        requestedSources.append(message)
        return try await fetch(message)
    }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
}

@MainActor
private final class ThreadFailingRepository: MailRepository {
    var snapshot: AppSnapshot?
    var fail = false
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}

@MainActor
private final class UnsupportedThreadProvider: ReadOnlyMailProvider {
    let accountID: UUID
    let name = "Cached conversations only"
    private(set) var pageRequests = 0
    init(accountID: UUID) { self.accountID = accountID }
    func fetchAccounts() async throws -> [MailAccount] { [] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        pageRequests += 1
        return MailSyncPage(messages: [], checkpoint: SyncCheckpoint())
    }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
}

@MainActor
final class MailThreadServiceTests: XCTestCase {
    private func account() -> MailAccount {
        MailAccount(name: "Gmail fixture", address: MailAddress(name: "Reader", email: "reader@example.test"), provider: "Gmail", providerType: .gmail,
                    providerAccountID: UUID().uuidString, credentialReference: MailCredentialReference(id: UUID().uuidString),
                    syncState: MailSyncState(checkpoint: SyncCheckpoint(opaqueState: "mailbox-delta", continuationToken: "pending-page", initialComplete: true), lastSuccessfulSync: Date(timeIntervalSince1970: 1_800_000_000), errorMessage: "Prior sync status"))
    }
    private func message(_ account: MailAccount, id: String = "source", thread: String = "conversation", body: String = "Please review the notes.") -> MailMessage {
        MailMessage(id: StableMailIdentity.message(accountID: account.id, providerID: id), providerID: id, accountID: account.id,
                    threadID: StableMailIdentity.thread(accountID: account.id, providerID: thread), from: MailAddress(name: "Colleague", email: "colleague@example.test"), to: [account.address],
                    subject: "Review", body: body, date: Date(timeIntervalSince1970: 1_800_000_000), providerThreadID: thread, providerFolderIDs: ["INBOX"])
    }

    func testReloadedProviderUsesPersistedSourceAndCommitsWithoutAdvancingCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraThreadTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = account(), otherAccount = self.account(), category = MailCategory(name: "Research")
        var source = message(account)
        source.categoryID = category.id
        source.attachments = [MailAttachment(name: "notes.pdf", size: 50, providerID: "part-1", downloadState: .downloaded, localRelativePath: "controlled/notes.pdf")]
        let summary = MessageSummary(messageID: source.id, headline: "Review requested", facts: [])
        let existing = AppSnapshot(accounts: [account, otherAccount], messages: [source, message(otherAccount, id: "additional")], categories: [category], summaries: [summary])
        let repository = JSONMailRepository(url: directory.appendingPathComponent("mail.json"))
        try repository.save(existing)
        let restored = try XCTUnwrap(repository.load())
        let executor = ActionExecutor(repository: repository, initialState: restored)
        let additional = message(account, id: "additional", body: "Here is the earlier discussion.")
        let provider = ThreadFixtureProvider(accountID: account.id) { requested in
            XCTAssertEqual(requested.providerThreadID, "conversation")
            var refreshed = requested; refreshed.categoryID = nil; refreshed.isRead = true
            refreshed.attachments[0].downloadState = .notDownloaded; refreshed.attachments[0].localRelativePath = nil
            return MailThread(id: requested.threadID, messages: [refreshed, additional, additional])
        }
        let result = try await MailThreadService(executor: executor).load(message: source, provider: provider)
        XCTAssertEqual(provider.requestedSources.count, 1)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.messages.allSatisfy { $0.accountID == account.id })
        XCTAssertEqual(executor.state.messages.count, 3)
        let retained = try XCTUnwrap(executor.state.messages.first { $0.id == source.id })
        XCTAssertEqual(retained.categoryID, category.id)
        XCTAssertEqual(retained.attachments[0].localRelativePath, "controlled/notes.pdf")
        XCTAssertTrue(retained.isRead)
        XCTAssertEqual(executor.state.summaries, [summary])
        XCTAssertEqual(executor.state.accounts, existing.accounts)
        XCTAssertTrue(executor.state.history.isEmpty)
        XCTAssertEqual(try repository.load(), executor.state)
    }

    func testWrongAccountThreadPageIsRejectedAtomically() async throws {
        let first = account(), second = account()
        let source = message(first)
        let initial = AppSnapshot(accounts: [first, second], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let crossAccount = message(second, id: "injected")
        let provider = ThreadFixtureProvider(accountID: first.id) { _ in MailThread(id: source.threadID, messages: [source, crossAccount]) }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Cross-account conversation accepted") }
        catch { XCTAssertEqual(error as? MailSyncError, .accountMismatch) }
        XCTAssertEqual(executor.state, initial)
        let wrongProvider = ThreadFixtureProvider(accountID: second.id) { _ in MailThread(id: source.threadID, messages: [source]) }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: wrongProvider); XCTFail("Wrong account provider used") }
        catch { XCTAssertEqual(error as? MailSyncError, .accountMismatch) }
        XCTAssertTrue(wrongProvider.requestedSources.isEmpty)
    }

    func testDifferentConversationDoesNotContaminateCachedThread() async throws {
        let account = account(), sourceThread = "source-conversation"
        let source = message(account, thread: sourceThread)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let unrelated = message(account, id: "unrelated", thread: "different-conversation")
        let provider = ThreadFixtureProvider(accountID: account.id) { _ in MailThread(id: source.threadID, messages: [source, unrelated]) }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Unrelated conversation accepted") }
        catch { XCTAssertEqual(error as? MailThreadError, .invalidThread) }
        XCTAssertEqual(executor.state, initial)
    }

    func testPartialRemoteFailurePreservesCachedMessagesAndCheckpoint() async throws {
        let account = account(), source = message(account)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let provider = ThreadFixtureProvider(accountID: account.id) { _ in
            _ = self.message(account, id: "retrieved-before-failure")
            throw MailSyncError.rateLimited
        }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Expected partial remote failure") }
        catch { XCTAssertEqual(error as? MailSyncError, .rateLimited) }
        XCTAssertEqual(executor.state, initial)
    }

    func testCancelledProviderCompletionCannotPublishThread() async throws {
        let account = account(), source = message(account)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let provider = ThreadFixtureProvider(accountID: account.id) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return MailThread(id: source.threadID, messages: [source, self.message(account, id: "late")])
        }
        let operation = Task { try await MailThreadService(executor: executor).load(message: source, provider: provider) }
        do { _ = try await operation.value; XCTFail("Cancelled thread was published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(executor.state, initial)
    }

    func testCredentialReplacementDuringLoadDiscardsOldResponse() async throws {
        let account = account(), source = message(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        let provider = ThreadFixtureProvider(accountID: account.id) { _ in
            var reauthenticated = account; reauthenticated.credentialReference = MailCredentialReference(id: "replacement-reference")
            try executor.updateAccount(reauthenticated)
            return MailThread(id: source.threadID, messages: [source, self.message(account, id: "stale")])
        }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Stale credential result published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(executor.state.messages, [source])
        XCTAssertEqual(executor.state.accounts[0].syncState, account.syncState)
    }

    func testPersistenceFailureLeavesThreadAndCheckpointUntouched() async throws {
        let account = account(), source = message(account)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let repository = ThreadFailingRepository(); try repository.save(initial); repository.fail = true
        let executor = ActionExecutor(repository: repository, initialState: initial)
        let provider = ThreadFixtureProvider(accountID: account.id) { _ in MailThread(id: source.threadID, messages: [source, self.message(account, id: "new")]) }
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Expected persistence failure") } catch {}
        XCTAssertEqual(executor.state, initial)
        XCTAssertEqual(repository.snapshot, initial)
    }

    func testOversizedConversationIsRejectedWithoutPartialCommit() throws {
        let account = account(), source = message(account)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let oversized = MailThread(id: source.threadID, messages: Array(repeating: source, count: MailThreadService.maximumMessages + 1))
        XCTAssertThrowsError(try executor.commitRemoteThread(oversized, sourceMessageID: source.id)) { XCTAssertEqual($0 as? MailThreadError, .tooLarge) }
        XCTAssertEqual(executor.state, initial)
    }

    func testContentWarningsAreSeparateFromBodyAndBackwardCompatible() throws {
        let account = account()
        var source = message(account, body: "Original source body")
        source.contentWarnings = ["Some content could not be decoded."]
        let encoded = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(MailMessage.self, from: encoded).contentWarnings, source.contentWarnings)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "contentWarnings")
        let decoded = try JSONDecoder().decode(MailMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.contentWarnings.isEmpty)
        XCTAssertEqual(decoded.body, source.body)
    }

    func testUnsupportedRemoteThreadDoesNotPretendRecentMailboxPageIsConversation() async throws {
        let account = account(), source = message(account)
        let initial = AppSnapshot(accounts: [account], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let provider = UnsupportedThreadProvider(accountID: account.id)
        do { _ = try await MailThreadService(executor: executor).load(message: source, provider: provider); XCTFail("Expected explicit unavailable state") }
        catch { XCTAssertEqual(error as? MailThreadError, .unavailable) }
        XCTAssertEqual(provider.pageRequests, 0)
        XCTAssertEqual(executor.state, initial)
    }

    func testWarningOnlyBodyRefreshPreservesPriorReadableContentInPagesAndThreads() throws {
        for throughThread in [false, true] {
            let account = account(), category = MailCategory(name: "Research")
            var source = message(account, body: "Previously readable source")
            source.htmlBody = "<p>Previously readable source</p>"; source.categoryID = category.id
            source.attachments = [MailAttachment(name: "notes.pdf", size: 20, providerID: "part-1", downloadState: .downloaded, localRelativePath: "controlled/notes.pdf")]
            let summary = MessageSummary(messageID: source.id, headline: "Prior source summary", facts: [])
            let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source], categories: [category], summaries: [summary]))
            var failed = source
            failed.body = ""; failed.htmlBody = nil; failed.attachments = []; failed.isRead = true
            failed.contentWarnings = ["The latest body could not be decoded."]
            if throughThread { try executor.commitRemoteThread(MailThread(id: source.threadID, messages: [failed]), sourceMessageID: source.id) }
            else { try executor.commitSyncPage(MailSyncPage(messages: [failed], checkpoint: SyncCheckpoint(opaqueState: "next")), accountID: account.id) }
            let retained = try XCTUnwrap(executor.state.messages.first)
            XCTAssertEqual(retained.body, source.body); XCTAssertEqual(retained.htmlBody, source.htmlBody)
            XCTAssertEqual(retained.attachments, source.attachments); XCTAssertEqual(retained.categoryID, category.id)
            XCTAssertTrue(retained.isRead)
            XCTAssertTrue(retained.contentWarnings.contains("The latest body could not be decoded."))
            XCTAssertTrue(retained.contentWarnings.contains { $0.contains("previously cached content") })
            XCTAssertEqual(executor.state.summaries, [summary])
            if throughThread { XCTAssertEqual(executor.state.accounts[0].syncState.checkpoint, account.syncState.checkpoint) }
            var recovered = source; recovered.body = "Freshly recovered body"; recovered.htmlBody = nil; recovered.attachments = []
            try executor.commitSyncPage(MailSyncPage(messages: [recovered], checkpoint: SyncCheckpoint()), accountID: account.id)
            XCTAssertEqual(executor.state.messages[0].body, recovered.body)
            XCTAssertTrue(executor.state.messages[0].contentWarnings.isEmpty)
        }
    }

    func testNormalEmptyBodyAndDifferentProviderIDDoNotInheritCachedContent() throws {
        let account = account(), source = message(account, body: "Existing source text")
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        var different = message(account, id: "different-id", body: "")
        different.contentWarnings = ["Body unavailable."]
        try executor.commitSyncPage(MailSyncPage(messages: [different], checkpoint: SyncCheckpoint()), accountID: account.id)
        let inserted = try XCTUnwrap(executor.state.messages.first { $0.providerID == different.providerID })
        XCTAssertTrue(inserted.body.isEmpty)
        XCTAssertFalse(inserted.contentWarnings.contains { $0.contains("previously cached") })
        var legitimatelyEmpty = source; legitimatelyEmpty.body = ""; legitimatelyEmpty.htmlBody = nil; legitimatelyEmpty.contentWarnings = []
        try executor.commitSyncPage(MailSyncPage(messages: [legitimatelyEmpty], checkpoint: SyncCheckpoint()), accountID: account.id)
        let replaced = try XCTUnwrap(executor.state.messages.first { $0.id == source.id })
        XCTAssertTrue(replaced.body.isEmpty); XCTAssertNil(replaced.htmlBody); XCTAssertTrue(replaced.contentWarnings.isEmpty)
    }
}
