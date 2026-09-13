import Foundation
import Testing
@testable import FloraCore

actor ScriptedMailHTTP: MailHTTPClient {
    var responses: [MailHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [MailHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> MailHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw RemoteMailError.networkUnavailable }
        return responses.removeFirst()
    }
    func captured() -> [URLRequest] { requests }
}


actor BlockingMailHTTP: MailHTTPClient {
    private var continuation: CheckedContinuation<MailHTTPResponse, Error>?
    private var began = false
    func send(_ request: URLRequest) async throws -> MailHTTPResponse {
        began = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func started() -> Bool { began }
    func finish(_ response: MailHTTPResponse) { continuation?.resume(returning: response); continuation = nil }
}

private func restJSON(_ object: Any, status: Int = 200) throws -> MailHTTPResponse {
    MailHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: status)
}
private let googleConfig = OAuthClientConfiguration(provider: .gmail, clientID: "fictional-test.apps.googleusercontent.com")
private let microsoftConfig = OAuthClientConfiguration(provider: .microsoft, clientID: "00000000-0000-0000-0000-000000000099")
private let testReference = MailCredentialReference(id: "fictional-unit-test-reference")
private func testCredentials(_ configuration: OAuthClientConfiguration, expired: Bool = false) async throws -> MemoryCredentialStore {
    let store = MemoryCredentialStore()
    let record = OAuthCredential(provider: configuration.provider, clientID: configuration.clientID,
                                 accessToken: "FICTIONAL_TEST_ACCESS", refreshToken: "FICTIONAL_TEST_REFRESH",
                                 expiresAt: Date().addingTimeInterval(expired ? -100 : 3600), scope: configuration.scopes.joined(separator: " "))
    try await store.write(JSONEncoder().encode(record), reference: testReference)
    return store
}
private func gmailMessage(_ id: String, labels: [String] = ["INBOX", "UNREAD"]) -> [String: Any] {
    ["id": id, "threadId": "thread-\(id)", "labelIds": labels, "internalDate": "1800000000000",
     "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "Jane <jane@example.invalid>"], ["name": "To", "value": "reader@example.invalid"], ["name": "Subject", "value": "Review \(id)"]],
                 "body": ["data": Data("Please review the proposal.".utf8).base64URLString, "size": 27]]]
}
private func graphMessage(_ id: String, folder: String = "folder-inbox") -> [String: Any] {
    ["id": id, "conversationId": "conversation-1", "subject": "Proposal", "parentFolderId": folder, "isRead": false,
     "from": ["emailAddress": ["name": "Jane", "address": "jane@example.invalid"]], "toRecipients": [],
     "body": ["contentType": "html", "content": "<script>malicious()</script><p>Hello 世界</p><img src='https://tracker.invalid/x'>"],
     "receivedDateTime": "2026-09-13T10:00:00Z", "flag": ["flagStatus": "notFlagged"], "importance": "high", "hasAttachments": false]
}

@Suite("Read-only OAuth and REST providers")
@MainActor
struct RESTMailProviderTests {
    @Test func authorizationUsesPKCEStateAndReadOnlyScopes() throws {
        let service = OAuthService(credentials: MemoryCredentialStore(), http: ScriptedMailHTTP([]))
        let redirect = try #require(URL(string: "http://127.0.0.1:54321/oauth/callback"))
        let google = try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: redirect)
        let other = try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: redirect)
        let googleItems = try #require(URLComponents(url: google.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(googleItems.first { $0.name == "scope" }?.value == "https://www.googleapis.com/auth/gmail.readonly")
        #expect(googleItems.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(googleItems.first { $0.name == "code_challenge" }?.value?.count == 43)
        #expect(google.authorizationURL != other.authorizationURL)
        let microsoft = try service.makeAuthorizationRequest(configuration: microsoftConfig, redirectURI: redirect)
        #expect(microsoft.authorizationURL.path == "/common/oauth2/v2.0/authorize")
        #expect(microsoftConfig.scopes.contains("https://graph.microsoft.com/Mail.Read"))
        #expect(!microsoftConfig.scopes.contains { $0.contains("Write") || $0.contains("Send") })
        #expect(throws: RemoteMailError.invalidConfiguration) {
            try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: #require(URL(string: "http://192.168.1.1:54321/callback")))
        }
    }

    @Test func microsoftLocalhostRedirectAndGoogleLiteralBoundary() throws {
        let service = OAuthService(credentials: MemoryCredentialStore(), http: ScriptedMailHTTP([]))
        let redirect = try #require(URL(string: "http://localhost:54321/oauth/callback"))
        let request = try service.makeAuthorizationRequest(configuration: microsoftConfig, redirectURI: redirect)
        #expect(request.redirectURI.host == "localhost")
        #expect(throws: RemoteMailError.invalidConfiguration) { try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: redirect) }
    }
    @Test func gmailQuotaFailureOffersRetryInsteadOfReauthentication() throws {
        let quota = try restJSON(["error": ["errors": [["reason": "userRateLimitExceeded", "message": "PRIVATE_PROVIDER_MESSAGE"]]]], status: 403)
        #expect(throws: RemoteMailError.rateLimited) { try MailHTTP.checked(quota) }
        #expect(RemoteMailError.rateLimited.syncError == .rateLimited)
        let denied = try restJSON(["error": ["errors": [["reason": "insufficientPermissions"]]]], status: 403)
        #expect(throws: RemoteMailError.authorizationDenied) { try MailHTTP.checked(denied) }
    }
    @Test func invalidCallbackCannotExchangeOrPersistCredentials() async throws {
        let http = ScriptedMailHTTP([]), store = MemoryCredentialStore()
        let service = OAuthService(credentials: store, http: http)
        let request = try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: #require(URL(string: "http://127.0.0.1:54321/callback")))
        await #expect(throws: RemoteMailError.authenticationRequired) {
            try await service.exchange(callbackURL: #require(URL(string: "http://127.0.0.1:54321/callback?state=wrong&code=fictional")), request: request, credentialReference: testReference)
        }
        #expect(await http.captured().isEmpty)
        #expect(await store.read(reference: testReference) == nil)
    }
    @Test func validExchangePersistsSecretOnlyThroughCredentialStore() async throws {
        let response = try restJSON(["access_token": "FICTIONAL_NEW_ACCESS", "refresh_token": "FICTIONAL_NEW_REFRESH", "token_type": "Bearer", "expires_in": 3600, "scope": googleConfig.scopes.joined(separator: " ")])
        let http = ScriptedMailHTTP([response]), store = MemoryCredentialStore()
        let service = OAuthService(credentials: store, http: http)
        let request = try service.makeAuthorizationRequest(configuration: googleConfig, redirectURI: #require(URL(string: "http://127.0.0.1:54321/callback")))
        let state = try #require(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        var callback = try #require(URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false))
        callback.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "FICTIONAL_CODE")]
        try await service.exchange(callbackURL: #require(callback.url), request: request, credentialReference: testReference)
        let stored = try #require(await store.read(reference: testReference))
        let decoded = try JSONDecoder().decode(OAuthCredential.self, from: stored)
        #expect(decoded.refreshToken == "FICTIONAL_NEW_REFRESH")
        let sent = try #require(await http.captured().first)
        #expect(sent.url?.host == "oauth2.googleapis.com")
        #expect(sent.httpMethod == "POST")
        let body = String(decoding: try #require(sent.httpBody), as: UTF8.self)
        #expect(body.contains("code_verifier="))
        #expect(!body.contains("client_secret"))
        #expect(!String(decoding: try JSONEncoder().encode(testReference), as: UTF8.self).contains("FICTIONAL_NEW_REFRESH"))
    }
    @Test func refreshRotatesTokensAndRejectsScopeEscalation() async throws {
        let store = try await testCredentials(googleConfig, expired: true)
        let http = ScriptedMailHTTP([try restJSON(["access_token": "FICTIONAL_ROTATED", "refresh_token": "FICTIONAL_ROTATED_REFRESH", "token_type": "Bearer", "expires_in": 3600, "scope": googleConfig.scopes[0]])])
        let tokens = OAuthAccessTokenProvider(configuration: googleConfig, reference: testReference, credentials: store, http: http)
        #expect(try await tokens.accessToken() == "FICTIONAL_ROTATED")
        let stored = try #require(await store.read(reference: testReference))
        #expect(try JSONDecoder().decode(OAuthCredential.self, from: stored).refreshToken == "FICTIONAL_ROTATED_REFRESH")
        let badHTTP = ScriptedMailHTTP([try restJSON(["access_token": "FICTIONAL_OVERREACH", "token_type": "Bearer", "expires_in": 3600, "scope": googleConfig.scopes[0] + " https://www.googleapis.com/auth/gmail.modify"])])
        let bad = OAuthAccessTokenProvider(configuration: googleConfig, reference: testReference, credentials: store, http: badHTTP)
        await #expect(throws: RemoteMailError.authorizationDenied) { try await bad.accessToken(forceRefresh: true) }
        #expect(await store.read(reference: testReference) == stored)
    }

    @Test func cancelledRefreshCannotRewriteRemovedOrOldCredentials() async throws {
        let store = try await testCredentials(googleConfig, expired: true)
        let original = await store.read(reference: testReference)
        let http = BlockingMailHTTP()
        let tokens = OAuthAccessTokenProvider(configuration: googleConfig, reference: testReference, credentials: store, http: http)
        let task = Task { try await tokens.accessToken() }
        while !(await http.started()) { await Task.yield() }
        task.cancel()
        await http.finish(try restJSON(["access_token": "FICTIONAL_LATE_ACCESS", "refresh_token": "FICTIONAL_LATE_REFRESH", "token_type": "Bearer", "expires_in": 3600, "scope": googleConfig.scopes[0]]))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await store.read(reference: testReference) == original)
    }
    @Test func storedScopeOverreachIsRejectedBeforeAnyMailRequest() async throws {
        let store = MemoryCredentialStore()
        let credential = OAuthCredential(provider: .gmail, clientID: googleConfig.clientID, accessToken: "FICTIONAL_TEST", refreshToken: "FICTIONAL_REFRESH", expiresAt: Date().addingTimeInterval(3600), scope: googleConfig.scopes[0] + " https://www.googleapis.com/auth/gmail.send")
        try await store.write(JSONEncoder().encode(credential), reference: testReference)
        let http = ScriptedMailHTTP([])
        let tokens = OAuthAccessTokenProvider(configuration: googleConfig, reference: testReference, credentials: store, http: http)
        await #expect(throws: RemoteMailError.authorizationDenied) { try await tokens.accessToken() }
        #expect(await http.captured().isEmpty)
    }
    @Test func credentialCannotBeReusedAcrossProviderOrClient() async throws {
        let store = try await testCredentials(googleConfig)
        let http = ScriptedMailHTTP([])
        let tokens = OAuthAccessTokenProvider(configuration: microsoftConfig, reference: testReference, credentials: store, http: http)
        await #expect(throws: RemoteMailError.authenticationRequired) { try await tokens.accessToken() }
        #expect(await http.captured().isEmpty)
        await store.delete(reference: testReference)
        #expect(await store.read(reference: testReference) == nil)
    }
    @Test func transportRejectsInsecureAndForeignURLs() throws {
        for raw in ["http://gmail.googleapis.com/gmail/v1/me", "https://gmail.googleapis.com.evil.invalid/", "https://user:secret@graph.microsoft.com/v1.0/me", "https://graph.microsoft.com:8443/v1.0/me", "https://example.invalid/"] {
            #expect(throws: RemoteMailError.invalidConfiguration) { try SecureMailHTTPClient.validate(#require(URL(string: raw))) }
        }
        try SecureMailHTTPClient.validate(#require(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")))
    }
    @Test func gmailMappingPreservesLabelsUnicodeAndAttachmentMetadata() throws {
        let json: [String: Any] = ["id": "gmail-1", "threadId": "thread-1", "labelIds": ["INBOX", "IMPORTANT", "Label_Research", "UNREAD"], "internalDate": "1800000000000",
                                  "payload": ["mimeType": "multipart/mixed", "headers": [["name": "From", "value": "=?UTF-8?B?SmFuZQ==?= <jane@example.invalid>"], ["name": "Subject", "value": "研究 proposal"]],
                                              "parts": [["partId": "0", "mimeType": "text/plain", "body": ["data": Data("Hi 世界\nPlease review.".utf8).base64URLString]],
                                                        ["partId": "1", "mimeType": "application/pdf", "filename": "proposal.pdf", "body": ["attachmentId": "att-1", "size": 512]]]]]
        let account = UUID(), wire = try MailHTTP.decode(GmailMessageDTO.self, restJSON(json).data)
        let message = try GmailMapping.message(wire, accountID: account)
        #expect(message.from.name == "Jane")
        #expect(message.body.contains("Hi 世界"))
        #expect(message.providerFolderIDs.contains("Label_Research"))
        #expect(message.isImportant && !message.isFlagged && !message.isRead)
        #expect(message.attachments.first?.mimeType == "application/pdf")
        #expect(message.attachments.first?.downloadState == .notDownloaded)
        #expect(message.id == StableMailIdentity.message(accountID: account, providerID: "gmail-1"))
        #expect(try GmailMapping.message(wire, accountID: UUID()).id != message.id)
    }
    @Test func gmailInitialPaginationAndHistoryOnlyFetchChangedMessages() async throws {
        let http = ScriptedMailHTTP([
            try restJSON(["emailAddress": "reader@example.invalid", "historyId": "100"]),
            try restJSON(["messages": [["id": "one"]], "nextPageToken": "page-two"]), try restJSON(gmailMessage("one")),
            try restJSON(["messages": [["id": "two"]]]), try restJSON(gmailMessage("two")),
            try restJSON(["historyId": "120", "history": [["messages": [["id": "one"], ["id": "deleted"]]]]]),
            try restJSON([:], status: 404), try restJSON(gmailMessage("one", labels: ["INBOX"]))
        ])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        let first = try await provider.fetchPage(MailSyncRequest(limit: 1, since: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(first.hasMore && !first.checkpoint.initialComplete)
        let second = try await provider.fetchPage(MailSyncRequest(checkpoint: first.checkpoint, limit: 1, since: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(!second.hasMore && second.checkpoint.initialComplete)
        let third = try await provider.fetchPage(MailSyncRequest(checkpoint: second.checkpoint, limit: 2, since: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(third.messages.count == 1 && third.messages[0].isRead)
        #expect(third.deletedProviderMessageIDs == ["deleted"])
        let urls = await http.captured().compactMap(\.url)
        #expect(urls[3].query?.contains("pageToken=page-two") == true)
        #expect(urls[5].query?.contains("startHistoryId=100") == true)
        #expect(urls.filter { $0.path.hasSuffix("/messages/two") }.count == 1)
    }
    @Test func gmailMissingHistoryRequestsBoundedRecovery() async throws {
        let http = ScriptedMailHTTP([try restJSON([:], status: 404)])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        let state = "{\"historyID\":\"old\",\"pendingIDs\":[]}"
        await #expect(throws: RemoteMailError.staleCheckpoint) { try await provider.fetchPage(MailSyncRequest(checkpoint: SyncCheckpoint(opaqueState: state, initialComplete: true), since: Date())) }
    }
    @Test func providersExposeNoMutationAndDoNotContactServerForWrites() async throws {
        let http = ScriptedMailHTTP([])
        let provider: any ReadOnlyMailProvider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: MemoryCredentialStore(), http: http)
        await #expect(throws: MailActionError.readOnlyAccount) { try await provider.perform(ProposedAction(type: .archive(messageIDs: [UUID()]), explanation: "Forbidden"), confirmed: true) }
        #expect(await http.captured().isEmpty)
    }
    @Test func microsoftMappingUsesInertHTMLAndImmutableNamespace() throws {
        let wire = try MailHTTP.decode(GraphMessageDTO.self, restJSON(graphMessage("immutable-1")).data)
        let message = try MicrosoftMapping.message(wire, accountID: UUID(), role: .inbox)
        #expect(message.body == "Hello 世界")
        #expect(!message.body.contains("malicious"))
        #expect(message.isImportant && !message.isFlagged)
        #expect(message.providerThreadID == "conversation-1")
        #expect(message.providerFolderIDs == ["folder-inbox"])
    }
    @Test func microsoftDeltaResolvesMovedMessagesWithoutFalseDeletion() async throws {
        let folders: [MailHTTPResponse] = try ["inbox", "sentitems", "drafts", "deleteditems", "archive"].map { role in
            try restJSON(["id": "folder-\(role)", "displayName": role, "childFolderCount": 0])
        } + [restJSON(["value": []])]
        let delta = "https://graph.microsoft.com/v1.0/me/mailFolders/folder-inbox/messages/delta?$deltatoken=fictional"
        let http = ScriptedMailHTTP(folders + [try restJSON(["value": [["id": "immutable-1", "@removed": ["reason": "deleted"]]], "@odata.deltaLink": delta]), try restJSON(graphMessage("immutable-1", folder: "folder-archive"))])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        let page = try await provider.fetchPage(MailSyncRequest(limit: 5, since: Date(timeIntervalSince1970: 1_790_000_000)))
        #expect(page.messages.first?.folder == .archive)
        #expect(page.deletedProviderMessageIDs.isEmpty)
        let requests = await http.captured()
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true })
    }
    @Test func microsoftRejectsForeignContinuationWithoutCredentialLeak() async throws {
        let folders = try ["inbox", "sentitems", "drafts", "deleteditems", "archive"].map { role in try restJSON(["id": "folder-\(role)", "displayName": role, "childFolderCount": 0]) }
        let http = ScriptedMailHTTP(folders + [try restJSON(["value": [], "@odata.nextLink": "https://evil.invalid/steal"])])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        await #expect(throws: RemoteMailError.malformedResponse) { try await provider.fetchRemoteFolders() }
        #expect(await http.captured().allSatisfy { $0.url?.host == "graph.microsoft.com" })
    }
    @Test func authenticationExpirationRefreshesOnceAndMapsFailureSafely() async throws {
        let http = ScriptedMailHTTP([try restJSON(["private": "NEVER_DISPLAY_THIS"], status: 401), try restJSON(["error": "invalid_grant", "private": "NEVER_DISPLAY_THIS"], status: 400)])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        await #expect(throws: RemoteMailError.authenticationRequired) { try await provider.fetchAccounts() }
        #expect(await http.captured().count == 2)
        #expect(RemoteMailError.authenticationRequired.syncError == .authenticationRequired)
        #expect(!RemoteMailError.authenticationRequired.localizedDescription.contains("NEVER_DISPLAY_THIS"))
    }
    @Test func cancelledProviderReadDoesNotStartNetwork() async throws {
        let http = ScriptedMailHTTP([])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: MemoryCredentialStore(), http: http)
        let task = Task { @MainActor in try await provider.fetchPage(MailSyncRequest(since: Date())) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await http.captured().isEmpty)
    }
}


@Suite("REST read-only recovery")
@MainActor
struct RESTRecoveryTests {
    private func folderResponses() throws -> [MailHTTPResponse] {
        try ["inbox", "sentitems", "drafts", "deleteditems", "archive"].map {
            try restJSON(["id": "folder-\($0)", "displayName": $0, "childFolderCount": 0])
        } + [restJSON(["value": []])]
    }
    @Test func graphContinuationAcceptsEquivalentODataPathsWithoutChangingIDs() throws {
        let expected = try #require(URL(string: "https://graph.microsoft.com/v1.0/me/mailFolders/Folder%2FID/messages/delta"))
        let alternate = try #require(URL(string: "https://graph.microsoft.com/v1.0/me/mailfolders('Folder%2FID')/messages/delta?$skiptoken=fictional"))
        try GraphResourcePath.validate(alternate, matches: expected)
        for raw in ["https://graph.microsoft.com/v1.0/me/mailfolders('folder%2FID')/messages/delta", "https://graph.microsoft.com/v1.0/users/someone/mailfolders('Folder%2FID')/messages/delta", "https://graph.microsoft.com/v1.0/me/mailfolders('Other')/messages/delta"] {
            #expect(throws: RemoteMailError.malformedResponse) { try GraphResourcePath.validate(#require(URL(string: raw)), matches: expected) }
        }
    }
    @Test func graphRemovedFolderCheckpointAdvancesWithoutDeletingCachedMessages() async throws {
        let initialState: [String: Any] = ["folders": [["id": "folder-inbox", "role": "inbox"], ["id": "removed-folder", "role": "archive"], ["id": "folder-archive", "role": "archive"]], "links": [:], "index": 1, "pendingIDs": ["old-pending-message"], "pendingLink": "https://graph.microsoft.com/v1.0/me/mailFolders/removed-folder/messages/delta?$skiptoken=old", "pendingCompletesFolder": false]
        let http = ScriptedMailHTTP(try folderResponses() + [restJSON(["value": [], "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/mailFolders/folder-archive/messages/delta?$deltatoken=new"])])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        let checkpoint = SyncCheckpoint(opaqueState: String(decoding: try JSONSerialization.data(withJSONObject: initialState), as: UTF8.self), initialComplete: true)
        let page = try await provider.fetchPage(MailSyncRequest(checkpoint: checkpoint, since: Date()))
        #expect(page.messages.isEmpty && page.deletedProviderMessageIDs.isEmpty)
        #expect(page.checkpoint.opaqueState?.contains("removed-folder") == false)
        #expect(await http.captured().last?.url?.path.contains("folder-archive") == true)
    }
    @Test func graphExpiredDeltaRestartsOnlyItsFolderAndRetainsOtherLinks() async throws {
        let old = "https://graph.microsoft.com/v1.0/me/mailFolders/folder-inbox/messages/delta?$deltatoken=expired"
        let archive = "https://graph.microsoft.com/v1.0/me/mailFolders/folder-archive/messages/delta?$deltatoken=keep"
        let initialState: [String: Any] = ["folders": [["id": "folder-inbox", "role": "inbox"], ["id": "folder-archive", "role": "archive"]], "links": ["folder-inbox": old, "folder-archive": archive], "index": 0, "pendingIDs": [], "pendingCompletesFolder": false]
        let http = ScriptedMailHTTP(try folderResponses() + [restJSON([:], status: 410), restJSON(["value": [], "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/mailfolders('folder-inbox')/messages/delta?$deltatoken=new"])])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        let checkpoint = SyncCheckpoint(opaqueState: String(decoding: try JSONSerialization.data(withJSONObject: initialState), as: UTF8.self), initialComplete: true)
        let page = try await provider.fetchPage(MailSyncRequest(checkpoint: checkpoint, since: Date()))
        let saved = try #require(page.checkpoint.opaqueState)
        #expect(saved.contains("keep") && !saved.contains("expired"))
        let requests = await http.captured()
        #expect(requests[6].url?.query?.contains("deltatoken=expired") == true)
        #expect(requests[7].url?.query?.contains("receivedDateTime") == true)
        #expect(page.deletedProviderMessageIDs.isEmpty)
    }
    @Test func malformedGmailBodyPreservesEnvelopeAndDoesNotBlockFollowingMessage() async throws {
        var broken = gmailMessage("broken")
        var payload = try #require(broken["payload"] as? [String: Any])
        payload["body"] = ["data": 12345]; broken["payload"] = payload
        let http = ScriptedMailHTTP([try restJSON(["emailAddress": "reader@example.invalid", "historyId": "100"]), try restJSON(["messages": [["id": "broken"], ["id": "valid"]]]), try restJSON(broken), try restJSON(gmailMessage("valid"))])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        let page = try await provider.fetchPage(MailSyncRequest(since: Date()))
        #expect(page.messages.count == 2 && page.checkpoint.initialComplete)
        #expect(page.messages[0].subject == "Review broken" && page.messages[0].from.email == "jane@example.invalid")
        #expect(page.messages[0].body.isEmpty && !page.messages[0].contentWarnings.isEmpty)
        #expect(page.messages[1].body == "Please review the proposal.")
    }
    @Test func invalidGmailBase64NeverBecomesOriginalText() async throws {
        var broken = gmailMessage("broken")
        var payload = try #require(broken["payload"] as? [String: Any])
        payload["body"] = ["data": "invalid!base64"]; broken["payload"] = payload
        let http = ScriptedMailHTTP([try restJSON(["messages": [broken]])])
        let accountID = UUID()
        let provider = GmailMailProvider(accountID: accountID, credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        let source = MailMessage(providerID: "broken", accountID: accountID, threadID: StableMailIdentity.thread(accountID: accountID, providerID: "thread-broken"), from: MailAddress(name: "Jane", email: "jane@example.invalid"), to: [], subject: "Review broken", body: "", providerThreadID: "thread-broken")
        let thread = try await provider.fetchThread(message: source)
        #expect(thread.messages.first?.body.isEmpty == true)
        #expect(thread.messages.first?.contentWarnings.isEmpty == false)
        #expect(await http.captured().first?.url?.path.hasSuffix("/threads/thread-broken") == true)
    }
    @Test func malformedGraphBodyPreservesEnvelopeAndOtherMessages() async throws {
        var broken = graphMessage("broken"); broken["body"] = ["contentType": "html", "content": 123]
        let http = ScriptedMailHTTP(try folderResponses() + [restJSON(["value": [["id": "broken", "body": 123], ["id": "valid"]], "@odata.deltaLink": "https://graph.microsoft.com/v1.0/me/mailfolders('folder-inbox')/messages/delta?$deltatoken=new"]), restJSON(broken), restJSON(graphMessage("valid"))])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        let page = try await provider.fetchPage(MailSyncRequest(since: Date()))
        #expect(page.messages.count == 2)
        #expect(page.messages[0].body.isEmpty && page.messages[0].subject == "Proposal")
        #expect(!page.messages[0].contentWarnings.isEmpty)
        #expect(page.messages[1].body == "Hello 世界")
    }
    @Test func gmailAttachmentHydrationAuthenticationFailureDoesNotBecomeContentFallback() async throws {
        var wire = gmailMessage("body-attachment")
        var payload = try #require(wire["payload"] as? [String: Any]); payload["body"] = ["attachmentId": "body-part", "size": 100]; wire["payload"] = payload
        let http = ScriptedMailHTTP([try restJSON(["messages": [wire]]), try restJSON([:], status: 403)])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        await #expect(throws: RemoteMailError.authorizationDenied) { try await provider.fetchThread(providerThreadID: "thread-body-attachment") }
    }
    @Test func graphThreadWorksFromPersistedIdentityAndRejectsCrossAccountSource() async throws {
        let accountID = UUID()
        let source = MailMessage(providerID: "one", accountID: accountID, threadID: StableMailIdentity.thread(accountID: accountID, providerID: "conversation-1"), from: MailAddress(name: "Jane", email: "jane@example.invalid"), to: [], subject: "Proposal", body: "", providerThreadID: "conversation-1")
        let http = ScriptedMailHTTP(try folderResponses() + [restJSON(["value": [["id": "one"]]]), restJSON(graphMessage("one"))])
        let provider = MicrosoftMailProvider(accountID: accountID, credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        let thread = try await provider.fetchThread(message: source)
        #expect(thread.id == source.threadID && thread.messages.count == 1)
        #expect(thread.messages.first?.folder == .inbox)
        var other = source; other.accountID = UUID()
        await #expect(throws: RemoteMailError.invalidConfiguration) { try await provider.fetchThread(message: other) }
        #expect(await http.captured().count == 8)
    }
    @Test func threadRejectsAnotherConversationFromTheSameMailbox() async throws {
        var wire = graphMessage("one"); wire["conversationId"] = "another-thread"
        let http = ScriptedMailHTTP(try folderResponses() + [restJSON(["value": [["id": "one"]]]), restJSON(wire)])
        let provider = MicrosoftMailProvider(accountID: UUID(), credentialReference: testReference, configuration: microsoftConfig, credentials: try await testCredentials(microsoftConfig), http: http)
        await #expect(throws: RemoteMailError.malformedResponse) { try await provider.fetchThread(providerConversationID: "conversation-1") }
    }
    @Test func gmailAttachedMIMETreeDoesNotTriggerAutomaticDownloadsOrEnterVisibleBody() async throws {
        var wire = gmailMessage("attached-tree")
        wire["payload"] = ["mimeType": "multipart/mixed", "headers": [["name": "Subject", "value": "Attached message"]], "parts": [
            ["partId": "0", "mimeType": "text/plain", "body": ["data": Data("Visible body".utf8).base64URLString]],
            ["partId": "1", "mimeType": "multipart/mixed", "headers": [["name": "Content-Disposition", "value": "attachment; filename*=UTF-8''research%20%E4%B8%AD.mime"]], "body": ["attachmentId": "forwarded", "size": 300], "parts": [
                ["partId": "1.1", "mimeType": "text/plain", "body": ["attachmentId": "private-attached-text", "size": 30]]
            ]]
        ]]
        let http = ScriptedMailHTTP([try restJSON(["messages": [wire]])])
        let provider = GmailMailProvider(accountID: UUID(), credentialReference: testReference, configuration: googleConfig, credentials: try await testCredentials(googleConfig), http: http)
        let thread = try await provider.fetchThread(providerThreadID: "thread-attached-tree")
        #expect(thread.messages.first?.body == "Visible body")
        #expect(thread.messages.first?.attachments.first?.name == "research 中.mime")
        #expect(await http.captured().count == 1)
    }
    @Test func multibytePreviewIsBoundedByUTF8BytesAndDisclosesTruncation() throws {
        var raw = graphMessage("long"); raw["body"] = ["contentType": "text", "content": String(repeating: "界", count: 200_000)]
        let wire = try MailHTTP.decode(GraphMessageDTO.self, restJSON(raw).data)
        let result = try MicrosoftMapping.message(wire, accountID: UUID(), role: .inbox)
        #expect(result.body.utf8.count <= MIMEParser.maximumTextBytes)
        #expect(!result.body.contains("�") && !result.contentWarnings.isEmpty)
    }
}
