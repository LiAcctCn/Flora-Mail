import Foundation
import Testing
import FloraCore
@testable import FloraMail

@MainActor
private final class PresentationWriter: ReadOnlyMailProvider, RemoteMailWriter {
    let account: MailAccount
    var accountID: UUID { account.id }
    let name = "Fictional action fixture"
    var calls = 0
    var unknown = false
    init(account: MailAccount) { self.account = account }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] { [] }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage { MailSyncPage(messages: [], checkpoint: SyncCheckpoint(initialComplete: true)) }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data { throw MailSyncError.unsupportedContent }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        calls += 1
        if unknown { throw RemoteActionError.outcomeUnknown }
        var messages = request.messages
        for index in messages.indices {
            if case .flag(_, let value) = request.action { messages[index].isFlagged = value }
            if case .markRead(_, let value) = request.action { messages[index].isRead = value }
        }
        return RemoteActionReceipt(messages: messages, sentProviderMessageID: request.action.isSend ? "fictional-sent" : nil)
    }
}

@MainActor
struct RemoteMailPresentationTests {
    private func fixture() throws -> (URL, MailAccount, MailMessage, PresentationWriter, AppModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraPresentation-\(UUID())")
        let url = directory.appendingPathComponent("fixture.json")
        let account = MailAccount(name: "Fictional account", address: MailAddress(name: "Reader", email: "reader@example.test"), providerType: .gmail,
                                  credentialReference: MailCredentialReference(id: "fictional-keychain-reference"), oauthAccessLevel: .readWrite,
                                  writePermission: .userAuthorized, writeAuthorizedAt: Date().addingTimeInterval(-60))
        let message = MailMessage(providerID: "fictional-message", accountID: account.id, from: MailAddress(name: "Colleague", email: "colleague@example.test"), to: [account.address], subject: "Fictional review", body: "Please review the fictional plan.")
        try JSONMailRepository(url: url).save(AppSnapshot(accounts: [account], messages: [message]))
        let writer = PresentationWriter(account: account)
        let model = AppModel(storageURL: url, remoteProviderFactory: { _ in writer })
        return (directory, account, message, writer, model)
    }

    @Test func guiActionCreatesPreviewAndGenuineUndoInvokesWriter() async throws {
        let (directory, _, message, writer, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.toggleFlag(message)
        #expect(writer.calls == 0)
        #expect(model.state.messages.first?.isFlagged == false)
        let preview = try #require(model.pendingRemoteAction)
        #expect(await model.executeRemote(preview) == nil)
        #expect(writer.calls == 1)
        #expect(model.state.messages.first?.isFlagged == true)
        let record = try #require(model.state.remoteActionHistory.last)
        let undo = try model.accountController.proposeUndo(recordID: record.id)
        #expect(await model.executeRemote(undo) == nil)
        #expect(writer.calls == 2)
        #expect(model.state.messages.first?.isFlagged == false)
    }

    @Test func disablingWritesRetainsReadGrantAndCachedMail() throws {
        let (directory, account, message, writer, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.accountController.disableMailboxActions(account.id)
        #expect(model.state.accounts.first?.oauthAccessLevel == .readWrite)
        #expect(model.state.accounts.first?.isReadOnly == true)
        #expect(model.state.messages.contains(message))
        model.toggleFlag(message)
        #expect(model.pendingRemoteAction == nil && writer.calls == 0)
        #expect(model.errorMessage != nil)
    }

    @Test func uncertainSendStaysBlockedAfterAppReload() async throws {
        let (directory, account, _, writer, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = Draft(to: "colleague@example.test", subject: "Fictional send", body: "Test content only.", accountID: account.id)
        writer.unknown = true
        let proposal = try model.prepareRemoteDraft(draft, send: true)
        #expect(await model.executeRemote(proposal) != nil)
        #expect(writer.calls == 1)
        let reloaded = AppModel(storageURL: directory.appendingPathComponent("fixture.json"), remoteProviderFactory: { _ in writer })
        #expect(!reloaded.canSend(draft))
        #expect(throws: (any Error).self) { try reloaded.prepareRemoteDraft(draft, send: true) }
        #expect(writer.calls == 1)
    }

    @Test func replyAllUsesReplyToExcludesOwnAddressAndDeduplicates() throws {
        let account = MailAccount(name: "Reader", address: MailAddress(name: "Me", email: "me@example.test"))
        var message = MailMessage(accountID: account.id, from: MailAddress(name: "List", email: "list@example.test"),
                                  to: [account.address, MailAddress(name: "Team", email: "team@example.test")], subject: "Fictional", body: "")
        message.replyTo = [MailAddress(name: "Author", email: "author@example.test")]
        message.cc = [MailAddress(name: "Team", email: "TEAM@example.test"), MailAddress(name: "Other", email: "other@example.test"), account.address]
        let all = DraftComposition.recipients(for: message, account: account, replyAll: true)
        #expect(all.to == "author@example.test, team@example.test")
        #expect(all.cc == "other@example.test")
        #expect(DraftComposition.recipients(for: message, account: account, replyAll: false).to == "author@example.test")
    }

    @Test func importedAttachmentsCannotCrossAccountOrDraftScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraOutgoing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fictional.txt")
        try Data("Fictional attachment".utf8).write(to: source)
        let store = AttachmentStorage(root: directory.appendingPathComponent("files"))
        var draft = Draft(accountID: UUID())
        let file = try await store.importForDraft(source, accountID: #require(draft.accountID), draftID: draft.id)
        draft.attachments = [file]
        #expect(try await store.outgoingPayloads(for: draft).first?.data == Data("Fictional attachment".utf8))
        let stored = try await store.existingFile(file.localRelativePath)
        try Data(repeating: 0x41, count: file.size).write(to: stored)
        await #expect(throws: AttachmentStorageError.self) { try await store.outgoingPayloads(for: draft) }
        draft.accountID = UUID()
        await #expect(throws: AttachmentStorageError.self) { try await store.outgoingPayloads(for: draft) }
    }

    @Test func optionalMIMELookupFailureKeepsBoundsAndFileValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMIMELookup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fictional.txt")
        let bytes = Data("A fictional attachment whose type metadata is unavailable.".utf8)
        try bytes.write(to: source)
        let store = AttachmentStorage(root: directory.appendingPathComponent("files"), mimeTypeLookup: { _ in throw CocoaError(.fileReadUnknown) })
        var draft = Draft(accountID: UUID())
        let accountID = try #require(draft.accountID)
        let imported = try await store.importForDraft(source, accountID: accountID, draftID: draft.id)
        #expect(imported.mimeType == "application/octet-stream" && imported.size == bytes.count)
        draft.attachments = [imported]
        #expect(try await store.outgoingPayloads(for: draft).first?.data == bytes)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: AttachmentStorageError.self) { try await store.importForDraft(link, accountID: accountID, draftID: draft.id) }
        await #expect(throws: AttachmentStorageError.self) { try await store.importForDraft(directory, accountID: accountID, draftID: draft.id) }
        let oversized = directory.appendingPathComponent("oversized.bin")
        try Data(repeating: 0, count: AttachmentStorage.maximumOutgoingBytes + 1).write(to: oversized)
        await #expect(throws: AttachmentStorageError.self) { try await store.importForDraft(oversized, accountID: accountID, draftID: draft.id) }
    }

    @Test func recoveryIsSeparateFromSavedDraftAndPreservesOtherDrafts() throws {
        let (directory, account, _, _, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var draft = Draft(to: "colleague@example.test", subject: "Recovery fixture", body: "Unsaved content", accountID: account.id)
        draft.cc = "second@example.test"
        let recovery = DraftRecoveryStore(url: directory.appendingPathComponent("composer-recovery.json"))
        try recovery.save(draft)
        #expect(model.state.drafts.isEmpty)
        let reloaded = AppModel(storageURL: directory.appendingPathComponent("fixture.json"))
        #expect(reloaded.recoverableDraft == draft)
        try recovery.clear(draftID: UUID())
        #expect(try recovery.load() == draft)
        reloaded.recoverUnsavedDraft()
        #expect(reloaded.composingDraft == draft)
        #expect(reloaded.draftHasUnsavedChanges(draft))
    }

    @Test func temporaryFallbackCannotOverwriteExistingRecovery() async throws {
        let (directory, account, _, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DraftRecoveryStore(url: directory.appendingPathComponent("composer-recovery.json"))
        let original = Draft(body: "Existing recovery fixture", accountID: account.id)
        try recovery.save(original)
        try Data("corrupt store fixture".utf8).write(to: directory.appendingPathComponent("fixture.json"))
        let fallback = AppModel(storageURL: directory.appendingPathComponent("fixture.json"))
        let temporary = Draft(body: "Temporary demo text", accountID: try #require(fallback.state.accounts.first?.id))
        fallback.updateEditorDraft(temporary, isDirty: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try recovery.load() == original)
        #expect(fallback.editorRecoveryError != nil)
    }
}
