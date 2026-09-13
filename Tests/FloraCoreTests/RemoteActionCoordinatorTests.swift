import CryptoKit
import Foundation
import XCTest
@testable import FloraCore

@MainActor
private final class JournalRepository: MailRepository {
    var snapshot: AppSnapshot?
    var failSave = false
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if failSave { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}
@MainActor
private final class JournalWriter: RemoteMailWriter {
    let accountID: UUID
    var requests: [AuthorizedRemoteAction] = []
    var reply: (AuthorizedRemoteAction) async throws -> RemoteActionReceipt
    init(accountID: UUID, reply: @escaping (AuthorizedRemoteAction) async throws -> RemoteActionReceipt = { _ in RemoteActionReceipt() }) { self.accountID = accountID; self.reply = reply }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt { requests.append(request); return try await reply(request) }
}

@MainActor
final class RemoteActionCoordinatorTests: XCTestCase {
    private func account() -> MailAccount {
        MailAccount(name: "Real fixture", address: MailAddress(name: "Reader", email: "reader@example.test"), providerType: .gmail,
                    credentialReference: MailCredentialReference(id: "test-keychain-reference"),
                    syncState: MailSyncState(checkpoint: SyncCheckpoint(opaqueState: "stable-checkpoint", initialComplete: true)),
                    oauthAccessLevel: .readWrite, writePermission: .userAuthorized, writeAuthorizedAt: .distantPast)
    }
    private func message(_ account: MailAccount, providerID: String = "provider-1") -> MailMessage {
        MailMessage(id: StableMailIdentity.message(accountID: account.id, providerID: providerID), providerID: providerID, accountID: account.id, threadID: UUID(), from: account.address, to: [account.address], subject: "Meeting", body: "Review this message.", date: Date(), providerThreadID: "thread", internetMessageID: "<meeting@example.test>")
    }
    private func draft(_ account: MailAccount) -> Draft { Draft(to: "recipient@example.test", subject: "Meeting", body: "Wednesday works.", accountID: account.id) }

    func testDefaultReadOnlyAndLegacyExecutorAlwaysRejectsRealWrites() throws {
        var account = account(); account.writePermission = .readOnly
        let message = message(account), draft = draft(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [message], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        XCTAssertThrowsError(try coordinator.propose(.archive(messageIDs: [message.id]), accountID: account.id, explanation: "Archive")) { XCTAssertEqual($0 as? RemoteActionError, .permissionDenied) }
        account.writePermission = .userAuthorized
        try executor.upsertAccount(account)
        for type in [ActionType.archive(messageIDs: [message.id]), .markRead(messageIDs: [message.id], isRead: true), .flag(messageIDs: [message.id], isFlagged: true), .sendDraft(id: draft.id)] {
            XCTAssertThrowsError(try executor.execute(ProposedAction(type: type, explanation: "A real account"), confirmed: true)) { XCTAssertEqual($0 as? MailActionError, .readOnlyAccount) }
        }
        XCTAssertTrue(executor.state.history.isEmpty)
    }

    func testConfirmationAndPermissionCheckedBeforeWriterAndJournalPrecedesNetwork() async throws {
        let account = account(), message = message(account), repository = JournalRepository()
        let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account], messages: [message]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let proposal = try coordinator.propose(.markRead(messageIDs: [message.id], isRead: true), accountID: account.id, explanation: "Mark read", origin: .ai)
        let writer = JournalWriter(accountID: account.id) { request in
            XCTAssertEqual(repository.snapshot?.remoteActionHistory.last?.status, .prepared)
            var updated = request.messages[0]; updated.isRead = true
            return RemoteActionReceipt(messages: [updated])
        }
        do { _ = try await coordinator.execute(proposal, writer: writer); XCTFail("Unconfirmed AI action executed") }
        catch { XCTAssertEqual(error as? RemoteActionError, .confirmationRequired) }
        XCTAssertTrue(writer.requests.isEmpty)
        let result = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(result.status, .completed); XCTAssertTrue(result.canUndo)
        XCTAssertTrue(executor.state.messages[0].isRead)
        XCTAssertEqual(executor.state.accounts[0].syncState.checkpoint, account.syncState.checkpoint)
        XCTAssertFalse(executor.canUndo, "No fake cache Undo for a remote action")
    }

    func testJournalSaveFailureNeverReachesWriter() async throws {
        let account = account(), draft = draft(account), repository = JournalRepository()
        let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor), writer = JournalWriter(accountID: account.id)
        let proposal = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
        repository.failSave = true
        do { _ = try await coordinator.execute(proposal, confirmed: true, writer: writer); XCTFail("Save failure ignored") }
        catch { XCTAssertEqual(error as? RemoteActionError, .persistenceFailed) }
        XCTAssertTrue(writer.requests.isEmpty); XCTAssertTrue(executor.state.remoteActionHistory.isEmpty)
        XCTAssertEqual(executor.state.drafts[0].deliveryState, .notSent)
    }

    func testUnknownSendSurvivesRestartStaleEditorAndRequiresExplicitRecovery() async throws {
        let account = account(), draft = draft(account), repository = JournalRepository()
        let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in throw RemoteActionError.outcomeUnknown }
        let proposal = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
        do { _ = try await coordinator.execute(proposal, confirmed: true, writer: writer); XCTFail("Ambiguous send treated as success") } catch { XCTAssertEqual(error as? RemoteActionError, .outcomeUnknown) }
        try executor.execute(ProposedAction(type: .saveDraft(draft), explanation: "Stale editor save"))
        XCTAssertEqual(executor.state.drafts[0].deliveryState, .outcomeUnknown)
        let persisted = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(try XCTUnwrap(repository.snapshot)))
        let restarted = ActionExecutor(repository: repository, initialState: persisted), recovery = RemoteActionCoordinator(executor: restarted)
        XCTAssertThrowsError(try recovery.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Retry"))
        XCTAssertThrowsError(try recovery.resolveUnknown(recordID: proposal.id, resolution: .confirmedNotApplied))
        let resolved = try recovery.resolveUnknown(recordID: proposal.id, resolution: .confirmedNotApplied, confirmed: true)
        XCTAssertEqual(resolved.resolution, .confirmedNotApplied); XCTAssertNotNil(resolved.resolvedAt)
        XCTAssertEqual(restarted.state.drafts[0].deliveryState, .notSent)
        _ = try recovery.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Reviewed retry")
    }

    func testInterruptedPreparedSendAndDeletedRecreatedDraftCannotBypassBarrier() throws {
        let account = account(), draft = draft(account), repository = MemoryMailRepository()
        let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        let proposal = try RemoteActionCoordinator(executor: executor).propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
        try executor.beginRemoteAction(proposal)
        let restarted = ActionExecutor(repository: repository, initialState: try XCTUnwrap(repository.snapshot))
        XCTAssertEqual(restarted.state.remoteActionHistory[0].status, .outcomeUnknown)
        try restarted.execute(ProposedAction(type: .deleteDraft(id: draft.id), explanation: "Delete local draft"))
        try restarted.execute(ProposedAction(type: .saveDraft(draft), explanation: "Recreate same draft ID"))
        XCTAssertThrowsError(try RemoteActionCoordinator(executor: restarted).propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Retry"))
    }

    func testAcknowledgedSendIsNotFakeSentCacheAndCannotBeReplayed() async throws {
        let account = account(), draft = draft(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor), writer = JournalWriter(accountID: account.id)
        let proposal = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
        let record = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(record.status, .completed); XCTAssertFalse(record.canUndo)
        XCTAssertEqual(executor.state.drafts[0].deliveryState, .sent); XCTAssertTrue(executor.state.messages.isEmpty)
        XCTAssertThrowsError(try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Again"))
        XCTAssertEqual(writer.requests.count, 1)
    }

    func testStalePreviewCrossAccountAndAutomationAreRejected() async throws {
        let account = account(), other = self.account(), source = message(account), foreign = message(other)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account, other], messages: [source, foreign]))
        let coordinator = RemoteActionCoordinator(executor: executor), writer = JournalWriter(accountID: account.id)
        XCTAssertThrowsError(try coordinator.propose(.archive(messageIDs: [foreign.id]), accountID: account.id, explanation: "Wrong account"))
        XCTAssertThrowsError(try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Automation", origin: .automation))
        let proposal = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Archive")
        var changed = source; changed.subject = "Changed after preview"
        try executor.commitSyncPage(MailSyncPage(messages: [changed], checkpoint: SyncCheckpoint()), accountID: account.id)
        do { _ = try await coordinator.execute(proposal, confirmed: true, writer: writer); XCTFail("Stale preview executed") } catch { XCTAssertEqual(error as? RemoteActionError, .staleProposal) }
        XCTAssertTrue(writer.requests.isEmpty)
    }

    func testCancellationAfterWriterStartsBecomesUnknownAndPreservesCache() async throws {
        let account = account(), source = message(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in throw CancellationError() }
        let proposal = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Archive")
        do { _ = try await coordinator.execute(proposal, confirmed: true, writer: writer); XCTFail("Cancellation ignored") } catch { XCTAssertEqual(error as? RemoteActionError, .outcomeUnknown) }
        XCTAssertEqual(executor.state.messages, [source]); XCTAssertEqual(executor.state.remoteActionHistory[0].status, .outcomeUnknown)
    }

    func testDraftSyncUsesSourceContextPreservesNewerEditsAndBlocksUnknownSyncSend() async throws {
        let account = account(), source = message(account)
        var draft = draft(account); draft.replyToMessageID = source.id
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { request in
            XCTAssertEqual(request.messages.map(\.id), [source.id]); XCTAssertEqual(request.outgoing?.inReplyTo, source.internetMessageID)
            var edited = draft; edited.body = "New text while sync was in progress"
            try executor.execute(ProposedAction(type: .saveDraft(edited), explanation: "Edit"))
            return RemoteActionReceipt(draftReference: RemoteDraftReference(providerDraftID: "remote-draft", providerMessageID: "remote-message"))
        }
        let proposal = try coordinator.propose(.syncDraft(draftID: draft.id), accountID: account.id, explanation: "Sync draft")
        _ = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(executor.state.drafts[0].draftSyncStatus, .localOnly)
        XCTAssertEqual(executor.state.drafts[0].providerDraftID, "remote-draft")
        var stale = draft; stale.providerDraftID = "forged-id"
        try executor.execute(ProposedAction(type: .saveDraft(stale), explanation: "Stale save"))
        XCTAssertEqual(executor.state.drafts[0].providerDraftID, "remote-draft")
        writer.reply = { _ in throw RemoteActionError.outcomeUnknown }
        let next = try coordinator.propose(.syncDraft(draftID: draft.id), accountID: account.id, explanation: "Sync again")
        do { _ = try await coordinator.execute(next, confirmed: true, writer: writer) } catch { }
        XCTAssertThrowsError(try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send unknown draft"))
    }

    func testRealFlagUndoUsesASecondConfirmedWriterCallAndRejectsStaleState() async throws {
        let account = account(), source = message(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { request in
            var changed = request.messages[0]
            guard case .flag(_, let value) = request.action else { throw RemoteActionError.invalidRequest }
            changed.isFlagged = value; return RemoteActionReceipt(messages: [changed])
        }
        let original = try coordinator.propose(.flag(messageIDs: [source.id], isFlagged: true), accountID: account.id, explanation: "Flag")
        _ = try await coordinator.execute(original, confirmed: true, writer: writer)
        let undo = try coordinator.proposeUndo(recordID: original.id)
        XCTAssertTrue(undo.requiresConfirmation)
        _ = try await coordinator.execute(undo, confirmed: true, writer: writer)
        XCTAssertEqual(writer.requests.count, 2); XCTAssertFalse(executor.state.messages[0].isFlagged)
        XCTAssertEqual(executor.state.remoteActionHistory[0].undoneByActionID, undo.id)
        XCTAssertFalse(executor.state.remoteActionHistory[0].canUndo)
        XCTAssertThrowsError(try coordinator.proposeUndo(recordID: original.id))
    }

    func testMIMEProtectsBccUnicodeAndHeaderInjection() throws {
        let account = account()
        var draft = draft(account); draft.cc = "Colleague <cc@example.test>"; draft.bcc = "hidden@example.test"; draft.subject = "会议确认"
        let reference = DraftAttachment(name: "研究.pdf", mimeType: "application/pdf", size: 3, localRelativePath: "Drafts/attachment.pdf", contentHash: SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined())
        draft.attachments = [reference]
        let attachment = OutgoingAttachment(id: reference.id, name: reference.name, mimeType: reference.mimeType, data: Data([1, 2, 3]))
        let outgoing = try OutgoingMIMEComposer.compose(account: account, draft: draft, source: nil, attachments: [attachment])
        let raw = String(decoding: outgoing.rawData, as: UTF8.self), smtp = String(decoding: outgoing.smtpData, as: UTF8.self)
        XCTAssertTrue(raw.contains("Bcc: hidden@example.test")); XCTAssertFalse(smtp.contains("hidden@example.test"))
        XCTAssertTrue(raw.contains("Subject: =?UTF-8?B?")); XCTAssertTrue(raw.contains("filename*0*=UTF-8''"))
        XCTAssertEqual(outgoing.bcc.map(\.email), ["hidden@example.test"])
        draft.subject = "Normal\r\nBcc: attacker@example.test"
        XCTAssertThrowsError(try OutgoingMIMEComposer.compose(account: account, draft: draft, source: nil, attachments: [attachment]))
        draft.subject = "Normal"
        let substituted = OutgoingAttachment(id: reference.id, name: reference.name, mimeType: reference.mimeType, data: Data([3, 2, 1]))
        XCTAssertThrowsError(try OutgoingMIMEComposer.compose(account: account, draft: draft, source: nil, attachments: [substituted]))
        draft.attachments[0].size = 4
        XCTAssertThrowsError(try OutgoingMIMEComposer.compose(account: account, draft: draft, source: nil, attachments: [attachment]))
    }

    func testForeignReceiptAndPostAcknowledgementStorageFailureKeepDuplicateBarrier() async throws {
        let account = account(), other = self.account(), source = message(account), foreign = message(other)
        let repository = JournalRepository()
        let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account, other], messages: [source, foreign]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in RemoteActionReceipt(messages: [foreign]) }
        let action = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Archive")
        do { _ = try await coordinator.execute(action, confirmed: true, writer: writer); XCTFail("Wrong-account receipt accepted") }
        catch { XCTAssertEqual(error as? RemoteActionError, .outcomeUnknown) }
        XCTAssertEqual(executor.state.messages, [source, foreign]); XCTAssertEqual(executor.state.remoteActionHistory[0].status, .outcomeUnknown)
        _ = try coordinator.resolveUnknown(recordID: action.id, resolution: .confirmedNotApplied, confirmed: true)
        let next = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Reviewed retry")
        writer.reply = { request in
            repository.failSave = true
            var changed = request.messages[0]; changed.folder = .archive
            return RemoteActionReceipt(messages: [changed])
        }
        do { _ = try await coordinator.execute(next, confirmed: true, writer: writer); XCTFail("Storage failure ignored") }
        catch { XCTAssertEqual(error as? RemoteActionError, .persistenceFailed) }
        XCTAssertEqual(repository.snapshot?.remoteActionHistory.last?.status, .prepared)
        let restarted = ActionExecutor(repository: repository, initialState: try XCTUnwrap(repository.snapshot))
        XCTAssertEqual(restarted.state.remoteActionHistory.last?.status, .outcomeUnknown)
    }

    func testMoveIdentityReplacementPreservesLocalCategoryAndCheckpoint() async throws {
        let account = account(), source = message(account)
        let category = MailCategory(name: "Research")
        var categorized = source; categorized.categoryID = category.id
        let destination = MailFolderDescriptor(id: "remote-work", accountID: account.id, name: "Work")
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [categorized], categories: [category], remoteFolders: [destination]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in
            var moved = source; moved.providerID = "replacement-id"; moved.folder = .archive; moved.providerFolderIDs = [destination.id]
            return RemoteActionReceipt(messages: [moved], removedProviderMessageIDs: [source.providerID])
        }
        let proposal = try coordinator.propose(.move(messageIDs: [source.id], destination: destination), accountID: account.id, explanation: "Move")
        _ = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(executor.state.messages.count, 1); XCTAssertEqual(executor.state.messages[0].id, source.id)
        XCTAssertEqual(executor.state.messages[0].providerID, "replacement-id"); XCTAssertEqual(executor.state.messages[0].categoryID, category.id)
        XCTAssertEqual(executor.state.accounts[0].syncState.checkpoint, account.syncState.checkpoint)
        XCTAssertFalse(executor.state.remoteActionHistory[0].canUndo)
    }

    func testCancellationBeforeExecutionDoesNotJournalOrCallWriter() async throws {
        let account = account(), source = message(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        let coordinator = RemoteActionCoordinator(executor: executor), writer = JournalWriter(accountID: account.id)
        let proposal = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Archive")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.execute(proposal, confirmed: true, writer: writer)
        }
        do { _ = try await task.value; XCTFail("Cancelled task ran") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(writer.requests.isEmpty); XCTAssertTrue(executor.state.remoteActionHistory.isEmpty)
    }

    func testRevokingPermissionAfterPreviewAndStaleUndoNeverCallsWriter() async throws {
        var account = account()
        let source = message(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { request in
            var updated = request.messages[0]; updated.isRead = true; return RemoteActionReceipt(messages: [updated])
        }
        let proposal = try coordinator.propose(.markRead(messageIDs: [source.id], isRead: true), accountID: account.id, explanation: "Read")
        _ = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        var fresh = source; fresh.isRead = false
        try executor.commitSyncPage(MailSyncPage(messages: [fresh], checkpoint: SyncCheckpoint()), accountID: account.id)
        XCTAssertThrowsError(try coordinator.proposeUndo(recordID: proposal.id)) { XCTAssertEqual($0 as? RemoteActionError, .staleProposal) }
        let preview = try coordinator.propose(.archive(messageIDs: [source.id]), accountID: account.id, explanation: "Archive")
        account.writePermission = .readOnly; account.writeAuthorizedAt = nil
        try executor.updateAccount(account)
        do { _ = try await coordinator.execute(preview, confirmed: true, writer: writer); XCTFail("Revoked permission used") }
        catch { XCTAssertEqual(error as? RemoteActionError, .permissionDenied) }
        XCTAssertEqual(writer.requests.count, 1)
    }

    func testEditingSyncedDraftRetainsServerIdentityAndMarksUnsynced() async throws {
        let account = account(), draft = draft(account)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in RemoteActionReceipt(draftReference: RemoteDraftReference(providerDraftID: "server-draft", providerMessageID: "server-message")) }
        let proposal = try coordinator.propose(.syncDraft(draftID: draft.id), accountID: account.id, explanation: "Sync")
        _ = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(executor.state.drafts[0].draftSyncStatus, .synced)
        var edited = draft; edited.cc = "Colleague <colleague@example.test>"; edited.body = "Revised draft"
        try executor.execute(ProposedAction(type: .saveDraft(edited), explanation: "Edit"))
        XCTAssertEqual(executor.state.drafts[0].draftSyncStatus, .localOnly)
        XCTAssertEqual(executor.state.drafts[0].providerDraftID, "server-draft")
        XCTAssertEqual(executor.state.drafts[0].providerDraftMessageID, "server-message")
        try executor.undo()
        XCTAssertEqual(executor.state.drafts[0].providerDraftID, "server-draft")
    }

    func testDemoSendSupportsDisplayNamesCCAndBccWithoutExposingBccHeader() throws {
        let account = MailAccount(name: "Demo", address: MailAddress(name: "Demo Reader", email: "demo@example.test"))
        let draft = Draft(to: "Recipient Name <recipient@example.test>", subject: "Demo", body: "Message", accountID: account.id, cc: "Copy Name <copy@example.test>", bcc: "blind@example.test", attachments: [DraftAttachment(name: "notes.txt", mimeType: "text/plain", size: 10, localRelativePath: "Drafts/notes.txt")])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], drafts: [draft]))
        try executor.execute(ProposedAction(type: .sendDraft(id: draft.id), explanation: "Demo send"), confirmed: true)
        let sent = try XCTUnwrap(executor.state.messages.first)
        XCTAssertEqual(sent.to.first?.name, "Recipient Name"); XCTAssertEqual(sent.cc.first?.email, "copy@example.test")
        XCTAssertEqual(sent.attachments.first?.name, "notes.txt"); XCTAssertEqual(sent.attachments.first?.mimeType, "text/plain")
        XCTAssertFalse((sent.to + sent.cc).contains(where: { $0.email == "blind@example.test" }))
    }

    func testTrashMoveRequiresPersistedFolderAndExplicitConfirmation() async throws {
        let account = account(), source = message(account)
        let trash = MailFolderDescriptor(id: "TRASH", accountID: account.id, name: "Trash", role: .trash)
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account], messages: [source], remoteFolders: [trash]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let proposal = try coordinator.propose(.move(messageIDs: [source.id], destination: trash), accountID: account.id, explanation: "Move to Trash")
        let writer = JournalWriter(accountID: account.id) { request in
            var updated = request.messages[0]; updated.folder = .trash; updated.providerFolderIDs = [trash.id]
            return RemoteActionReceipt(messages: [updated])
        }
        do { _ = try await coordinator.execute(proposal, writer: writer); XCTFail("Trash moved without confirmation") }
        catch { XCTAssertEqual(error as? RemoteActionError, .confirmationRequired) }
        _ = try await coordinator.execute(proposal, confirmed: true, writer: writer)
        XCTAssertEqual(executor.state.messages[0].folder, .trash)
        XCTAssertFalse(executor.state.remoteActionHistory[0].canUndo)
    }

    func testAcknowledgedSendAdvisoryPersistsWithoutAllowingDuplicateDelivery() async throws {
        let advisory = "Message accepted for delivery. The previous server draft could not be removed; review Drafts in the account."
        for advice in [[advisory], [String(repeating: "x", count: 10_000), "Untrusted\nline"], Array(repeating: "More advice", count: 100)] {
            let account = account(), draft = draft(account), repository = MemoryMailRepository()
            let executor = ActionExecutor(repository: repository, initialState: AppSnapshot(accounts: [account], drafts: [draft]))
            let coordinator = RemoteActionCoordinator(executor: executor)
            let writer = JournalWriter(accountID: account.id) { _ in RemoteActionReceipt(advisories: advice) }
            let proposal = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
            let record = try await coordinator.execute(proposal, confirmed: true, writer: writer)
            XCTAssertEqual(record.status, .completed); XCTAssertEqual(executor.state.drafts[0].deliveryState, .sent)
            XCTAssertNotNil(record.errorMessage); XCTAssertLessThanOrEqual(record.errorMessage?.utf8.count ?? 0, 2_051)
            if advice == [advisory] { XCTAssertEqual(record.errorMessage, advisory) }
            let saved = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(try XCTUnwrap(repository.snapshot)))
            let restarted = ActionExecutor(repository: repository, initialState: saved)
            XCTAssertEqual(restarted.state.remoteActionHistory[0].status, .completed)
            XCTAssertEqual(restarted.state.remoteActionHistory[0].errorMessage, record.errorMessage)
            XCTAssertThrowsError(try RemoteActionCoordinator(executor: restarted).propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send again"))
        }
    }

    func testDraftReplacementAndAcknowledgedSendRemoveOnlyExactPriorCachedDraft() async throws {
        let account = account(), other = self.account()
        var draft = draft(account); draft.providerDraftID = "old-draft"; draft.providerDraftMessageID = "old-message"
        var prior = message(account, providerID: "old-message"); prior.folder = .drafts
        let foreign = message(other, providerID: "old-message")
        let unrelated = message(account, providerID: "unrelated-inbox")
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(accounts: [account, other], messages: [prior, foreign, unrelated], drafts: [draft]))
        let coordinator = RemoteActionCoordinator(executor: executor)
        let writer = JournalWriter(accountID: account.id) { _ in RemoteActionReceipt(removedProviderMessageIDs: ["old-message"], draftReference: RemoteDraftReference(providerDraftID: "new-draft", providerMessageID: "new-message")) }
        let sync = try coordinator.propose(.syncDraft(draftID: draft.id), accountID: account.id, explanation: "Replace server draft")
        _ = try await coordinator.execute(sync, confirmed: true, writer: writer)
        XCTAssertFalse(executor.state.messages.contains(where: { $0.id == prior.id }))
        XCTAssertTrue(executor.state.messages.contains(foreign)); XCTAssertTrue(executor.state.messages.contains(unrelated))
        XCTAssertEqual(executor.state.drafts[0].providerDraftMessageID, "new-message")
        writer.reply = { _ in RemoteActionReceipt(removedProviderMessageIDs: ["unrelated-inbox"]) }
        let badSend = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Send")
        do { _ = try await coordinator.execute(badSend, confirmed: true, writer: writer); XCTFail("Unrelated deletion accepted") }
        catch { XCTAssertEqual(error as? RemoteActionError, .outcomeUnknown) }
        XCTAssertTrue(executor.state.messages.contains(unrelated))
        _ = try coordinator.resolveUnknown(recordID: badSend.id, resolution: .confirmedNotApplied, confirmed: true)
        writer.reply = { _ in RemoteActionReceipt(removedProviderMessageIDs: ["new-message"]) }
        let send = try coordinator.propose(.sendDraft(draftID: draft.id), accountID: account.id, explanation: "Reviewed send")
        let sent = try await coordinator.execute(send, confirmed: true, writer: writer)
        XCTAssertEqual(sent.status, .completed); XCTAssertEqual(executor.state.drafts[0].deliveryState, .sent)
        XCTAssertTrue(executor.state.messages.contains(foreign)); XCTAssertTrue(executor.state.messages.contains(unrelated))
    }

    func testLegacyPersistenceDefaultsToReadOnlyAndLocalDraft() throws {
        let account = account(), draft = draft(account)
        let snapshot = AppSnapshot(accounts: [account], drafts: [draft])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        for key in ["writePermission", "writeAuthorizedAt", "oauthAccessLevel"] { accounts[0].removeValue(forKey: key) }
        var drafts = try XCTUnwrap(object["drafts"] as? [[String: Any]])
        for key in ["cc", "bcc", "attachments", "providerDraftID", "providerDraftMessageID", "draftSyncStatus", "deliveryState"] { drafts[0].removeValue(forKey: key) }
        object["accounts"] = accounts; object["drafts"] = drafts; object.removeValue(forKey: "remoteActionHistory")
        let migrated = try JSONDecoder().decode(AppSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.accounts[0].writePermission, .readOnly); XCTAssertEqual(migrated.accounts[0].oauthAccessLevel, .readOnly)
        XCTAssertEqual(migrated.drafts[0].deliveryState, .notSent); XCTAssertTrue(migrated.drafts[0].attachments.isEmpty)
        XCTAssertTrue(migrated.remoteActionHistory.isEmpty)
    }
}
