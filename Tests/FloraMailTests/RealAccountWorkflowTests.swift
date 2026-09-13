import Foundation
import Testing
@testable import FloraCore
@testable import FloraMail

private actor WorkflowLocalClient: LocalModelClient {
    var requests: [LocalModelRequest] = []
    private let identity = LocalModelIdentity(runtimeVersion: "0.34.0", model: "workflow-model", digest: "workflow-digest")
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { identity }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        requests.append(request)
        let response = request.schemaJSON.contains("overview") ? #"{"overview":"Selected message summary.","facts":[]}"# : #"{"text":"Thank you for the update."}"#
        return LocalModelOutput(content: response, identity: identity)
    }
}

private actor WorkflowPageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var wasCancelled = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func noteCancellation() { wasCancelled = true }
}

private actor WorkflowGatedCredentialStore: CredentialStore {
    private var items: [String: Data]
    private let blockedReference: MailCredentialReference
    private let gate: WorkflowPageGate
    private(set) var deletedReferences: [MailCredentialReference] = []
    private(set) var writtenReferences: [MailCredentialReference] = []
    init(reference: MailCredentialReference, gate: WorkflowPageGate) {
        blockedReference = reference; self.gate = gate
        items = [reference.id: Data("synthetic-fixture-credential".utf8)]
    }
    func read(reference: MailCredentialReference) -> Data? { items[reference.id] }
    func write(_ data: Data, reference: MailCredentialReference) { writtenReferences.append(reference); items[reference.id] = data }
    func delete(reference: MailCredentialReference) async {
        deletedReferences.append(reference)
        if reference == blockedReference { await gate.wait() }
        items[reference.id] = nil
    }
}

@MainActor
private final class WorkflowRemoteProvider: ReadOnlyMailProvider {
    let account: MailAccount
    let name = "Read-only workflow fixture"
    var accountID: UUID { account.id }
    private(set) var calls = 0
    var page: (MailSyncRequest, Int) async throws -> MailSyncPage
    init(account: MailAccount, page: @escaping (MailSyncRequest, Int) async throws -> MailSyncPage) { self.account = account; self.page = page }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [MailFolderDescriptor(id: "INBOX", accountID: accountID, name: "Inbox", role: .inbox)] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage { calls += 1; return try await page(request, calls) }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
}

@MainActor
struct RealAccountWorkflowTests {
    private func snapshot() -> AppSnapshot {
        let demo = MailAccount(name: "Demo", address: MailAddress(name: "Demo", email: "demo@example.test"))
        let gmail = MailAccount(name: "Gmail fixture", address: MailAddress(name: "First", email: "first@example.test"), provider: "Gmail", providerType: .gmail, providerAccountID: "first-provider-subject", credentialReference: MailCredentialReference(id: "first-credential-reference"), oauthClientID: "public-google-client")
        let microsoft = MailAccount(name: "Microsoft fixture", address: MailAddress(name: "Second", email: "second@example.test"), provider: "Microsoft", providerType: .microsoft, providerAccountID: "second-provider-subject", credentialReference: MailCredentialReference(id: "second-credential-reference"), oauthClientID: "public-microsoft-client")
        let accounts = [demo, gmail, microsoft]
        let messages = accounts.enumerated().map { index, account in
            MailMessage(id: StableMailIdentity.message(accountID: account.id, providerID: "same-provider-id"), providerID: "same-provider-id", accountID: account.id,
                        threadID: StableMailIdentity.thread(accountID: account.id, providerID: "same-thread-id"), from: MailAddress(name: "Colleague", email: "colleague@example.test"), to: [account.address],
                        subject: "Shared review request", body: "Shared review request. PRIVATE_ACCOUNT_\(index)_CONTEXT", providerThreadID: "same-thread-id", providerFolderIDs: ["INBOX"])
        }
        let drafts = messages.map { Draft(to: $0.from.email, subject: "Re: Shared review request", body: "Saved draft.", replyToMessageID: $0.id, accountID: $0.accountID) }
        return AppSnapshot(accounts: accounts, messages: messages, categories: [MailCategory(name: "Research"), MailCategory(name: "Other")], drafts: drafts,
                           remoteFolders: accounts.filter(\.isReadOnly).map { MailFolderDescriptor(id: "INBOX", accountID: $0.id, name: "Inbox", role: .inbox) })
    }

    private func store(_ snapshot: AppSnapshot) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraRealWorkflow-\(UUID())")
        let url = directory.appendingPathComponent("mail.json")
        try JSONMailRepository(url: url).save(snapshot)
        return url
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), "The asynchronous fixture did not reach its expected state")
    }
    private func waitUntilAsync(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate(), "The asynchronous fixture did not reach its expected state")
    }

    @Test func textAndAISearchStayWithinSelectedRealAccount() async throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let client = WorkflowLocalClient()
        let model = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        let first = original.accounts[1], second = original.accounts[2]
        model.setDemoMode(false); model.navigate(.account(first.id)); model.searchText = "Shared"
        #expect(model.visibleMessages.map(\.accountID) == [first.id])
        let assistant = try await model.assistantSearch("Shared")
        #expect(assistant.messages.map(\.accountID) == [first.id])
        model.semanticSearch(); try await waitUntil { !model.searching }
        #expect(model.visibleMessages.map(\.accountID) == [first.id])
        #expect(Set(model.semanticResults ?? []).isSubset(of: Set(original.messages.filter { $0.accountID == first.id }.map(\.id))))

        model.navigate(.providerFolder(accountID: second.id, folderID: "INBOX")); model.searchText = "Shared"
        #expect(model.visibleMessages.map(\.accountID) == [second.id])
        model.updateAIMode(.local)
        model.semanticSearch(); try await waitUntil { !model.searching }
        #expect(model.searchNotice?.contains("text matches") == true)
        #expect(model.visibleMessages.map(\.accountID) == [second.id])
        let fallback = try await model.assistantSearch("Shared")
        #expect(fallback.messages.map(\.accountID) == [second.id])
        let expansionRequests = await client.requests
        #expect(!expansionRequests.isEmpty)
        #expect(expansionRequests.allSatisfy { !$0.prompt.contains("PRIVATE_ACCOUNT_") && !$0.prompt.contains("colleague@example.test") })
        // Expansion receives the query only; mailbox matching stays on-device.
    }

    @Test func demoVisibilitySeparatesAccountsMessagesAndSavedDrafts() throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        #expect(model.displayedAccounts.map(\.providerType) == [.demo])
        #expect(model.scopedMessages.map(\.accountID) == [original.accounts[0].id])
        #expect(model.visibleDrafts.map(\.accountID) == [original.accounts[0].id])
        model.openMessage(original.messages[0].id)
        model.setDemoMode(false)
        #expect(model.selectedMessageID == nil)
        #expect(Set(model.displayedAccounts.map(\.providerType)) == [.gmail, .microsoft])
        #expect(Set(model.scopedMessages.map(\.accountID)) == Set(original.accounts.dropFirst().map(\.id)))
        #expect(Set(model.visibleDrafts.compactMap(\.accountID)) == Set(original.accounts.dropFirst().map(\.id)))
        model.setDemoMode(true)
        #expect(model.scopedMessages.map(\.accountID) == [original.accounts[0].id])
    }

    @Test func sourceLinksPreserveSingleAccountScopeAndExplicitlySwitchDemoMode() throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        let demo = original.accounts[0], first = original.accounts[1], second = original.accounts[2]
        model.setDemoMode(false); model.navigate(.account(first.id)); model.searchText = "Shared"
        model.openMessage(original.messages[1].id)
        #expect(model.destination == .account(first.id))
        #expect(model.searchText == "Shared")
        #expect(model.accountScopeID == first.id)
        #expect(model.visibleMessages.map(\.accountID) == [first.id])

        model.navigate(.providerFolder(accountID: first.id, folderID: "INBOX"))
        model.openMessage(original.messages[1].id)
        #expect(model.destination == .providerFolder(accountID: first.id, folderID: "INBOX"))
        model.openMessage(original.messages[2].id)
        #expect(model.destination == .account(second.id))
        #expect(model.selectedMessageID == original.messages[2].id)
        #expect(model.visibleMessages.map(\.accountID) == [second.id])

        model.openMessage(original.messages[0].id)
        #expect(model.state.preferences.showDemoAccounts)
        #expect(model.destination == .account(demo.id))
        #expect(model.selectedMessageID == original.messages[0].id)
        #expect(model.visibleMessages.map(\.accountID) == [demo.id])
        model.openMessage(original.messages[1].id)
        #expect(!model.state.preferences.showDemoAccounts)
        #expect(model.destination == .account(first.id))
        #expect(model.selectedMessageID == original.messages[1].id)
        #expect(model.visibleMessages.map(\.accountID) == [first.id])
    }

    @Test func realSourceReplyAndForwardStayReadOnlyEvenInDemoMode() throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        let source = original.messages[1]
        model.compose(replyTo: source, suggestedText: "Thank you for the update.")
        let reply = try #require(model.composingDraft)
        #expect(reply.accountID == source.accountID); #expect(reply.replyToMessageID == source.id)
        #expect(!model.canSendDemo(reply)); #expect(!model.sendDraft(reply))
        #expect(model.state.history.isEmpty)
        var spoofed = reply; spoofed.accountID = original.accounts[0].id
        #expect(!model.canSendDemo(spoofed)); #expect(!model.sendDraft(spoofed))
        var omitted = reply; omitted.accountID = nil
        #expect(!model.canSendDemo(omitted)); #expect(!model.sendDraft(omitted))
        model.composingDraft = nil
        model.compose(replyTo: source, forward: true)
        let forward = try #require(model.composingDraft)
        #expect(forward.replyToMessageID == nil); #expect(forward.accountID == source.accountID)
        #expect(!model.canSendDemo(forward)); #expect(!model.sendDraft(forward))
        #expect(model.state.messages == original.messages)
    }

    @Test func selectedAccountIsUsedForNewDraftAndDanglingReplyFailsClosed() throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        model.setDemoMode(false); model.navigate(.account(original.accounts[2].id)); model.compose()
        #expect(model.composingDraft?.accountID == original.accounts[2].id)
        model.setDemoMode(true)
        let orphaned = Draft(to: "recipient@example.test", subject: "Reply", body: "Hello", replyToMessageID: UUID(), accountID: original.accounts[0].id)
        #expect(!model.canSendDemo(orphaned)); #expect(!model.sendDraft(orphaned))
    }

    @Test func realModeWithoutAccountsCannotCreateAnAnonymousDemoDraft() throws {
        let original = DemoFixtures.makeSnapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        model.setDemoMode(false)
        #expect(model.displayedAccounts.isEmpty); #expect(!model.canCompose)
        model.compose()
        #expect(model.composingDraft == nil)
        #expect(model.state.drafts == original.drafts)
        model.setDemoMode(true)
        #expect(model.canCompose)
        model.compose()
        #expect(model.composingDraft?.accountID == original.accounts.first?.id)
        #expect(model.composingDraft != nil)
    }

    @Test func openingRealMessageDoesNotChangeReadFlagOrPermitMailboxControls() throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        model.setDemoMode(false); model.navigate(.account(original.accounts[1].id))
        let source = original.messages[1]
        model.openMessage(source.id)
        #expect(model.selectedMessageID == source.id)
        #expect(model.selectedMessage?.isRead == false)
        model.archive(source); model.trash(source); model.toggleFlag(source); model.toggleRead(source)
        #expect(model.state.messages == original.messages)
        #expect(model.state.history.isEmpty)
        #expect(model.errorMessage == RemoteActionError.permissionDenied.localizedDescription)
    }

    @Test func cachedMailAccountConfigurationAndLocalPreferencesSurviveRestart() throws {
        var original = snapshot()
        original.accounts[1].syncState = MailSyncState(checkpoint: SyncCheckpoint(opaqueState: "saved-delta", initialComplete: true), lastSuccessfulSync: Date(timeIntervalSince1970: 1_800_000_000))
        let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        let configuration = AIModelConfiguration(endpoint: "http://127.0.0.1:11435", model: "configured-local-model", timeoutSeconds: 45)
        let settings = MailSyncSettings(recentDays: 14, maximumMessages: 75, pageSize: 25)
        model.setDemoMode(false); model.saveSyncSettings(settings)
        #expect(model.saveLocalConfiguration(configuration)); model.updateAIMode(.local)
        let reopened = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: MemoryCredentialStore())
        #expect(reopened.storageWarning == nil)
        #expect(reopened.state.messages == original.messages)
        #expect(reopened.state.remoteFolders == original.remoteFolders)
        #expect(reopened.state.accounts == original.accounts)
        #expect(reopened.state.preferences.localAI == configuration)
        #expect(reopened.state.preferences.mailSyncSettings == settings)
        #expect(reopened.state.preferences.aiMode == .local)
        #expect(!reopened.state.preferences.showDemoAccounts)
        #expect(reopened.accountController.syncProgress.isEmpty)
        #expect(reopened.selectedMessageID == nil)
    }

    @Test func localSummaryAndWritingContextUseOnlySelectedCachedAccountMail() async throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let client = WorkflowLocalClient()
        let model = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        model.setDemoMode(false); model.navigate(.account(original.accounts[1].id)); model.updateAIMode(.local)
        let source = original.messages[1]
        let summary = try await model.summary(for: source)
        #expect(summary.messageID == source.id)
        _ = try await model.rewrite("Thank you for update.", tool: .proofread, replyToMessageID: source.id, accountID: source.accountID)
        _ = try await model.rewrite("Thank you for update.", tool: .proofread, replyToMessageID: original.messages[2].id, accountID: source.accountID)
        let requests = await client.requests
        #expect(requests.count == 3)
        #expect(requests[0].prompt.contains("PRIVATE_ACCOUNT_1_CONTEXT"))
        #expect(requests[1].prompt.contains("PRIVATE_ACCOUNT_1_CONTEXT"))
        #expect(!requests[2].prompt.contains("PRIVATE_ACCOUNT_1_CONTEXT"))
        #expect(!requests.contains { $0.prompt.contains("PRIVATE_ACCOUNT_0_CONTEXT") || $0.prompt.contains("PRIVATE_ACCOUNT_2_CONTEXT") })
        #expect(model.state.history.isEmpty)
    }

    @Test func disconnectWaitsForCancelledSyncAndRetainsLatestCommittedCheckpoint() async throws {
        let original = snapshot(); let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let account = original.accounts[1], reference = try #require(account.credentialReference)
        let credentials = MemoryCredentialStore()
        await credentials.write(Data("synthetic-test-credential".utf8), reference: reference)
        let gate = WorkflowPageGate()
        defer { Task { await gate.release() } }
        let provider = WorkflowRemoteProvider(account: account) { _, call in
            if call == 1 {
                var fetched = original.messages[1]; fetched.providerID = "newly-synchronized"; fetched.id = UUID()
                return MailSyncPage(messages: [fetched], checkpoint: SyncCheckpoint(continuationToken: "committed-first-page"), hasMore: true)
            }
            // Observe cancellation while deliberately withholding completion.
            await withTaskCancellationHandler { await gate.wait() } onCancel: {
                Task { await gate.noteCancellation() }
            }
            var late = original.messages[1]; late.providerID = "cancelled-second-page"; late.id = UUID()
            return MailSyncPage(messages: [late], checkpoint: SyncCheckpoint(initialComplete: true))
        }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: credentials, remoteProviderFactory: { _ in provider })
        model.accountController.syncNow(account.id)
        try await waitUntil { provider.calls == 2 }
        #expect(model.state.accounts[1].syncState.checkpoint?.continuationToken == "committed-first-page")
        let disconnect = Task { await model.accountController.disconnect(account.id) }
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.wasCancelled), ContinuousClock.now < cancellationDeadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await gate.wasCancelled)
        #expect(await credentials.read(reference: reference) != nil)
        await gate.release(); await disconnect.value
        #expect(!model.accountController.isSyncing(account.id))
        #expect(await credentials.read(reference: reference) == nil)
        let disconnected = try #require(model.state.accounts.first { $0.id == account.id })
        #expect(disconnected.status == .disconnected); #expect(disconnected.credentialReference == nil)
        #expect(disconnected.syncState.checkpoint?.continuationToken == "committed-first-page")
        #expect(model.state.messages.contains { $0.providerID == "newly-synchronized" })
        #expect(!model.state.messages.contains { $0.providerID == "cancelled-second-page" })
        let reopened = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: credentials)
        #expect(reopened.state.messages == model.state.messages)
        #expect(reopened.state.accounts.first { $0.id == account.id } == disconnected)
    }

    @Test(arguments: [MailProviderType.gmail, .iCloud])
    func pendingCredentialDeletionBlocksReauthenticationAndCheckpointReset(providerType: MailProviderType) async throws {
        var original = snapshot()
        var account = original.accounts[1]
        account.providerType = providerType; account.provider = providerType.title
        if providerType == .iCloud {
            account.address.email = "fixture@icloud.com"; account.providerAccountID = account.address.email
        }
        let checkpoint = SyncCheckpoint(opaqueState: "must-not-reset-during-disconnect", initialComplete: true)
        account.syncState.checkpoint = checkpoint
        original.accounts[1] = account
        let url = try store(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reference = try #require(account.credentialReference)
        let gate = WorkflowPageGate()
        defer { Task { await gate.release() } }
        let credentials = WorkflowGatedCredentialStore(reference: reference, gate: gate)
        let provider = WorkflowRemoteProvider(account: account) { _, _ in MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true)) }
        let model = AppModel(storageURL: url, localClient: WorkflowLocalClient(), credentials: credentials, remoteProviderFactory: { _ in provider })
        let controller = model.accountController
        let disconnect = Task { await controller.disconnect(account.id) }
        try await waitUntilAsync { await credentials.deletedReferences == [reference] }
        #expect(controller.isDisconnecting(account.id))
        let priorError = controller.connectionError, priorMessage = controller.connectionMessage

        // Invalid inputs ensure a regression cannot launch a browser or contact
        // iCloud. Without the lifecycle guard each path would alter error state
        // and attempt cleanup of an extra credential reference.
        #expect(!(await controller.connectOAuth(provider: .gmail, clientID: "", existingAccount: account)))
        #expect(!(await controller.connectICloud(email: "invalid", appSpecificPassword: "", existingAccount: account)))
        #expect(controller.connectionError == priorError)
        #expect(controller.connectionMessage == priorMessage)
        #expect(!controller.connecting)
        #expect(await credentials.writtenReferences.isEmpty)
        #expect(await credentials.deletedReferences == [reference])
        controller.restartRecentSync(account.id); controller.syncNow(account.id)
        #expect(model.state.accounts.first { $0.id == account.id }?.syncState.checkpoint == checkpoint)
        #expect(!controller.isSyncing(account.id)); #expect(provider.calls == 0)

        await gate.release(); await disconnect.value
        #expect(!controller.isDisconnecting(account.id))
        #expect(model.state.accounts.first { $0.id == account.id }?.status == .disconnected)
        #expect(model.state.accounts.first { $0.id == account.id }?.syncState.checkpoint == checkpoint)
        #expect(await credentials.read(reference: reference) == nil)

        // Once disconnect finishes, a fresh attempt reaches normal validation.
        #expect(!(await controller.connectOAuth(provider: .gmail, clientID: "", existingAccount: account)))
        #expect(controller.connectionError != nil)
        #expect(await credentials.deletedReferences.count == 2)
    }
}
