import Foundation
import Testing
import FloraCore
@testable import FloraMail

@MainActor
private final class AutomationFixtureRepository: MailRepository {
    var snapshot: AppSnapshot?
    var failWrites = false
    init(_ snapshot: AppSnapshot) { self.snapshot = snapshot }
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if failWrites { throw RepositoryError.unreadableStore }
        self.snapshot = snapshot
    }
}

@MainActor
private final class AutomationFixtureWriter: ReadOnlyMailProvider, RemoteMailWriter {
    let account: MailAccount
    var accountID: UUID { account.id }
    let name = "Fictional automation fixture"
    var requests: [AuthorizedRemoteAction] = []
    var pauseAcknowledgement = false
    var uncertain = false
    var pauseSync = false
    var syncCancelled = false
    private var acknowledgement: CheckedContinuation<Void, Never>?
    private var dispatchObserver: CheckedContinuation<Void, Never>?
    private var syncObserver: CheckedContinuation<Void, Never>?
    private var syncStarted = false
    init(account: MailAccount) { self.account = account }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        syncStarted = true; syncObserver?.resume(); syncObserver = nil
        if pauseSync {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { syncCancelled = true; throw error }
        }
        return MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true))
    }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        requests.append(request)
        if pauseAcknowledgement {
            await withCheckedContinuation { continuation in
                acknowledgement = continuation
                dispatchObserver?.resume(); dispatchObserver = nil
            }
        } else { dispatchObserver?.resume(); dispatchObserver = nil }
        if uncertain { throw RemoteActionError.outcomeUnknown }
        var messages = request.messages
        for index in messages.indices {
            switch request.action {
            case .markRead(_, let value): messages[index].isRead = value
            case .archive: messages[index].folder = .archive; messages[index].providerFolderIDs = []
            default: throw RemoteActionError.invalidRequest
            }
        }
        return RemoteActionReceipt(messages: messages)
    }
    func waitForDispatch() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { dispatchObserver = $0 }
    }
    func waitForSync() async {
        if syncStarted { return }
        await withCheckedContinuation { syncObserver = $0 }
    }
    func acknowledge() { acknowledgement?.resume(); acknowledgement = nil }
}

@MainActor
struct AutomationControllerTests {
    private struct Fixture {
        let account: MailAccount
        let messages: [MailMessage]
        let writer: AutomationFixtureWriter
        let repository: AutomationFixtureRepository
        let executor: ActionExecutor
        let accounts: AccountController
        let controller: AutomationController
        let rule: AutomationRule
    }
    private func fixture(level: AutomationLevel = .rules, remote: Bool = true, count: Int = 2, storageAvailable: Bool = true) throws -> Fixture {
        let account = MailAccount(name: "Fictional automation account", address: MailAddress(name: "Reader", email: "reader@example.test"), providerType: remote ? .gmail : .demo,
                                  credentialReference: remote ? MailCredentialReference(id: "fictional-reference") : nil, oauthAccessLevel: .readWrite,
                                  writePermission: .userAuthorized, writeAuthorizedAt: Date().addingTimeInterval(-60))
        let sender = MailAddress(name: "Fictional newsletter", email: "news@example.test")
        let messages = (0..<count).map { index in
            MailMessage(providerID: "fictional-\(index)", accountID: account.id, from: sender, to: [account.address], subject: "Fictional update \(index)", body: "A fixture with no real recipient.", date: Date().addingTimeInterval(-Double(40 + index) * 86_400))
        }
        let other = MailAccount(name: "Separate demo", address: MailAddress(name: "Other", email: "other@example.test"))
        let otherMessage = MailMessage(providerID: "fictional-0", accountID: other.id, from: sender, to: [other.address], subject: "Other account", body: "Must remain unchanged.", date: Date().addingTimeInterval(-45 * 86_400))
        let state = AppSnapshot(accounts: [account, other], messages: messages + [otherMessage], preferences: UserPreferences(automationLevel: level))
        let repository = AutomationFixtureRepository(state)
        let executor = ActionExecutor(repository: repository, initialState: state)
        let writer = AutomationFixtureWriter(account: account)
        let accounts = AccountController(executor: executor, storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("FloraAutomation-\(UUID())/fixture.json"), storageAvailable: storageAvailable, providerOverride: { _ in writer })
        let controller = AutomationController(executor: executor, accountController: accounts, storageAvailable: storageAvailable)
        let rule = AutomationRule(name: "Read older fictional newsletters", senderEmail: sender.email, olderThanDays: 30, enabled: true, accountID: account.id, action: .markRead, maxMessages: 10, expiresAt: Date().addingTimeInterval(86_400))
        return Fixture(account: account, messages: messages, writer: writer, repository: repository, executor: executor, accounts: accounts, controller: controller, rule: rule)
    }
    private func prepare(_ fixture: Fixture) throws {
        fixture.controller.saveRule(fixture.rule, confirmed: true)
        #expect(fixture.controller.errorMessage == nil)
        fixture.controller.preview(rule: try #require(fixture.controller.rules.first))
        #expect(fixture.controller.errorMessage == nil)
        #expect(fixture.controller.preview != nil)
    }

    @Test func savedRuleAndPreviewNeverStartWorkAndScopeIsVisible() throws {
        let f = try fixture(); try prepare(f)
        #expect(f.writer.requests.isEmpty)
        #expect(f.controller.matches.count == 2)
        #expect(f.controller.matches.allSatisfy { $0.accountID == f.account.id })
        #expect(f.controller.history.isEmpty)
        #expect(f.executor.state.messages.allSatisfy { !$0.isRead })
        #expect(f.controller.activeGrant == nil)
    }

    @Test func runUsesCentralGatewayAndPreservesOtherAccount() async throws {
        let f = try fixture(); try prepare(f)
        var changes = 0; f.controller.onChange = { changes += 1 }
        await f.controller.runPreview()
        #expect(f.writer.requests.count == 2)
        #expect(f.writer.requests.allSatisfy { $0.account.id == f.account.id })
        #expect(f.executor.state.remoteActionHistory.allSatisfy { $0.proposal.origin == .automation && $0.status == .completed })
        #expect(f.executor.state.messages.filter { $0.accountID == f.account.id }.allSatisfy { $0.isRead })
        #expect(f.executor.state.messages.filter { $0.accountID != f.account.id }.allSatisfy { !$0.isRead })
        #expect(f.controller.lastRun?.status == .completed)
        #expect(f.controller.preview == nil && !f.controller.isRunning)
        #expect(changes > 0 && f.accounts.writingAccounts.isEmpty)
    }

    @Test func demoRunRequiresNoCredentialsOrNetworkWriter() async throws {
        let f = try fixture(remote: false); try prepare(f)
        await f.controller.runPreview()
        #expect(f.writer.requests.isEmpty)
        #expect(f.controller.lastRun?.status == .completed)
        #expect(f.executor.state.history.count == 2)
        #expect(f.executor.state.history.allSatisfy { $0.proposal.origin == .automation })
    }

    @Test func unavailableDurableStorageCannotAuthorizeOrRun() async throws {
        let f = try fixture(storageAvailable: false)
        f.controller.saveRule(f.rule, confirmed: true)
        #expect(f.controller.errorMessage != nil && f.controller.rules.isEmpty)
        await f.controller.runPreview()
        #expect(f.writer.requests.isEmpty && f.controller.history.isEmpty)
    }

    @Test func failedRunJournalNeverCallsWriter() async throws {
        let f = try fixture(); try prepare(f)
        f.repository.failWrites = true
        await f.controller.runPreview()
        #expect(f.writer.requests.isEmpty)
        #expect(f.controller.errorMessage != nil && !f.controller.isRunning)
    }

    @Test func changedMailboxPermissionInvalidatesPreviewBeforeDispatch() async throws {
        let f = try fixture(); try prepare(f)
        var account = f.account; account.writePermission = .readOnly; account.writeAuthorizedAt = nil
        try f.executor.updateAccount(account)
        await f.controller.runPreview()
        #expect(f.writer.requests.isEmpty)
        #expect(f.controller.errorMessage != nil)
    }

    @Test func oneRunGrantIsSeparateFromPreviewAndConsumedOnce() async throws {
        let f = try fixture(level: .delegated); try prepare(f)
        f.controller.authorizeDelegation(expiresAt: Date().addingTimeInterval(600), confirmed: true)
        let grant = try #require(f.controller.activeGrant)
        #expect(!grant.isConsumed && f.writer.requests.isEmpty)
        await f.controller.runPreview()
        #expect(f.controller.grants.first(where: { $0.id == grant.id })?.isConsumed == true)
        #expect(f.controller.lastRun?.grantID == grant.id)
        await f.controller.runPreview()
        #expect(f.writer.requests.count == 2)
    }

    @Test func editedRuleClearsDisplayedGrantAndCannotRunOldPreview() async throws {
        let f = try fixture(level: .delegated); try prepare(f)
        f.controller.authorizeDelegation(expiresAt: Date().addingTimeInterval(600), confirmed: true)
        let grantID = try #require(f.controller.activeGrant?.id)
        var updated = try #require(f.controller.rules.first); updated.senderEmail = "different@example.test"
        f.controller.saveRule(updated, confirmed: true)
        #expect(f.controller.activeGrant == nil && f.controller.preview == nil && f.controller.matches.isEmpty)
        #expect(f.controller.grants.first(where: { $0.id == grantID })?.isRevoked == true)
        await f.controller.runPreview()
        #expect(f.writer.requests.isEmpty)
    }

    @Test func persistedHistoryReloadDoesNotResumeOrAuthorizeAnotherRun() async throws {
        let f = try fixture(level: .delegated); try prepare(f)
        f.controller.authorizeDelegation(expiresAt: Date().addingTimeInterval(600), confirmed: true)
        await f.controller.runPreview()
        let stored = try #require(f.repository.snapshot)
        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(stored))
        let executor = ActionExecutor(repository: MemoryMailRepository(snapshot: snapshot), initialState: snapshot)
        let accounts = AccountController(executor: executor, storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("FloraAutomationReload-\(UUID())/fixture.json"), storageAvailable: true, providerOverride: { _ in f.writer })
        let reloaded = AutomationController(executor: executor, accountController: accounts)
        #expect(reloaded.rules.count == 1 && reloaded.history.count == 1)
        #expect(reloaded.grants.first?.isConsumed == true)
        #expect(reloaded.preview == nil && reloaded.activeGrant == nil && !reloaded.isRunning)
        await reloaded.runPreview()
        #expect(f.writer.requests.count == 2)
    }

    @Test func cancellingWaitsForAcknowledgementAndStopsLaterMessages() async throws {
        let f = try fixture(); try prepare(f)
        f.writer.pauseAcknowledgement = true
        let run = Task { await f.controller.runPreview() }
        await f.writer.waitForDispatch()
        f.controller.cancel()
        #expect(f.controller.isRunning && f.accounts.writingAccounts.contains(f.account.id))
        f.writer.acknowledge(); await run.value
        #expect(f.writer.requests.count == 1)
        #expect(f.controller.lastRun?.completedMessageIDs.count == 1)
        #expect(f.controller.lastRun?.status == .cancelled)
        #expect(!f.controller.isRunning && f.accounts.writingAccounts.isEmpty)
    }

    @Test func revocationDuringRunPreventsTheNextDispatch() async throws {
        let f = try fixture(); try prepare(f)
        f.writer.pauseAcknowledgement = true
        let run = Task { await f.controller.runPreview() }
        await f.writer.waitForDispatch()
        f.controller.revokeRule(id: f.rule.id)
        f.writer.acknowledge(); await run.value
        #expect(f.writer.requests.count == 1)
        #expect(f.controller.rules.first?.enabled == false)
        #expect(f.controller.lastRun?.completedMessageIDs.count == 1)
        #expect(f.controller.lastRun?.status != .completed)
    }

    @Test func uncertainResultStopsRunWithoutRetrying() async throws {
        let f = try fixture(); try prepare(f); f.writer.uncertain = true
        await f.controller.runPreview()
        #expect(f.writer.requests.count == 1)
        #expect(f.controller.lastRun?.status == .outcomeUnknown)
        #expect(f.controller.errorMessage != nil)
        await f.controller.runPreview()
        #expect(f.writer.requests.count == 1)
    }

    @Test func accountSerializationCancelsSyncBeforeWriting() async throws {
        let f = try fixture(); try prepare(f)
        f.writer.pauseSync = true
        f.accounts.syncNow(f.account.id)
        await f.writer.waitForSync()
        await f.controller.runPreview()
        #expect(f.writer.syncCancelled)
        #expect(f.writer.requests.count == 2)
        #expect(!f.accounts.isSyncing(f.account.id) && f.accounts.writingAccounts.isEmpty)
    }

    @Test func successfulModeSwitchClearsPreviewButUnchangedModeDoesNot() throws {
        let f = try fixture(level: .delegated); try prepare(f)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraAutomationMode-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        try JSONMailRepository(url: url).save(f.executor.state)
        let model = AppModel(storageURL: url, remoteProviderFactory: { _ in f.writer })
        model.setDemoMode(false)
        model.automationController.preview(rule: try #require(model.state.rules.first))
        model.automationController.authorizeDelegation(expiresAt: Date().addingTimeInterval(600), confirmed: true)
        let preview = try #require(model.automationController.preview)
        #expect(model.automationController.activeGrant != nil)
        model.setDemoMode(false)
        #expect(model.automationController.preview == preview)
        model.setDemoMode(true)
        #expect(model.automationController.preview == nil)
        #expect(model.automationController.matches.isEmpty && model.automationController.activeGrant == nil)
        #expect(f.writer.requests.isEmpty)
    }

    @Test func scopeInvalidationClearsPresentationImmediatelyWhileAcknowledgementRemainsTracked() async throws {
        let f = try fixture(); try prepare(f)
        f.writer.pauseAcknowledgement = true
        let run = Task { await f.controller.runPreview() }
        await f.writer.waitForDispatch()
        f.controller.invalidateScope()
        #expect(f.controller.preview == nil && f.controller.matches.isEmpty && f.controller.activeGrant == nil)
        #expect(f.controller.isRunning && f.accounts.writingAccounts.contains(f.account.id))
        f.writer.acknowledge(); await run.value
        #expect(f.writer.requests.count == 1)
        #expect(f.controller.lastRun?.status == .cancelled)
        #expect(f.controller.lastRun?.completedMessageIDs.count == 1)
    }
}
