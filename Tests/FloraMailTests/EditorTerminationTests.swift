import AppKit
import Foundation
import Testing
import FloraCore
@testable import FloraMail

@MainActor
private final class TerminationFixtureWriter: ReadOnlyMailProvider, RemoteMailWriter {
    let account: MailAccount
    var accountID: UUID { account.id }
    let name = "Fictional termination fixture"
    var sends = 0
    init(account: MailAccount) { self.account = account }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage { MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true)) }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        guard request.action.isSend else { throw RemoteActionError.invalidRequest }
        sends += 1
        return RemoteActionReceipt(sentProviderMessageID: "fictional-acknowledged-send")
    }
}

@MainActor
struct EditorTerminationTests {
    private struct Fixture {
        let directory: URL
        let storeURL: URL
        let recoveryURL: URL
        let model: AppModel
        let original: Draft
        let edited: Draft
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraEditorTermination-\(UUID())")
        let storeURL = directory.appendingPathComponent("mail.json")
        let model = AppModel(storageURL: storeURL)
        let original = try #require(model.state.drafts.first)
        var edited = original; edited.body += "\nFictional unsaved revision."
        model.editDraft(original); model.updateEditorDraft(edited, isDirty: true)
        return Fixture(directory: directory, storeURL: storeURL, recoveryURL: directory.appendingPathComponent("composer-recovery.json"), model: model, original: original, edited: edited)
    }

    @Test(arguments: [EditorCloseDecision.save, .discard])
    func delegateUsesRetainedDirtyDraftAfterEarlyDisappearance(decision: EditorCloseDecision) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try DraftRecoveryStore(url: f.recoveryURL).save(f.edited)
        let delegate = AppDelegate(); delegate.model = f.model
        f.model.composingDraft = nil
        f.model.editorDidDisappear(id: f.edited.id)
        // This is the state the real delegate reads; no out-of-band draft is
        // supplied to the tested termination handler after disappearance.
        #expect(f.model.editorIsDirty && f.model.editorDraft == f.edited)
        #expect(delegate.finishDraftTermination(decision) == .terminateNow)
        await nextMainQueueTurn()
        #expect(f.model.composingDraft == nil && f.model.editorDraft == nil)
        let reloaded = AppModel(storageURL: f.storeURL)
        let stored = try #require(reloaded.state.drafts.first { $0.id == f.original.id })
        #expect(stored.body == (decision == .save ? f.edited.body : f.original.body))
        #expect(reloaded.recoverableDraft == nil)
    }

    @Test(arguments: [EditorCloseDecision.save, .discard])
    func committedCloseRejectsDebounceAndLateEditorUpdates(decision: EditorCloseDecision) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try DraftRecoveryStore(url: f.recoveryURL).save(f.edited)
        #expect(f.model.finishEditorClose(f.edited, decision: decision))
        f.model.updateEditorDraft(f.edited, isDirty: true)
        f.model.editorDidDisappear(id: f.edited.id)
        // Longer than the real recovery debounce, not a mocked timer.
        try await Task.sleep(for: .milliseconds(600))
        #expect(try DraftRecoveryStore(url: f.recoveryURL).load() == nil)
        #expect(f.model.editorDraft == nil && f.model.composingDraft == nil)
        #expect(!f.model.editorIsDirty)
        // A genuinely new session may open the same saved draft again.
        f.model.editDraft(f.original)
        f.model.updateEditorDraft(f.original, isDirty: false)
        #expect(f.model.editorDraft?.id == f.original.id)
        #expect(f.model.finishEditorClose(f.original, decision: .discard))
        f.model.editorDidDisappear(id: f.original.id)
    }

    @Test func anotherDraftRecoveryIsNotDeletedByCurrentClose() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let another = Draft(to: "other@example.test", subject: "Separate fictional recovery", body: "Must remain intact.", accountID: f.original.accountID)
        let recovery = DraftRecoveryStore(url: f.recoveryURL); try recovery.save(another)
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        #expect(try recovery.load() == another)
        #expect(f.model.state.drafts.first { $0.id == f.original.id } == f.original)
    }

    @Test func oldEditorCallbackCannotReplaceANewComposerBeforeItsAppearance() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        f.model.compose()
        let next = try #require(f.model.composingDraft)
        #expect(next.id != f.edited.id)
        f.model.updateEditorDraft(f.edited, isDirty: true)
        #expect(f.model.editorDraft == nil)
        #expect(f.model.composingDraft == next)
        f.model.updateEditorDraft(next, isDirty: false)
        #expect(f.model.editorDraft == next)
        #expect(f.model.finishEditorClose(next, decision: .discard))
        f.model.editorDidDisappear(id: next.id)
    }

    @Test func pendingRecoverySurvivesNewEditorAttemptsAndExplicitReviewAllowsEditing() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        let recovery = DraftRecoveryStore(url: f.recoveryURL); try recovery.save(f.edited)
        let reloaded = AppModel(storageURL: f.storeURL)
        let other = Draft(subject: "Another fictional draft", body: "Must not replace recovery.", accountID: f.original.accountID)
        #expect(!reloaded.canCompose)
        reloaded.compose(); reloaded.editDraft(other)
        reloaded.updateEditorDraft(other, isDirty: true)
        #expect(reloaded.composingDraft == nil && reloaded.editorDraft == nil)
        #expect(reloaded.recoverableDraft == f.edited && reloaded.errorMessage != nil)
        #expect(throws: DraftRecoveryStore.StorageError.self) { try recovery.save(other) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(try recovery.load() == f.edited)
        reloaded.setDemoMode(false)
        reloaded.recoverUnsavedDraft()
        #expect(reloaded.recoverableDraft == nil && reloaded.composingDraft == f.edited)
        #expect(reloaded.state.preferences.showDemoAccounts)
        var revised = f.edited; revised.body += "\nReviewed and edited."
        reloaded.updateEditorDraft(revised, isDirty: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try recovery.load() == revised)
        #expect(reloaded.finishEditorClose(revised, decision: .save))
        reloaded.editorDidDisappear(id: revised.id)
        #expect(reloaded.state.drafts.first { $0.id == revised.id }?.body == revised.body)
        #expect(try recovery.load() == nil)
    }

    @Test func explicitRecoveryDiscardAllowsNewComposerAndPreservesSavedBaseline() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        let recovery = DraftRecoveryStore(url: f.recoveryURL); try recovery.save(f.edited)
        let reloaded = AppModel(storageURL: f.storeURL)
        reloaded.discardRecoveredDraft()
        #expect(reloaded.recoverableDraft == nil && reloaded.canCompose)
        #expect(try recovery.load() == nil)
        #expect(reloaded.state.drafts.first { $0.id == f.original.id } == f.original)
        reloaded.compose()
        #expect(reloaded.composingDraft != nil)
    }

    @Test(arguments: [false, true])
    func unavailableOrConflictingRecoveryAccountStaysPending(conflictsWithSource: Bool) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        let other = MailAccount(name: "Fictional other account", address: MailAddress(name: "Other", email: "other@example.test"), providerType: .gmail)
        var snapshot = f.model.state; snapshot.accounts.append(other)
        try JSONMailRepository(url: f.storeURL).save(snapshot)
        var recoveryDraft = f.edited
        recoveryDraft.accountID = conflictsWithSource ? other.id : UUID()
        if !conflictsWithSource { recoveryDraft.replyToMessageID = nil }
        let recovery = DraftRecoveryStore(url: f.recoveryURL); try recovery.save(recoveryDraft)
        let reloaded = AppModel(storageURL: f.storeURL)
        reloaded.recoverUnsavedDraft()
        #expect(reloaded.composingDraft == nil && reloaded.recoverableDraft == recoveryDraft)
        #expect(reloaded.errorMessage != nil && !reloaded.canCompose)
        #expect(try recovery.load() == recoveryDraft)
    }

    @Test func failedRecoveryCleanupVetoesQuitAndRetainsEditedText() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        // A directory at the file path is a deterministic, local cleanup failure.
        try FileManager.default.createDirectory(at: f.recoveryURL, withIntermediateDirectories: false)
        let delegate = AppDelegate(); delegate.model = f.model
        f.model.composingDraft = nil; f.model.editorDidDisappear(id: f.edited.id)
        #expect(delegate.finishDraftTermination(.discard) == .terminateCancel)
        await nextMainQueueTurn()
        #expect(f.model.composingDraft == f.edited && f.model.editorDraft == f.edited)
        #expect(f.model.editorIsDirty && f.model.editorRecoveryError != nil)
        #expect(f.model.state.drafts.first { $0.id == f.original.id } == f.original)
        #expect(FileManager.default.fileExists(atPath: f.recoveryURL.path))
    }

    @Test func savedDraftRemainsSavedWhenRecoveryCleanupFailsAndCanCloseAfterRepair() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try FileManager.default.createDirectory(at: f.recoveryURL, withIntermediateDirectories: false)
        let delegate = AppDelegate(); delegate.model = f.model
        #expect(delegate.finishDraftTermination(.save) == .terminateCancel)
        #expect(f.model.state.drafts.first { $0.id == f.original.id }?.body == f.edited.body)
        #expect(f.model.editorDraft == f.edited)
        #expect(f.model.editorRecoveryError?.contains("was saved") == true)
        try FileManager.default.removeItem(at: f.recoveryURL)
        #expect(delegate.finishDraftTermination(.discard) == .terminateNow)
        #expect(f.model.state.drafts.first { $0.id == f.original.id }?.body == f.edited.body)
    }

    @Test func failedDraftSaveVetoesQuitEvenAfterViewDisappeared() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try DraftRecoveryStore(url: f.recoveryURL).save(f.edited)
        try FileManager.default.removeItem(at: f.storeURL)
        try FileManager.default.createDirectory(at: f.storeURL, withIntermediateDirectories: false)
        f.model.composingDraft = nil; f.model.editorDidDisappear(id: f.edited.id)
        let delegate = AppDelegate(); delegate.model = f.model
        #expect(delegate.finishDraftTermination(.save) == .terminateCancel)
        await nextMainQueueTurn()
        #expect(f.model.editorDraft == f.edited && f.model.composingDraft == f.edited)
        #expect(f.model.editorIsDirty && f.model.editorRecoveryError != nil)
        #expect(try DraftRecoveryStore(url: f.recoveryURL).load() == f.edited)
        #expect(f.model.state.drafts.first { $0.id == f.original.id } == f.original)
    }

    @Test func fallbackSaveCannotPretendDurabilityAndDiscardPreservesPrivateRecovery() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        // Stop the original fixture's debounce before constructing the fallback.
        #expect(f.model.finishEditorClose(f.edited, decision: .discard))
        f.model.editorDidDisappear(id: f.edited.id)
        try DraftRecoveryStore(url: f.recoveryURL).save(f.edited)
        let corrupt = Data("fictional corrupt store".utf8); try corrupt.write(to: f.storeURL)
        let fallback = AppModel(storageURL: f.storeURL)
        let temporary = Draft(subject: "Temporary fixture", body: "Never claimed to be saved.", accountID: try #require(fallback.state.accounts.first?.id))
        fallback.editDraft(temporary); fallback.updateEditorDraft(temporary, isDirty: true)
        let delegate = AppDelegate(); delegate.model = fallback
        #expect(delegate.finishDraftTermination(.save) == .terminateCancel)
        #expect(fallback.editorDraft == temporary && fallback.editorIsDirty)
        #expect(!fallback.state.drafts.contains { $0.id == temporary.id })
        #expect(delegate.finishDraftTermination(.discard) == .terminateNow)
        #expect(try Data(contentsOf: f.storeURL) == corrupt)
        #expect(try DraftRecoveryStore(url: f.recoveryURL).load() == f.edited)
    }

    @Test func acknowledgedSendCleanupDoesNotCallWriterAgainOnFailureOrRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraSentTermination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("mail.json")
        let account = MailAccount(name: "Fictional send fixture", address: MailAddress(name: "Reader", email: "reader@example.test"), providerType: .gmail,
                                  credentialReference: MailCredentialReference(id: "fictional-reference"), oauthAccessLevel: .readWrite, writePermission: .userAuthorized, writeAuthorizedAt: Date().addingTimeInterval(-60))
        let draft = Draft(to: "recipient@example.test", subject: "Fictional send", body: "No live transport is used.", accountID: account.id)
        try JSONMailRepository(url: storeURL).save(AppSnapshot(accounts: [account], drafts: [draft]))
        let writer = TerminationFixtureWriter(account: account)
        let model = AppModel(storageURL: storeURL, remoteProviderFactory: { _ in writer })
        model.editDraft(draft); model.updateEditorDraft(draft, isDirty: false)
        let proposal = try model.prepareRemoteDraft(draft, send: true)
        #expect(await model.executeRemote(proposal) == nil)
        let recoveryURL = directory.appendingPathComponent("composer-recovery.json")
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: false)
        #expect(!model.finishEditorClose(draft, decision: .sent))
        #expect(model.editorRecoveryError?.contains("Do not send again") == true)
        #expect(writer.sends == 1 && !model.canSend(draft))
        #expect(model.state.drafts.first?.deliveryState == .sent)
        try FileManager.default.removeItem(at: recoveryURL)
        #expect(model.finishEditorClose(draft, decision: .sent))
        model.editorDidDisappear(id: draft.id)
        #expect(writer.sends == 1 && model.editorDraft == nil)
        #expect(model.state.remoteActionHistory.count == 1)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}
