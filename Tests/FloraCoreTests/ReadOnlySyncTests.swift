import Foundation
import XCTest
@testable import FloraCore

@MainActor
private final class ScriptedReadOnlyProvider: ReadOnlyMailProvider {
    let account: MailAccount
    var accountID: UUID { account.id }
    let name = "Read-only test provider"
    var requests: [MailSyncRequest] = []
    var handler: (MailSyncRequest) async throws -> MailSyncPage
    init(account: MailAccount, handler: @escaping (MailSyncRequest) async throws -> MailSyncPage) { self.account = account; self.handler = handler }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [MailFolderDescriptor(id: "INBOX", accountID: accountID, name: "Inbox", role: .inbox)] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage { requests.append(request); return try await handler(request) }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
}

private actor SyncedMailAIClient: LocalModelClient {
    let identity = LocalModelIdentity(runtimeVersion: "0.34.0", model: "local-test", digest: "test-digest")
    var requests: [LocalModelRequest] = []
    private var outputs = [
        #"{"overview":"Review requested.","facts":[]}"#,
        #"{"category":"none","confidence":0.1,"reason":"No category fits."}"#,
        #"{"actions":[]}"#,
        #"{"replies":["Thank you for the message."]}"#,
        #"{"text":"Thank you for the update."}"#
    ]
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { identity }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        requests.append(request)
        return LocalModelOutput(content: outputs.removeFirst(), identity: identity)
    }
}

private enum ProviderAuthorizationFailure: MailSyncFailure {
    case expired
    var syncError: MailSyncError { .authenticationRequired }
}

@MainActor
private final class FailingSyncRepository: MailRepository {
    var snapshot: AppSnapshot?
    var failSaves = false
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if failSaves { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}

@MainActor
final class ReadOnlySyncTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ type: MailProviderType = .gmail) -> MailAccount {
        MailAccount(name: "Read-only test", address: MailAddress(name: "Reader", email: "reader@example.test"), provider: type.title, providerType: type, providerAccountID: UUID().uuidString, credentialReference: MailCredentialReference(id: UUID().uuidString))
    }
    private func message(_ account: MailAccount, id: String = "provider-1", body: String = "Please review the attached draft.") -> MailMessage {
        MailMessage(accountID: account.id, from: MailAddress(name: "Colleague", email: "colleague@example.test"), to: [account.address], subject: "Review request", body: body, date: timestamp, providerThreadID: "thread-1", providerFolderIDs: ["INBOX"]).withProviderID(id)
    }
    private func executor(_ accounts: [MailAccount], messages: [MailMessage] = [], categories: [MailCategory] = []) -> ActionExecutor {
        ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: accounts, messages: messages, categories: categories), now: { self.timestamp })
    }

    func testAllRealMailboxMutationsRejectedBeforeConfirmationOrAutomation() throws {
        for provider in [MailProviderType.gmail, .microsoft, .iCloud] {
            let real = account(provider)
            let mail = message(real)
            let draft = Draft(to: "friend@example.test", subject: "Reply", body: "Hello", replyToMessageID: mail.id, accountID: real.id)
            var snapshot = AppSnapshot(accounts: [real], messages: [mail], drafts: [draft])
            let rule = AutomationRule(name: "Archive", senderEmail: mail.from.email, olderThanDays: 1, enabled: true, authorizedAt: timestamp.addingTimeInterval(-1), accountID: real.id, expiresAt: timestamp.addingTimeInterval(3_600))
            snapshot.rules = [rule]
            let service = ActionExecutor(repository: MemoryMailRepository(), initialState: snapshot, now: { self.timestamp })
            let actions: [ActionType] = [.archive(messageIDs: [mail.id]), .move(messageIDs: [mail.id], folder: .trash), .markRead(messageIDs: [mail.id], isRead: true), .flag(messageIDs: [mail.id], isFlagged: true), .sendDraft(id: draft.id)]
            for action in actions {
                for origin in [ActionOrigin.user, .ai, .automation] {
                    XCTAssertThrowsError(try service.execute(ProposedAction(type: action, explanation: "Test", origin: origin), confirmed: true, ruleID: rule.id)) { XCTAssertEqual($0 as? MailActionError, .readOnlyAccount) }
                }
            }
            XCTAssertEqual(service.state, snapshot)
        }
    }

    func testRealReplyCannotBecomeDemoSendByOmittingOrForgingAccountID() throws {
        let real = account(); let demo = MailAccount(name: "Demo", address: MailAddress(name: "Demo", email: "demo@example.test"))
        let mail = message(real)
        for draftAccountID in [nil, demo.id] {
            let draft = Draft(to: "recipient@example.test", subject: "Reply", body: "Hello", replyToMessageID: mail.id, accountID: draftAccountID)
            let service = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [demo, real], messages: [mail], drafts: [draft]))
            XCTAssertThrowsError(try service.execute(ProposedAction(type: .sendDraft(id: draft.id), explanation: "Send"), confirmed: true)) { XCTAssertEqual($0 as? MailActionError, .readOnlyAccount) }
        }
    }

    func testReadOnlyProviderRejectsWritesEvenWithUserConfirmation() async throws {
        let real = account()
        let provider = ScriptedReadOnlyProvider(account: real) { _ in MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true)) }
        do {
            _ = try await provider.perform(ProposedAction(type: .archive(messageIDs: [UUID()]), explanation: "Archive"), confirmed: true)
            XCTFail("Read-only provider accepted a write")
        } catch { XCTAssertEqual(error as? MailActionError, .readOnlyAccount) }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSyncIsBoundedAndResumesDurableCheckpointAfterRestart() async throws {
        let real = account()
        let repository = MemoryMailRepository()
        let service = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [real]))
        let provider = ScriptedReadOnlyProvider(account: real) { request in
            let offset = Int(request.checkpoint?.continuationToken ?? "0") ?? 0
            let page = (offset..<(offset + request.limit)).map { self.message(real, id: "message-\($0)") }
            return MailSyncPage(messages: page, checkpoint: SyncCheckpoint(opaqueState: "stable-watermark", continuationToken: String(offset + page.count)), hasMore: true)
        }
        let coordinator = MailSyncCoordinator(executor: service, now: { self.timestamp })
        let result = try await coordinator.sync(provider: provider, settings: MailSyncSettings(recentDays: 14, maximumMessages: 3, pageSize: 2))
        XCTAssertEqual(result.receivedMessages, 3); XCTAssertEqual(result.pages, 2); XCTAssertTrue(result.hasMore)
        XCTAssertEqual(provider.requests.map(\.limit), [2, 1])
        XCTAssertEqual(provider.requests.first?.since, timestamp.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(service.state.messages.count, 3)
        let restored = try XCTUnwrap(repository.load())
        let restarted = ActionExecutor(repository: repository, initialState: restored)
        _ = try await MailSyncCoordinator(executor: restarted).sync(provider: provider, settings: MailSyncSettings(maximumMessages: 1, pageSize: 1))
        XCTAssertEqual(provider.requests.last?.checkpoint?.continuationToken, "3")
        XCTAssertEqual(restarted.state.messages.count, 4)
    }

    func testDuplicateAndOverlappingPagesUseAccountScopedStableIdentity() throws {
        let first = account(), second = account(.microsoft)
        let service = executor([first, second])
        let source = message(first)
        try service.commitSyncPage(MailSyncPage(messages: [source, source], checkpoint: SyncCheckpoint()), accountID: first.id)
        var repeated = message(first); repeated.isRead = true
        try service.commitSyncPage(MailSyncPage(messages: [repeated], checkpoint: SyncCheckpoint()), accountID: first.id)
        try service.commitSyncPage(MailSyncPage(messages: [message(second)], checkpoint: SyncCheckpoint()), accountID: second.id)
        XCTAssertEqual(service.state.messages.count, 2)
        XCTAssertEqual(Set(service.state.messages.map(\.id)).count, 2)
        XCTAssertEqual(Set(service.state.messages.map(\.threadID)).count, 2)
        XCTAssertEqual(service.state.messages.first?.id, StableMailIdentity.message(accountID: first.id, providerID: source.providerID))
        XCTAssertEqual(service.state.messages.first?.isRead, true)
    }

    func testCrossAccountPageRejectedAtomically() throws {
        let first = account(), second = account()
        let service = executor([first, second])
        let before = service.state
        XCTAssertThrowsError(try service.commitSyncPage(MailSyncPage(messages: [message(first), message(second)], checkpoint: SyncCheckpoint(opaqueState: "advance")), accountID: first.id)) { XCTAssertEqual($0 as? MailSyncError, .accountMismatch) }
        XCTAssertEqual(service.state, before)
    }

    func testPartialFailurePreservesCommittedMessagesAndCheckpoint() async throws {
        let real = account(); let service = executor([real])
        let provider = ScriptedReadOnlyProvider(account: real) { request in
            if request.checkpoint?.continuationToken == "next" { throw MailSyncError.rateLimited }
            return MailSyncPage(messages: [self.message(real)], checkpoint: SyncCheckpoint(continuationToken: "next"), hasMore: true)
        }
        do { _ = try await MailSyncCoordinator(executor: service).sync(provider: provider); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? MailSyncError, .rateLimited) }
        XCTAssertEqual(service.state.messages.count, 1)
        XCTAssertEqual(service.state.accounts[0].syncState.checkpoint?.continuationToken, "next")
        XCTAssertNil(service.state.accounts[0].syncState.lastSuccessfulSync)
        XCTAssertEqual(service.state.accounts[0].status, .error)
        XCTAssertEqual(service.state.accounts[0].syncState.errorMessage, MailSyncError.rateLimited.localizedDescription)
    }

    func testProviderAuthorizationErrorUsesSharedReauthenticationState() async throws {
        let real = account(); let service = executor([real])
        let provider = ScriptedReadOnlyProvider(account: real) { _ in throw ProviderAuthorizationFailure.expired }
        do { _ = try await MailSyncCoordinator(executor: service).sync(provider: provider); XCTFail("Expected expired authorization") } catch {}
        XCTAssertEqual(service.state.accounts[0].status, .reauthenticationRequired)
        XCTAssertEqual(service.state.accounts[0].syncState.errorMessage, MailSyncError.authenticationRequired.localizedDescription)
    }

    func testFailedPersistenceCannotAdvanceCheckpointOrPublishMessages() throws {
        let real = account(), repository = FailingSyncRepository()
        let service = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [real]))
        try service.commitSyncPage(MailSyncPage(messages: [message(real)], checkpoint: SyncCheckpoint(opaqueState: "first")), accountID: real.id)
        let before = service.state
        repository.failSaves = true
        XCTAssertThrowsError(try service.commitSyncPage(MailSyncPage(messages: [message(real, id: "new")], checkpoint: SyncCheckpoint(opaqueState: "second")), accountID: real.id))
        XCTAssertEqual(service.state, before); XCTAssertEqual(repository.snapshot, before)
    }

    func testRestartNormalizesInterruptedSyncWithoutLosingCheckpoint() {
        var real = account()
        real.status = .syncing; real.syncState.checkpoint = SyncCheckpoint(continuationToken: "resume-here")
        let service = executor([real])
        XCTAssertEqual(service.state.accounts[0].status, .connected)
        XCTAssertEqual(service.state.accounts[0].syncState.checkpoint?.continuationToken, "resume-here")
        XCTAssertNotNil(service.state.accounts[0].syncState.errorMessage)
    }

    func testCancelledSyncPreservesEarlierPageAndStopsPublication() async throws {
        let real = account(); let service = executor([real])
        let provider = ScriptedReadOnlyProvider(account: real) { request in
            if request.checkpoint != nil {
                try await Task.sleep(for: .seconds(60))
                return MailSyncPage(messages: [self.message(real, id: "late")], checkpoint: SyncCheckpoint(initialComplete: true))
            }
            return MailSyncPage(messages: [self.message(real)], checkpoint: SyncCheckpoint(continuationToken: "next"), hasMore: true)
        }
        let task = Task { try await MailSyncCoordinator(executor: service).sync(provider: provider) }
        while provider.requests.count < 2 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(service.state.messages.count, 1)
        XCTAssertEqual(service.state.accounts[0].syncState.checkpoint?.continuationToken, "next")
        XCTAssertEqual(service.state.accounts[0].status, .connected)
    }

    func testUncooperativeProviderCompletionCannotPublishCancelledPage() async {
        let real = account(); let service = executor([real])
        let provider = ScriptedReadOnlyProvider(account: real) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return MailSyncPage(messages: [self.message(real)], checkpoint: SyncCheckpoint(initialComplete: true))
        }
        let task = Task { try await MailSyncCoordinator(executor: service).sync(provider: provider) }
        do { _ = try await task.value; XCTFail("Cancelled completion was published") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(service.state.messages.isEmpty)
        XCTAssertNil(service.state.accounts[0].syncState.checkpoint)
    }

    func testIncrementalUpdatesPreserveAcceptedCategoriesAndInvalidateChangedSource() throws {
        let real = account(); let category = MailCategory(name: "Research")
        let service = executor([real], categories: [category])
        let source = message(real)
        try service.commitSyncPage(MailSyncPage(messages: [source], checkpoint: SyncCheckpoint(initialComplete: true)), accountID: real.id)
        let id = try XCTUnwrap(service.state.messages.first?.id)
        let summary = MessageSummary(messageID: id, headline: "Review", facts: [])
        try service.cacheSummary(summary)
        try service.execute(ProposedAction(type: .classify(messageID: id, categoryID: category.id), explanation: "Local category"))
        var flags = source; flags.isRead = true; flags.isFlagged = true
        try service.commitSyncPage(MailSyncPage(messages: [flags], checkpoint: SyncCheckpoint(initialComplete: true)), accountID: real.id)
        XCTAssertEqual(service.state.summaries, [summary]); XCTAssertEqual(service.state.messages[0].categoryID, category.id)
        var changed = flags; changed.body = "Updated source text"
        try service.commitSyncPage(MailSyncPage(messages: [changed], checkpoint: SyncCheckpoint(initialComplete: true)), accountID: real.id)
        XCTAssertTrue(service.state.summaries.isEmpty); XCTAssertEqual(service.state.messages[0].categoryID, category.id)
        try service.undo()
        XCTAssertNil(service.state.messages[0].categoryID)
        XCTAssertEqual(service.state.messages[0].body, "Updated source text")
        XCTAssertTrue(service.state.messages[0].isRead)
    }

    func testAuthoritativeDeletionIsAccountScopedAndDoesNotReturnThroughUndo() throws {
        let first = account(), second = account(); let category = MailCategory(name: "Research")
        let service = executor([first, second], categories: [category])
        for account in [first, second] { try service.commitSyncPage(MailSyncPage(messages: [message(account)], checkpoint: SyncCheckpoint()), accountID: account.id) }
        let firstID = service.state.messages[0].id
        try service.execute(ProposedAction(type: .classify(messageID: firstID, categoryID: category.id), explanation: "Local"))
        try service.commitSyncPage(MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true), deletedProviderMessageIDs: ["provider-1"]), accountID: first.id)
        try service.undo()
        XCTAssertEqual(service.state.messages.count, 1); XCTAssertEqual(service.state.messages[0].accountID, second.id)
    }

    func testUndoAcceptedClassificationDoesNotRestorePredictionForOldSource() throws {
        let real = account(), category = MailCategory(name: "Research")
        let service = executor([real], categories: [category])
        let source = message(real)
        try service.commitSyncPage(MailSyncPage(messages: [source], checkpoint: SyncCheckpoint()), accountID: real.id)
        let id = service.state.messages[0].id
        let prediction = ClassificationSuggestion(messageID: id, categoryID: category.id, explanation: "Old source evidence")
        try service.cacheClassification(prediction, messageID: id)
        try service.acceptClassification(prediction)
        var changed = source; changed.body = "A completely different message body."
        try service.commitSyncPage(MailSyncPage(messages: [changed], checkpoint: SyncCheckpoint(initialComplete: true)), accountID: real.id)
        try service.undo()
        XCTAssertNil(service.state.messages[0].categoryID)
        XCTAssertTrue(service.state.classifications.isEmpty)
        XCTAssertEqual(service.state.messages[0].body, changed.body)
    }

    func testDownloadedAttachmentMetadataSurvivesUnchangedSync() throws {
        let real = account(); let service = executor([real])
        var source = message(real)
        source.attachments = [MailAttachment(name: "report.pdf", size: 200, providerID: "attachment-1", mimeType: "application/pdf")]
        try service.commitSyncPage(MailSyncPage(messages: [source], checkpoint: SyncCheckpoint()), accountID: real.id)
        let mail = service.state.messages[0]
        try service.markAttachmentDownloaded(messageID: mail.id, attachmentID: mail.attachments[0].id, relativePath: "Attachments/controlled.pdf")
        source.attachments[0].id = UUID()
        try service.commitSyncPage(MailSyncPage(messages: [source], checkpoint: SyncCheckpoint()), accountID: real.id)
        XCTAssertEqual(service.state.messages[0].attachments[0].downloadState, .downloaded)
        XCTAssertEqual(service.state.messages[0].attachments[0].localRelativePath, "Attachments/controlled.pdf")
        XCTAssertThrowsError(try service.markAttachmentDownloaded(messageID: mail.id, attachmentID: mail.attachments[0].id, relativePath: "../escape.pdf"))
    }

    func testLegacySnapshotDecodesWithoutReseeding() throws {
        let snapshot = DemoFixtures.makeSnapshot(now: timestamp)
        let data = try JSONEncoder().encode(snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "remoteFolders")
        json["accounts"] = (json["accounts"] as? [[String: Any]])?.map { value in value.filter { !["providerType", "providerAccountID", "credentialReference", "status", "syncState", "oauthClientID"].contains($0.key) } }
        json["messages"] = (json["messages"] as? [[String: Any]])?.map { value in value.filter { !["providerThreadID", "providerFolderIDs", "htmlBody", "cc", "isImportant"].contains($0.key) } }
        json["preferences"] = ["aiMode": "Demo AI"]
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.messages.map(\.id), snapshot.messages.map(\.id))
        XCTAssertTrue(decoded.accounts.allSatisfy { $0.providerType == .demo })
        XCTAssertTrue(decoded.preferences.showDemoAccounts); XCTAssertEqual(decoded.preferences.mailSyncSettings, MailSyncSettings())
    }

    func testAccountPersistenceContainsReferencesAndPublicConfigurationOnly() throws {
        var real = account(); real.oauthClientID = "public-client-identifier"
        real.syncState = MailSyncState(checkpoint: SyncCheckpoint(opaqueState: "watermark"), lastSuccessfulSync: timestamp)
        let repository = MemoryMailRepository(); let service = ActionExecutor(repository: repository, initialState: AppSnapshot())
        try service.upsertAccount(real)
        let encoded = try JSONEncoder().encode(try XCTUnwrap(repository.load()))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("credentialReference")); XCTAssertTrue(text.contains("public-client-identifier"))
        XCTAssertFalse(text.contains("access_token")); XCTAssertFalse(text.contains("refresh_token")); XCTAssertFalse(text.contains("password"))
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.accounts, [real])
    }

    func testReauthenticationCannotChangeExistingAccountIdentity() throws {
        let real = account(); let service = executor([real])
        var replacement = real; replacement.providerAccountID = "another-user"
        XCTAssertThrowsError(try service.upsertAccount(replacement)) { XCTAssertEqual($0 as? MailSyncError, .accountMismatch) }
        XCTAssertEqual(service.state.accounts, [real])
    }

    func testDemoProviderDoesNotRequireCredentialsWhenRealAccountsExist() async throws {
        let fixture = DemoFixtures.makeSnapshot(now: timestamp)
        let service = ActionExecutor(repository: MemoryMailRepository(), initialState: fixture)
        let real = account()
        try service.upsertAccount(real)
        try service.commitSyncPage(MailSyncPage(messages: [message(real)], checkpoint: SyncCheckpoint()), accountID: real.id)
        let provider = DemoMailProvider(executor: service)
        let messages = try await provider.fetchMessages(folder: .inbox)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertFalse(messages.contains { $0.accountID == real.id })
        let demoAccounts = try await provider.fetchAccounts()
        XCTAssertFalse(demoAccounts.contains { $0.id == real.id })
        let first = try XCTUnwrap(messages.first)
        _ = try await provider.perform(ProposedAction(type: .archive(messageIDs: [first.id]), explanation: "Demo archive"))
        XCTAssertEqual(service.state.messages.first { $0.id == first.id }?.folder, .archive)
    }

    func testRealMailAndFolderCheckpointPersistInRestrictedLocalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraSyncTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONMailRepository(url: directory.appendingPathComponent("mail.json"))
        let real = account()
        let service = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [real]))
        let folders = [MailFolderDescriptor(id: "INBOX", accountID: real.id, name: "Inbox", role: .inbox, isLabel: true)]
        try service.updateRemoteFolders(folders, accountID: real.id)
        try service.commitSyncPage(MailSyncPage(messages: [message(real)], checkpoint: SyncCheckpoint(opaqueState: "delta-checkpoint", initialComplete: true)), accountID: real.id)
        let loaded = try XCTUnwrap(JSONMailRepository(url: repository.url).load())
        XCTAssertEqual(loaded.messages, service.state.messages)
        XCTAssertEqual(loaded.remoteFolders, folders)
        XCTAssertEqual(loaded.accounts[0].syncState.checkpoint?.opaqueState, "delta-checkpoint")
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRemoteFlagRefreshDoesNotReadownloadOrCrossAccounts() throws {
        let first = account(), second = account()
        let service = executor([first, second])
        for account in [first, second] { try service.commitSyncPage(MailSyncPage(messages: [message(account)], checkpoint: SyncCheckpoint()), accountID: account.id) }
        let oldBody = service.state.messages[0].body
        try service.commitSyncPage(MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true), messageStateUpdates: [MailRemoteStateUpdate(providerID: "provider-1", isRead: true, isFlagged: true)]), accountID: first.id)
        XCTAssertTrue(service.state.messages[0].isRead); XCTAssertTrue(service.state.messages[0].isFlagged)
        XCTAssertFalse(service.state.messages[1].isRead); XCTAssertFalse(service.state.messages[1].isFlagged)
        XCTAssertEqual(service.state.messages[0].body, oldBody)
    }

    func testLocalAIReceivesOnlySelectedSynchronizedMessageAndExplicitWritingContext() async throws {
        let first = account(), otherAccount = account(.microsoft)
        let service = executor([first, otherAccount])
        for account in [first, otherAccount] {
            let body = account.id == first.id ? "SELECTED_MESSAGE_CONTEXT" : "UNRELATED_ACCOUNT_PRIVATE_CONTENT"
            try service.commitSyncPage(MailSyncPage(messages: [message(account, body: body)], checkpoint: SyncCheckpoint()), accountID: account.id)
        }
        let selected = try XCTUnwrap(service.state.messages.first { $0.accountID == first.id })
        let client = SyncedMailAIClient()
        let provider: any AIProvider = LocalAIProvider(client: client)
        _ = try await provider.summarize(selected)
        _ = try await provider.classify(selected, categories: [MailCategory(name: "Research")])
        _ = try await provider.extractActions(selected)
        _ = try await provider.generateReplies(selected)
        _ = try await provider.rewrite("Thank you for update.", tool: .proofread, context: selected)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 5)
        for request in requests {
            XCTAssertTrue(request.prompt.contains("SELECTED_MESSAGE_CONTEXT"))
            XCTAssertFalse(request.prompt.contains("UNRELATED_ACCOUNT_PRIVATE_CONTENT"))
            XCTAssertFalse(request.prompt.contains(first.address.email))
            XCTAssertFalse(request.prompt.contains(try XCTUnwrap(first.credentialReference?.id)))
        }
        XCTAssertFalse(requests[0].prompt.contains("Thank you for update."))
        XCTAssertTrue(requests[4].prompt.contains("Thank you for update."))
        XCTAssertTrue(service.state.history.isEmpty)
    }
}

private extension MailMessage {
    func withProviderID(_ value: String) -> Self { var copy = self; copy.providerID = value; return copy }
}
