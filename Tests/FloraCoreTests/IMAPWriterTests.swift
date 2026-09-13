import Foundation
import Testing
@testable import FloraCore

@Suite("Authorized iCloud writes")
@MainActor
struct IMAPWriterTests {
    private func fixture(_ server: IMAPWriterFixture, writable: Bool = true, smtp: any SMTPClient = SMTPWriterFixture()) async throws -> (ICloudMailWriter, MailAccount, MailMessage) {
        let store = MemoryCredentialStore(); let reference = MailCredentialReference(id: "fictional-imap-writer")
        let account = MailAccount(name: "Fictional iCloud", address: MailAddress(name: "Reader", email: "reader@icloud.com"), providerType: .iCloud, credentialReference: reference, writePermission: writable ? .userAuthorized : .readOnly)
        try await store.write(JSONEncoder().encode(IMAPCredential(username: account.address.email, appSpecificPassword: String(repeating: "x", count: 16))), reference: reference)
        let providerID = try IMAPWriteIdentity(folder: "INBOX", validity: 7, uid: 10).providerID
        let message = MailMessage(id: StableMailIdentity.message(accountID: account.id, providerID: providerID), providerID: providerID, accountID: account.id, from: MailAddress(name: "Sender", email: "sender@example.com"), to: [account.address], subject: "Fictional message", body: "Review the fictional document.", providerFolderIDs: ["INBOX"])
        return (ICloudMailWriter(account: account, credentials: store, sessionFactory: server, smtp: smtp), account, message)
    }
    private func request(_ account: MailAccount, action: RemoteMailAction, messages: [MailMessage] = [], draft: Draft? = nil) -> AuthorizedRemoteAction {
        AuthorizedRemoteAction(id: UUID(), account: account, action: action, messages: messages, draft: draft, outgoing: draft.map { fixtureOutgoing(from: account.address, body: $0.body) })
    }
    @Test func readOnlyOptInIsRequiredBeforeConnecting() async throws {
        let server = IMAPWriterFixture(); let (writer, account, message) = try await fixture(server, writable: false)
        await #expect(throws: RemoteActionError.permissionDenied) { try await writer.execute(request(account, action: .markRead(messageIDs: [message.id], isRead: true), messages: [message])) }
        #expect(await server.commands.isEmpty)
    }
    @Test func readAndFlagUseExactUIDAndVerifyAcknowledgedState() async throws {
        let server = IMAPWriterFixture(); let (writer, account, message) = try await fixture(server)
        let read = try await writer.execute(request(account, action: .markRead(messageIDs: [message.id], isRead: true), messages: [message]))
        #expect(read.messages.first?.isRead == true)
        let flag = try await writer.execute(request(account, action: .flag(messageIDs: [message.id], isFlagged: true), messages: [message]))
        #expect(flag.messages.first?.isFlagged == true)
        let commands = await server.commands
        #expect(commands.contains("UID STORE 10 +FLAGS.SILENT (\\Seen)"))
        #expect(commands.contains("UID STORE 10 +FLAGS.SILENT (\\Flagged)"))
        #expect(!commands.contains { $0.contains("BODY[") || $0 == "EXPUNGE" })
    }
    @Test func changedValidityPreventsMutation() async throws {
        let server = IMAPWriterFixture(validity: 8); let (writer, account, message) = try await fixture(server)
        await #expect(throws: RemoteActionError.invalidRequest) { try await writer.execute(request(account, action: .flag(messageIDs: [message.id], isFlagged: true), messages: [message])) }
        #expect(await server.commands.allSatisfy { !$0.contains("STORE") })
    }
    @Test func moveUsesCapabilityAndUpdatesProviderIdentity() async throws {
        let server = IMAPWriterFixture(); let (writer, account, message) = try await fixture(server)
        let result = try await writer.execute(request(account, action: .archive(messageIDs: [message.id]), messages: [message]))
        let moved = try #require(result.messages.first)
        let identity = try IMAPWriteIdentity(providerID: moved.providerID)
        #expect(identity.folder == "Archive"); #expect(identity.uid == 80)
        #expect(result.removedProviderMessageIDs == [message.providerID])
        #expect(moved.id != message.id); #expect(moved.accountID == account.id)
        let commands = await server.commands
        #expect(commands.contains("UID MOVE 10 \"Archive\""))
        #expect(!commands.contains { $0.contains("EXPUNGE") || $0.contains("COPY") })
    }
    @Test func uidplusFallbackNeverExpungesUnrelatedDeletedMail() async throws {
        let server = IMAPWriterFixture(capabilities: ["IMAP4REV1", "UIDPLUS"]); let (writer, account, message) = try await fixture(server)
        _ = try await writer.execute(request(account, action: .archive(messageIDs: [message.id]), messages: [message]))
        let commands = await server.commands
        #expect(commands.contains("UID COPY 10 \"Archive\"")); #expect(commands.contains("UID EXPUNGE 10"))
        #expect(await server.flags["INBOX"]?[99] == ["\\deleted"])
        #expect(!commands.contains("EXPUNGE"))
    }
    @Test func missingUIDPlusRejectsBeforeChangingMailbox() async throws {
        let server = IMAPWriterFixture(capabilities: ["IMAP4REV1"]); let (writer, account, message) = try await fixture(server)
        await #expect(throws: RemoteActionError.unsupported) { try await writer.execute(request(account, action: .archive(messageIDs: [message.id]), messages: [message])) }
        #expect(await server.commands.allSatisfy { !$0.hasPrefix("UID MOVE") && !$0.hasPrefix("UID COPY") })
    }
    @Test func missingCopyReceiptIsOutcomeUnknown() async throws {
        let server = IMAPWriterFixture(omitReceipt: true); let (writer, account, message) = try await fixture(server)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await writer.execute(request(account, action: .archive(messageIDs: [message.id]), messages: [message])) }
    }
    @Test func draftsAppendThenRemoveOnlyPriorDraftUID() async throws {
        let server = IMAPWriterFixture(); let (writer, account, _) = try await fixture(server)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", subject: "Fictional draft", body: "Revised draft", accountID: account.id, providerDraftID: previous, providerDraftMessageID: previous, draftSyncStatus: .synced)
        let result = try await writer.execute(request(account, action: .syncDraft(draftID: draft.id), draft: draft))
        let reference = try #require(result.draftReference)
        #expect(try IMAPWriteIdentity(providerID: reference.providerDraftID).uid == 81)
        let commands = await server.commands
        let appendIndex = try #require(commands.firstIndex(where: { $0.hasPrefix("APPEND") }))
        let removeIndex = try #require(commands.firstIndex(of: "UID EXPUNGE 10"))
        #expect(appendIndex < removeIndex); #expect(await server.flags["Drafts"]?[99] == ["\\deleted"])
    }
    @Test func draftAppendUnknownCannotBlindlyRetry() async throws {
        let server = IMAPWriterFixture(omitReceipt: true); let (writer, account, _) = try await fixture(server)
        let draft = Draft(to: "sender@example.com", body: "Fictional draft", accountID: account.id)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await writer.execute(request(account, action: .syncDraft(draftID: draft.id), draft: draft)) }
        var unknown = draft; unknown.draftSyncStatus = .outcomeUnknown
        await #expect(throws: RemoteActionError.invalidRequest) { try await writer.execute(request(account, action: .syncDraft(draftID: unknown.id), draft: unknown)) }
        #expect(await server.commands.filter { $0.hasPrefix("APPEND") }.count == 1)
    }
    @Test func partialDraftReplacementIsUnknownAndDoesNotExpungeBroadly() async throws {
        let server = IMAPWriterFixture(failCleanup: true); let (writer, account, _) = try await fixture(server)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", body: "Revised draft", accountID: account.id, providerDraftID: previous)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await writer.execute(request(account, action: .syncDraft(draftID: draft.id), draft: draft)) }
        #expect(await server.commands.allSatisfy { $0 != "EXPUNGE" })
    }
    @Test func acknowledgedSendRemovesOnlyTheVerifiedPreviousDraftUID() async throws {
        let smtp = SMTPWriterFixture(); let server = IMAPWriterFixture()
        let (writer, account, _) = try await fixture(server, smtp: smtp)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", body: "Final message", accountID: account.id, providerDraftID: previous, providerDraftMessageID: previous)
        let receipt = try await writer.execute(request(account, action: .sendDraft(draftID: draft.id), draft: draft))
        #expect(await smtp.sends == 1)
        #expect(receipt.advisories.isEmpty)
        #expect(receipt.removedProviderMessageIDs == [previous])
        #expect(await server.flags["Drafts"]?[10] == nil)
        #expect(await server.flags["Drafts"]?[99] == ["\\deleted"])
        #expect(await server.flags["INBOX"]?[10] != nil)
        #expect(await server.commands.filter { $0 == "UID EXPUNGE 10" }.count == 1)
        #expect(await server.commands.allSatisfy { $0 != "EXPUNGE" && !$0.hasPrefix("APPEND") })
    }
    @Test func acknowledgedSendCleanupFailureReturnsAdvisoryWithoutResending() async throws {
        let smtp = SMTPWriterFixture(); let server = IMAPWriterFixture(failCleanup: true)
        let (writer, account, _) = try await fixture(server, smtp: smtp)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", body: "Final message", accountID: account.id, providerDraftID: previous)
        let receipt = try await writer.execute(request(account, action: .sendDraft(draftID: draft.id), draft: draft))
        #expect(await smtp.sends == 1)
        #expect(receipt.advisories.count == 1)
        #expect(receipt.removedProviderMessageIDs.isEmpty)
        #expect(await server.flags["Drafts"]?[99] == ["\\deleted"])
        #expect(await server.commands.filter { $0 == "UID EXPUNGE 10" }.count == 1)
    }
    @Test func acknowledgedSendDoesNotCleanAnUnverifiedDraftIdentity() async throws {
        let smtp = SMTPWriterFixture(); let server = IMAPWriterFixture(validity: 8)
        let (writer, account, _) = try await fixture(server, smtp: smtp)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", body: "Final message", accountID: account.id, providerDraftID: previous)
        let receipt = try await writer.execute(request(account, action: .sendDraft(draftID: draft.id), draft: draft))
        #expect(await smtp.sends == 1); #expect(receipt.advisories.count == 1)
        #expect(await server.commands.allSatisfy { !$0.contains("STORE") && !$0.contains("EXPUNGE") })
        #expect(await server.flags["Drafts"]?[10] == ["\\draft"])
    }
    @Test func unknownSMTPOutcomeNeverStartsDraftCleanup() async throws {
        let smtp = SMTPWriterFixture(failure: .outcomeUnknown); let server = IMAPWriterFixture()
        let (writer, account, _) = try await fixture(server, smtp: smtp)
        let previous = try IMAPWriteIdentity(folder: "Drafts", validity: 7, uid: 10).providerID
        let draft = Draft(to: "sender@example.com", body: "Final message", accountID: account.id, providerDraftID: previous)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await writer.execute(request(account, action: .sendDraft(draftID: draft.id), draft: draft)) }
        #expect(await smtp.sends == 1); #expect(await server.commands.isEmpty)
    }
    @Test func writeCommandsRejectInjectionAndUnboundedLiterals() throws {
        #expect(throws: IMAPError.invalidConfiguration) { try IMAPWriteCommand.move(uid: 1, mailbox: "Archive\r\nEXPUNGE").wireText() }
        #expect(throws: RemoteActionError.invalidRequest) { try IMAPWriteCommand.expunge(uid: 0).wireText() }
        #expect(throws: RemoteActionError.invalidRequest) { try IMAPWriteCommand.append(mailbox: "Drafts", data: Data()).wireText() }
        #expect(throws: RemoteActionError.outcomeUnknown) { try IMAPWriteMapping.copied(IMAPResponse(lines: [], completion: "W1 OK [COPYUID 7 11 81] done"), sourceUID: 10, mailbox: "Archive") }
    }
}

func fixtureOutgoing(from: MailAddress = MailAddress(name: "Reader", email: "reader@icloud.com"), body: String = "Hello.\r\n.End", bcc: [MailAddress] = []) -> OutgoingMail {
    let raw = Data(("From: reader@icloud.com\r\nTo: sender@example.com\r\nSubject: Fictional\r\n\r\n" + body + "\r\n").utf8)
    return OutgoingMail(from: from, to: [MailAddress(name: "Sender", email: "sender@example.com")], cc: [], bcc: bcc, subject: "Fictional", body: body, attachments: [], messageID: "<fictional@example.com>", inReplyTo: nil, references: [], providerThreadID: nil, rawData: raw, smtpData: raw)
}

private actor SMTPWriterFixture: SMTPClient {
    var sends = 0
    let failure: RemoteActionError?
    init(failure: RemoteActionError? = nil) { self.failure = failure }
    func send(_ mail: OutgoingMail, credential: IMAPCredential) async throws {
        sends += 1
        if let failure { throw failure }
    }
}
private actor IMAPWriterFixture: IMAPSessionFactory, IMAPWritableSession {
    var commands: [String] = []
    var flags: [String: [UInt32: Set<String>]] = ["INBOX": [10: [], 99: ["\\deleted"]], "Drafts": [10: ["\\draft"], 99: ["\\deleted"]]]
    let validity: UInt32
    let capabilities: [String]
    let omitReceipt: Bool
    let failCleanup: Bool
    var selected = "INBOX"
    init(validity: UInt32 = 7, capabilities: [String] = ["IMAP4REV1", "UIDPLUS", "MOVE"], omitReceipt: Bool = false, failCleanup: Bool = false) {
        self.validity = validity; self.capabilities = capabilities; self.omitReceipt = omitReceipt; self.failCleanup = failCleanup
    }
    func makeSession(configuration: IMAPConfiguration) async throws -> any IMAPSession { commands.append("CONNECT"); return self }
    func close() {}
    func execute(_ command: IMAPCommand) throws -> IMAPResponse {
        if case .login = command { commands.append("LOGIN [fixture]"); return IMAPResponse(lines: []) }
        commands.append(try command.wireText())
        switch command {
        case .capability: return IMAPResponse(lines: ["* CAPABILITY " + capabilities.joined(separator: " ")])
        case .list: return IMAPResponse(lines: [#"* LIST () "/" "A Custom Folder""#, #"* LIST (\Archive) "/" "Archive""#, #"* LIST (\Drafts) "/" "Drafts""#])
        case .flags(let uids): return IMAPResponse(lines: uids.compactMap { uid in flags[selected]?[uid].map { "* 1 FETCH (UID \(uid) FLAGS (\($0.sorted().joined(separator: " "))))" } })
        default: throw IMAPError.unsupportedMessage
        }
    }
    func executeWrite(_ command: IMAPWriteCommand) throws -> IMAPResponse {
        commands.append(try command.wireText())
        switch command {
        case .select(let folder): selected = folder; return IMAPResponse(lines: ["* OK [UIDVALIDITY \(validity)] valid"], completion: "W1 OK [READ-WRITE] selected")
        case .setFlag(let uid, let flag, let enabled):
            if enabled { flags[selected, default: [:]][uid, default: []].insert(flag.rawValue.lowercased()) }
            else { flags[selected]?[uid]?.remove(flag.rawValue.lowercased()) }
        case .move(let uid, _), .copy(let uid, _): return IMAPResponse(lines: [], completion: omitReceipt ? "W1 OK done" : "W1 OK [COPYUID 7 \(uid) 80] done")
        case .expunge(let uid): if failCleanup { throw RemoteActionError.unavailable }; flags[selected]?[uid] = nil
        case .append: return IMAPResponse(lines: [], completion: omitReceipt ? "W1 OK done" : "W1 OK [APPENDUID 7 81] done")
        }
        return IMAPResponse(lines: [], completion: "W1 OK done")
    }
}
