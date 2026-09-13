import Foundation
import Testing
@testable import FloraCore

private let writeReference = MailCredentialReference(id: "fictional-write-test-reference")
private func writeConfiguration(_ provider: MailProviderType, level: OAuthAccessLevel = .readWrite) -> OAuthClientConfiguration {
    OAuthClientConfiguration(provider: provider, clientID: provider == .gmail ? "fictional-writer.apps.googleusercontent.com" : "00000000-0000-0000-0000-000000000012", accessLevel: level)
}
private func writeCredentials(_ config: OAuthClientConfiguration, scope: String? = nil, expired: Bool = false) async throws -> MemoryCredentialStore {
    let store = MemoryCredentialStore()
    let token = OAuthCredential(provider: config.provider, clientID: config.clientID, accessToken: "FICTIONAL_WRITE_ACCESS", refreshToken: "FICTIONAL_WRITE_REFRESH", expiresAt: Date().addingTimeInterval(expired ? -60 : 3600), scope: scope ?? config.scopes.joined(separator: " "))
    try await store.write(JSONEncoder().encode(token), reference: writeReference)
    return store
}
private func writeAccount(_ provider: MailProviderType = .gmail) -> MailAccount {
    MailAccount(name: "Fictional test", address: MailAddress(name: "Alex", email: "alex@example.invalid"), provider: provider.title, providerType: provider, credentialReference: writeReference, oauthClientID: writeConfiguration(provider).clientID, oauthAccessLevel: .readWrite, writePermission: .userAuthorized)
}
private func writeMessage(_ account: MailAccount, providerID: String = "message-one") -> MailMessage {
    MailMessage(providerID: providerID, accountID: account.id, from: MailAddress(name: "Sam", email: "sam@example.invalid"), to: [account.address], subject: "Fictional review", body: "Please review.", providerThreadID: "thread-one", providerFolderIDs: ["INBOX", "UNREAD", "Label_research"])
}
private func writeRequest(_ account: MailAccount, action: RemoteMailAction, messages: [MailMessage] = [], draft: Draft? = nil, outgoing: OutgoingMail? = nil) -> AuthorizedRemoteAction {
    AuthorizedRemoteAction(id: UUID(), account: account, action: action, messages: messages, draft: draft, outgoing: outgoing)
}
private func writeOutgoing(_ account: MailAccount, attachments: [OutgoingAttachment] = [], thread: String? = nil) -> OutgoingMail {
    OutgoingMail(from: account.address, to: [MailAddress(name: "Sam", email: "sam@example.invalid")], cc: [], bcc: [MailAddress(name: "Reviewer", email: "reviewer@example.invalid")], subject: "Fictional review", body: "Looks good.", attachments: attachments, messageID: "<fictional-review@example.invalid>", inReplyTo: nil, references: [], providerThreadID: thread, rawData: Data("From: alex@example.invalid\r\nTo: sam@example.invalid\r\nBcc: reviewer@example.invalid\r\nSubject: Fictional review\r\n\r\nLooks good.\r\n".utf8), smtpData: Data())
}
private func writeJSON(_ value: Any, status: Int = 200) throws -> MailHTTPResponse {
    MailHTTPResponse(data: try JSONSerialization.data(withJSONObject: value), status: status)
}
private func writeObject(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    let value = try JSONSerialization.jsonObject(with: data)
    return try #require(value as? [String: Any])
}

@Suite("Authorized REST mail writes")
@MainActor
struct RESTMailWriteTests {
    @Test func accessUpgradeScopesAreExplicitAndLegacyConfigurationStaysReadOnly() throws {
        let old = Data(#"{"provider":"gmail","clientID":"fictional-writer.apps.googleusercontent.com"}"#.utf8)
        #expect(try JSONDecoder().decode(OAuthClientConfiguration.self, from: old).accessLevel == .readOnly)
        #expect(writeConfiguration(.gmail).scopes == ["https://www.googleapis.com/auth/gmail.modify"])
        let microsoft = writeConfiguration(.microsoft).scopes
        #expect(microsoft.contains("https://graph.microsoft.com/Mail.ReadWrite") && microsoft.contains("https://graph.microsoft.com/Mail.Send"))
        let service = OAuthService(credentials: MemoryCredentialStore(), http: ScriptedMailHTTP([]))
        let redirect = try #require(URL(string: "http://127.0.0.1:50000/oauth/callback"))
        let auth = try service.makeAuthorizationRequest(configuration: writeConfiguration(.gmail), redirectURI: redirect)
        #expect(URLComponents(url: auth.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value == "https://www.googleapis.com/auth/gmail.modify")
    }
    @Test func oldReadOnlyCredentialsCannotSilentlyRefreshIntoWriteAccess() async throws {
        let config = writeConfiguration(.gmail), http = ScriptedMailHTTP([])
        let credentials = try await writeCredentials(config, scope: writeConfiguration(.gmail, level: .readOnly).scopes.joined(separator: " "), expired: true)
        let tokens = OAuthAccessTokenProvider(configuration: config, reference: writeReference, credentials: credentials, http: http)
        await #expect(throws: RemoteMailError.authorizationDenied) { try await tokens.accessToken() }
        #expect(await http.captured().isEmpty)
    }
    @Test func disabledWritePermissionDoesNotPreventReadingWithAnUpgradedToken() async throws {
        var account = writeAccount(); account.writePermission = .readOnly
        let config = writeConfiguration(.gmail), http = ScriptedMailHTTP([try writeJSON(["emailAddress": "alex@example.invalid", "historyId": "1"])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        #expect(try await provider.fetchAccounts().first?.oauthAccessLevel == .readWrite)
        let message = writeMessage(account)
        await #expect(throws: RemoteActionError.permissionDenied) { try await provider.execute(writeRequest(account, action: .archive(messageIDs: [message.id]), messages: [message])) }
        #expect(await http.captured().count == 1)
    }
    @Test func gmailArchivePreservesOtherLabelsAndUpdatesOnlyAfterAcknowledgement() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail)
        let source = writeMessage(account)
        let http = ScriptedMailHTTP([try writeJSON(["id": source.providerID, "labelIds": ["UNREAD", "Label_research"]])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let receipt = try await provider.execute(writeRequest(account, action: .archive(messageIDs: [source.id]), messages: [source]))
        #expect(receipt.messages.first?.folder == .archive)
        #expect(receipt.messages.first?.providerFolderIDs.contains("Label_research") == true)
        let request = try #require(await http.captured().first)
        #expect(request.httpMethod == "POST" && request.url?.path.hasSuffix("/messages/message-one/modify") == true)
        #expect(try writeObject(request)["removeLabelIds"] as? [String] == ["INBOX"])
    }
    @Test func crossAccountAndSpecialLabelMovesAreRejectedBeforeNetwork() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), http = ScriptedMailHTTP([])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let source = writeMessage(account)
        let other = MailFolderDescriptor(id: "Label_other", accountID: UUID(), name: "Other", isLabel: true)
        await #expect(throws: RemoteActionError.invalidRequest) { try await provider.execute(writeRequest(account, action: .move(messageIDs: [source.id], destination: other), messages: [source])) }
        let special = MailFolderDescriptor(id: "SENT", accountID: account.id, name: "Sent", role: .sent, isLabel: true)
        await #expect(throws: RemoteActionError.unsupported) { try await provider.execute(writeRequest(account, action: .move(messageIDs: [source.id], destination: special), messages: [source])) }
        #expect(await http.captured().isEmpty)
    }
    @Test func gmailExplicitTrashAndRestoreUseReversibleRoutes() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail)
        let source = writeMessage(account)
        let trash = MailFolderDescriptor(id: "TRASH", accountID: account.id, name: "Trash", role: .trash, isLabel: true)
        let inbox = MailFolderDescriptor(id: "INBOX", accountID: account.id, name: "Inbox", role: .inbox, isLabel: true)
        let http = ScriptedMailHTTP([try writeJSON(["id": source.providerID, "labelIds": ["TRASH", "UNREAD"]]), try writeJSON(["id": source.providerID, "labelIds": ["UNREAD"]]), try writeJSON(["id": source.providerID, "labelIds": ["INBOX", "UNREAD"]])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let trashed = try await provider.execute(writeRequest(account, action: .move(messageIDs: [source.id], destination: trash), messages: [source]))
        let inTrash = try #require(trashed.messages.first)
        #expect(inTrash.folder == .trash)
        await #expect(throws: RemoteActionError.unsupported) { try await provider.execute(writeRequest(account, action: .archive(messageIDs: [inTrash.id]), messages: [inTrash])) }
        let restored = try await provider.execute(writeRequest(account, action: .move(messageIDs: [inTrash.id], destination: inbox), messages: [inTrash]))
        #expect(restored.messages.first?.folder == .inbox)
        #expect(await http.captured().map { $0.url?.lastPathComponent } == ["trash", "untrash", "modify"])
    }
    @Test func gmailDraftCreateAndUpdateKeepSeparateDraftAndMessageIDs() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail)
        var draft = Draft(accountID: account.id)
        let http = ScriptedMailHTTP([try writeJSON(["id": "draft-one", "message": ["id": "draft-message-1"]]), try writeJSON(["id": "draft-one", "message": ["id": "draft-message-2"]])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let first = try await provider.execute(writeRequest(account, action: .syncDraft(draftID: draft.id), draft: draft, outgoing: writeOutgoing(account)))
        #expect(first.draftReference?.providerDraftID == "draft-one" && first.draftReference?.providerMessageID == "draft-message-1")
        draft.providerDraftID = "draft-one"
        let second = try await provider.execute(writeRequest(account, action: .syncDraft(draftID: draft.id), draft: draft, outgoing: writeOutgoing(account)))
        #expect(second.draftReference?.providerMessageID == "draft-message-2")
        #expect(await http.captured().map(\.httpMethod) == ["POST", "PUT"])
    }
    @Test func gmailReplySendPreservesRawBccAndThreadContext() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), draft = Draft(accountID: nil)
        var owned = draft; owned.accountID = account.id
        let http = ScriptedMailHTTP([try writeJSON(["id": "sent-one"])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let receipt = try await provider.execute(writeRequest(account, action: .sendDraft(draftID: owned.id), draft: owned, outgoing: writeOutgoing(account, thread: "thread-one")))
        #expect(receipt.sentProviderMessageID == "sent-one")
        let object = try writeObject(#require(await http.captured().first))
        let raw = try #require(object["raw"] as? String)
        #expect(object["threadId"] as? String == "thread-one")
        #expect(MIMEParser.base64URLDecode(raw).map { String(decoding: $0, as: UTF8.self).contains("Bcc: reviewer@example.invalid") } == true)
    }
    @Test func gmailReplyToLegacyCachedMessageFetchesOnlySourceMetadataBeforeSending() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), source = writeMessage(account)
        let draft = Draft(to: "sam@example.invalid", subject: "Re: Fictional review", body: "Looks good.", replyToMessageID: source.id, accountID: account.id)
        let metadata: [String: Any] = ["id": source.providerID, "threadId": "thread-one", "payload": ["headers": [["name": "Message-ID", "value": "<source@example.invalid>"], ["name": "References", "value": "<earlier@example.invalid>"]]]]
        let http = ScriptedMailHTTP([try writeJSON(metadata), try writeJSON(["id": "sent-reply"])])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        _ = try await provider.execute(writeRequest(account, action: .sendDraft(draftID: draft.id), messages: [source], draft: draft, outgoing: writeOutgoing(account, thread: "thread-one")))
        let requests = await http.captured()
        #expect(requests.count == 2 && requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.path.hasSuffix("/messages/message-one") == true)
        let metadataURL = try #require(requests.first?.url)
        #expect(URLComponents(url: metadataURL, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "format", value: "metadata")) == true)
        let object = try writeObject(requests[1]), encoded = try #require(object["raw"] as? String)
        let raw = try #require(MIMEParser.base64URLDecode(encoded))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("In-Reply-To: <source@example.invalid>"))
        #expect(text.contains("References: <earlier@example.invalid>"))
    }
    @Test func microsoftReplyCreatesDraftThenSetsReviewedRecipientsBeforeSending() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft), source = writeMessage(account)
        let draft = Draft(to: "sam@example.invalid", subject: "Re: Fictional review", body: "Looks good.", replyToMessageID: source.id, accountID: account.id)
        let http = ScriptedMailHTTP([try writeJSON(["id": "reply-draft", "isDraft": true], status: 201), try writeJSON(["id": "reply-draft", "isDraft": true]), MailHTTPResponse(data: Data(), status: 202)])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        _ = try await provider.execute(writeRequest(account, action: .sendDraft(draftID: draft.id), messages: [source], draft: draft, outgoing: writeOutgoing(account)))
        let requests = await http.captured()
        #expect(requests.map { $0.url?.path } == ["/v1.0/me/messages/message-one/createReply", "/v1.0/me/messages/reply-draft", "/v1.0/me/messages/reply-draft/send"])
        let recipients = try #require(writeObject(requests[1])["toRecipients"] as? [[String: [String: String]]])
        #expect(recipients.first?["emailAddress"]?["address"] == "sam@example.invalid")
    }
    @Test func sendTransportFailureHasUnknownOutcomeAndIsNeverRetried() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), draft = Draft(accountID: nil)
        var owned = draft; owned.accountID = account.id
        let http = ScriptedMailHTTP([])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await provider.execute(writeRequest(account, action: .sendDraft(draftID: owned.id), draft: owned, outgoing: writeOutgoing(account))) }
        #expect(await http.captured().count == 1)
    }
    @Test func write401DoesNotReplayTheMutationOrRefreshAutomatically() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), source = writeMessage(account)
        let http = ScriptedMailHTTP([try writeJSON([:], status: 401)])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.authenticationRequired) { try await provider.execute(writeRequest(account, action: .archive(messageIDs: [source.id]), messages: [source])) }
        #expect(await http.captured().count == 1)
    }
    @Test func partiallyAcknowledgedBatchIsUnknownRatherThanSafeToReplay() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), source = writeMessage(account)
        let second = writeMessage(account, providerID: "message-two")
        let http = ScriptedMailHTTP([try writeJSON(["id": source.providerID, "labelIds": ["INBOX", "STARRED"]]), try writeJSON([:], status: 429)])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await provider.execute(writeRequest(account, action: .flag(messageIDs: [source.id, second.id], isFlagged: true), messages: [source, second])) }
        #expect(await http.captured().count == 2)
    }
    @Test func preCancelledWriteDoesNotContactTheServer() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), source = writeMessage(account), http = ScriptedMailHTTP([])
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let task = Task { try await provider.execute(writeRequest(account, action: .archive(messageIDs: [source.id]), messages: [source])) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await http.captured().isEmpty)
    }
    @Test func cancellationAfterDispatchKeepsAnUnknownOutcome() async throws {
        let account = writeAccount(), config = writeConfiguration(.gmail), source = writeMessage(account), http = BlockingMailHTTP()
        let provider = GmailMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let task = Task { try await provider.execute(writeRequest(account, action: .archive(messageIDs: [source.id]), messages: [source])) }
        while !(await http.started()) { await Task.yield() }
        task.cancel()
        // A failed server acknowledgement after cancellation still cannot prove no effect.
        await http.finish(try writeJSON([:], status: 503))
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await task.value }
    }
    @Test func microsoftReadFlagAndMoveUseConstrainedVerbsAndImmutableIDs() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft), source = writeMessage(account)
        let folder = MailFolderDescriptor(id: "work-folder", accountID: account.id, name: "Work")
        let http = ScriptedMailHTTP([try writeJSON(["id": source.providerID, "isRead": true]), try writeJSON(["id": source.providerID, "flag": ["flagStatus": "flagged"]]), try writeJSON(["id": "moved-id", "parentFolderId": folder.id], status: 201)])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        _ = try await provider.execute(writeRequest(account, action: .markRead(messageIDs: [source.id], isRead: true), messages: [source]))
        _ = try await provider.execute(writeRequest(account, action: .flag(messageIDs: [source.id], isFlagged: true), messages: [source]))
        let moved = try await provider.execute(writeRequest(account, action: .move(messageIDs: [source.id], destination: folder), messages: [source]))
        #expect(moved.messages.first?.providerID == "moved-id" && moved.removedProviderMessageIDs == [source.providerID])
        let requests = await http.captured()
        #expect(requests.map(\.httpMethod) == ["PATCH", "PATCH", "POST"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer") == "IdType=\"ImmutableId\"" })
    }
    @Test func microsoftDraftSendAddsOnlyExplicitAttachmentsThenSubmitsOnce() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft), draft = Draft(accountID: nil)
        var owned = draft; owned.accountID = account.id
        let file = OutgoingAttachment(id: UUID(), name: "review.txt", mimeType: "text/plain", data: Data("Fictional attachment".utf8))
        let http = ScriptedMailHTTP([try writeJSON(["id": "draft-one", "isDraft": true], status: 201), try writeJSON(["id": "attachment-one"], status: 201), MailHTTPResponse(data: Data(), status: 202)])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        let receipt = try await provider.execute(writeRequest(account, action: .sendDraft(draftID: owned.id), draft: owned, outgoing: writeOutgoing(account, attachments: [file])))
        #expect(receipt.draftReference?.providerDraftID == "draft-one" && receipt.sentProviderMessageID == "draft-one")
        let requests = await http.captured()
        #expect(requests.map { $0.url?.path } == ["/v1.0/me/messages", "/v1.0/me/messages/draft-one/attachments", "/v1.0/me/messages/draft-one/send"])
        #expect(try writeObject(requests[0])["bccRecipients"] != nil)
        #expect(try writeObject(requests[1])["contentBytes"] as? String == file.data.base64EncodedString())
    }
    @Test func microsoftExistingDraftIsVerifiedBeforeReplacingAttachments() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft)
        var draft = Draft(accountID: account.id); draft.providerDraftID = "draft-one"
        let http = ScriptedMailHTTP([try writeJSON(["id": "draft-one", "isDraft": true]), try writeJSON(["value": [["id": "old-attachment"]]]), try writeJSON(["id": "draft-one", "isDraft": true]), MailHTTPResponse(data: Data(), status: 204)])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        _ = try await provider.execute(writeRequest(account, action: .syncDraft(draftID: draft.id), draft: draft, outgoing: writeOutgoing(account)))
        let requests = await http.captured()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PATCH", "DELETE"])
        #expect(requests.last?.url?.path == "/v1.0/me/messages/draft-one/attachments/old-attachment")
    }
    @Test func microsoftDoesNotOverwriteAnExistingSentMessageAsADraft() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft)
        var draft = Draft(accountID: account.id); draft.providerDraftID = "sent-one"
        let http = ScriptedMailHTTP([try writeJSON(["id": "sent-one", "isDraft": false])])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.invalidRequest) { try await provider.execute(writeRequest(account, action: .syncDraft(draftID: draft.id), draft: draft, outgoing: writeOutgoing(account))) }
        #expect(await http.captured().map(\.httpMethod) == ["GET"])
    }
    @Test func oversizedGraphAttachmentIsRejectedBeforeAnyWrite() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft), draft = Draft(accountID: nil)
        var owned = draft; owned.accountID = account.id
        let file = OutgoingAttachment(id: UUID(), name: "large.bin", mimeType: "application/octet-stream", data: Data(count: 2 * 1_024 * 1_024 + 1))
        let http = ScriptedMailHTTP([])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.invalidRequest) { try await provider.execute(writeRequest(account, action: .syncDraft(draftID: owned.id), draft: owned, outgoing: writeOutgoing(account, attachments: [file]))) }
        #expect(await http.captured().isEmpty)
    }
    @Test func graphAttachmentFailurePreventsSendAndReportsPartialOutcome() async throws {
        let account = writeAccount(.microsoft), config = writeConfiguration(.microsoft), draft = Draft(accountID: nil)
        var owned = draft; owned.accountID = account.id
        let file = OutgoingAttachment(id: UUID(), name: "review.txt", mimeType: "text/plain", data: Data("Fictional".utf8))
        let http = ScriptedMailHTTP([try writeJSON(["id": "draft-one", "isDraft": true]), try writeJSON([:], status: 403)])
        let provider = MicrosoftMailProvider(accountID: account.id, credentialReference: writeReference, configuration: config, credentials: try await writeCredentials(config), http: http)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await provider.execute(writeRequest(account, action: .sendDraft(draftID: owned.id), draft: owned, outgoing: writeOutgoing(account, attachments: [file]))) }
        #expect(await http.captured().count == 2)
    }
}
