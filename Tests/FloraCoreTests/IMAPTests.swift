import Foundation
import Testing
@testable import FloraCore

@Suite("iCloud read-only IMAP")
@MainActor
struct IMAPTests {
    private func fixture(server: IMAPFixtureServer, clock: IMAPFixtureClock? = nil) async throws -> ICloudMailProvider {
        let store = MemoryCredentialStore(); let reference = MailCredentialReference(id: "fixture-icloud")
        let credential = IMAPCredential(username: "reader@icloud.com", appSpecificPassword: String(repeating: "x", count: 16))
        try await store.write(JSONEncoder().encode(credential), reference: reference)
        let account = MailAccount(id: UUID(uuidString: "11000000-0000-0000-0000-000000000001") ?? UUID(), name: "Fixture iCloud", address: MailAddress(name: "Reader", email: "reader@icloud.com"), providerType: .iCloud, credentialReference: reference)
        return ICloudMailProvider(account: account, credentials: store, sessionFactory: server, now: { clock?.date ?? Date() })
    }
    @Test func credentialsRejectControlCharactersAndPrimaryPasswordShape() throws {
        #expect(throws: IMAPError.invalidConfiguration) { try IMAPCredential(username: "reader@icloud.com\r\nA STORE 1", appSpecificPassword: String(repeating: "x", count: 16)).validated() }
        #expect(throws: IMAPError.invalidConfiguration) { try IMAPCredential(username: "reader@icloud.com", appSpecificPassword: "Personal-password1!").validated() }
        #expect(try IMAPCredential(username: " reader@icloud.com ", appSpecificPassword: String(repeating: "x", count: 16)).validated().username == "reader@icloud.com")
        #expect(throws: IMAPError.invalidConfiguration) { try IMAPCommand.examine("INBOX\r\nA EXPUNGE").wireText() }
        #expect(throws: IMAPError.invalidConfiguration) { try IMAPCommand.body(uid: 1, section: "1] FLAGS", maximumBytes: 20).wireText() }
        #expect(try IMAPCommand.examine("Folder \"one\"").wireText() == "EXAMINE \"Folder \\\"one\\\"\"")
    }
    @Test func folderDiscoveryUsesSpecialUseAndModifiedUTF7() throws {
        let response = IMAPResponse(lines: [#"* LIST (\HasNoChildren) "/" "INBOX""#, #"* LIST (\Sent) "/" "Sent Messages""#, #"* LIST (\Noselect) "/" "Container""#, #"* LIST () "/" "&ZeVnLIqe-""#])
        let folders = try IMAPMapping.folders(response, accountID: UUID())
        #expect(folders.count == 3); #expect(folders.first?.role == .inbox)
        #expect(folders.contains { $0.name == "日本語" })
        #expect(IMAPMailboxName.decode("News &- Updates") == "News & Updates")
    }
    @Test func literalCannotSpoofCompletionAndMalformedLiteralFails() throws {
        let body = "\r\nF1 OK fake\r\n<script>untrusted</script>"
        var parser = IMAPValueParser(Data("* 1 FETCH (UID 7 BODY[1] {\(body.utf8.count)}\r\n\(body))\r\n".utf8))
        let parsed = try parser.parse()
        #expect(parsed.last?.values?.last?.bytes == Data(body.utf8))
        var broken = IMAPValueParser(Data("* 1 FETCH (BODY[1] {100}\r\nshort)".utf8))
        #expect(throws: IMAPError.malformedResponse) { try broken.parse() }
    }
    @Test func initialPaginationIncrementalCheckpointAndNoAttachmentAutoload() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); let provider = try await fixture(server: server)
        let first = try await provider.fetchPage(MailSyncRequest(limit: 1, since: Date(timeIntervalSince1970: 0)))
        #expect(first.messages.count == 1); #expect(first.hasMore)
        #expect(first.messages[0].body == "Hello Flora!\nReview by Friday.")
        #expect(first.messages[0].subject == "研究 Update")
        #expect(first.messages[0].attachments.first?.mimeType == "application/pdf")
        #expect(first.messages[0].isRead); #expect(first.messages[0].isFlagged)
        #expect(await server.requestedBodySections == ["1"])
        let second = try await provider.fetchPage(MailSyncRequest(checkpoint: first.checkpoint, limit: 1, since: Date()))
        #expect(!second.hasMore); #expect(first.messages[0].id != second.messages[0].id)
        await server.setUIDs([1, 2, 3])
        let incremental = try await provider.fetchPage(MailSyncRequest(checkpoint: second.checkpoint, limit: 10, since: Date(timeIntervalSince1970: 0)))
        #expect(incremental.messages.count == 1)
        #expect(await server.metadataUIDs == [2, 1, 3])
        let again = try await provider.fetchPage(MailSyncRequest(checkpoint: incremental.checkpoint, limit: 10, since: Date(timeIntervalSince1970: 0)))
        #expect(again.messages.isEmpty)
        let attachment = try #require(first.messages[0].attachments.first)
        let data = try await provider.downloadAttachment(message: first.messages[0], attachment: attachment)
        #expect(String(data: data, encoding: .utf8) == "%PDF-1.4")
        #expect(await server.requestedBodySections.last == "2")
        let commands = await server.commands
        #expect(commands.contains { $0.hasPrefix("EXAMINE ") })
        #expect(!commands.contains { $0.hasPrefix("SELECT ") || $0.contains(" STORE ") || $0.contains("EXPUNGE") || $0.contains("APPEND") })
    }
    @Test func incrementalRefreshesFlagsAndRemovalsWithoutBodies() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); let provider = try await fixture(server: server)
        let initial = try await provider.fetchPage(MailSyncRequest(limit: 10, since: Date(timeIntervalSince1970: 0)))
        await server.setUIDs([2])
        let update = try await provider.fetchPage(MailSyncRequest(checkpoint: initial.checkpoint, since: Date(timeIntervalSince1970: 0)))
        #expect(update.messages.isEmpty)
        #expect(update.deletedProviderMessageIDs == [initial.messages[1].providerID])
        #expect(update.messageStateUpdates.count == 1)
        #expect(update.messageStateUpdates[0].isRead)
        #expect(!update.messageStateUpdates[0].isFlagged)
        #expect(await server.requestedBodySections.count == 2)
    }
    @Test func uidValidityChangeCreatesNewIdentityAndRefusesOldAttachment() async throws {
        let server = IMAPFixtureServer(uids: [1]); let provider = try await fixture(server: server)
        let old = try await provider.fetchPage(MailSyncRequest(since: Date(timeIntervalSince1970: 0)))
        await server.setValidity(88)
        let current = try await provider.fetchPage(MailSyncRequest(checkpoint: old.checkpoint, since: Date(timeIntervalSince1970: 0)))
        #expect(old.messages[0].id != current.messages[0].id)
        let attachment = try #require(old.messages[0].attachments.first)
        await #expect(throws: IMAPError.mailboxChanged) { try await provider.downloadAttachment(message: old.messages[0], attachment: attachment) }
    }
    @Test func pageFailureClosesSessionAndDoesNotReturnPartialCheckpoint() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); await server.failMetadata(1)
        let provider = try await fixture(server: server)
        await #expect(throws: IMAPError.malformedResponse) { try await provider.fetchPage(MailSyncRequest(limit: 2, since: Date(timeIntervalSince1970: 0))) }
        #expect(await server.closes == 1)
    }
    @Test func cancellationStopsReadAndClosesSession() async throws {
        let server = IMAPFixtureServer(uids: [1]); await server.delayBodies()
        let provider = try await fixture(server: server)
        let task = Task { try await provider.fetchPage(MailSyncRequest(since: Date(timeIntervalSince1970: 0))) }
        while !(await server.bodyStarted) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await server.closes == 1)
    }
    @Test func malformedMIMEProducesVisibleWarningAndLaterMessagesStillSync() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); await server.malformedStructure(2)
        let provider = try await fixture(server: server)
        let page = try await provider.fetchPage(MailSyncRequest(limit: 10, since: Date(timeIntervalSince1970: 0)))
        #expect(page.messages.count == 2 && !page.hasMore)
        #expect(page.messages[0].body.isEmpty && !page.messages[0].contentWarnings.isEmpty)
        #expect(page.messages[0].subject == "研究 Update")
        #expect(page.messages[1].body.contains("Hello Flora!"))
        let next = try await provider.fetchPage(MailSyncRequest(checkpoint: page.checkpoint, since: Date(timeIntervalSince1970: 0)))
        #expect(next.messages.isEmpty)
        #expect(await server.metadataUIDs == [2, 1])
    }
    @Test func invalidStructureSyntaxRetriesHeadersWithoutStallingPage() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); await server.malformedRecord(2)
        let provider = try await fixture(server: server)
        let page = try await provider.fetchPage(MailSyncRequest(limit: 10, since: Date(timeIntervalSince1970: 0)))
        #expect(page.messages.count == 2)
        #expect(page.messages[0].subject == "Headers remain readable")
        #expect(page.messages[0].body.isEmpty && !page.messages[0].contentWarnings.isEmpty)
        #expect(await server.commands.contains { $0.contains("HEADER.FIELDS") && !$0.contains("BODYSTRUCTURE") })
    }
    @Test func corruptTransferEncodingRemainsSeparateFromOriginalAndLaterUIDs() async throws {
        let server = IMAPFixtureServer(uids: [1, 2]); await server.corruptBody(2)
        let provider = try await fixture(server: server)
        let page = try await provider.fetchPage(MailSyncRequest(limit: 10, since: Date(timeIntervalSince1970: 0)))
        #expect(page.messages[0].body.isEmpty)
        #expect(page.messages[0].contentWarnings.contains { $0.contains("could not be decoded") })
        #expect(page.messages[1].body.contains("Review by Friday."))
    }
    @Test func explicitThreadSearchLoadsOnlyExactRootMatchesWithoutWrites() async throws {
        let server = IMAPFixtureServer(uids: [1]); let provider = try await fixture(server: server)
        let page = try await provider.fetchPage(MailSyncRequest(since: Date(timeIntervalSince1970: 0)))
        let source = try #require(page.messages.first)
        await server.setUIDs([1, 2, 3]); await server.reference(2, root: "<1@example.test>"); await server.reference(3, root: "<unrelated@example.test>")
        let thread = try await provider.fetchThread(message: source)
        #expect(thread.id == source.threadID)
        #expect(thread.messages.count == 2)
        #expect(thread.messages.allSatisfy { $0.accountID == source.accountID && $0.providerThreadID == source.providerThreadID })
        #expect(!(await server.requestedBodyUIDs).contains(3))
        #expect(await server.commands.contains { $0.contains("HEADER Message-ID") && $0.contains("HEADER References") && $0.contains("HEADER In-Reply-To") })
        var forged = source; forged.providerThreadID = "<id@example.test>\r\nA STORE 1";
        await #expect(throws: MailSyncError.unsupportedContent) { try await provider.fetchThread(message: forged) }
    }
    @Test func conversationDeadlineStopsBetweenPartsAndKeepsCachedSource() async throws {
        let server = IMAPFixtureServer(uids: [1]); let clock = IMAPFixtureClock()
        let provider = try await fixture(server: server, clock: clock)
        let page = try await provider.fetchPage(MailSyncRequest(since: Date(timeIntervalSince1970: 0)))
        let source = try #require(page.messages.first)
        let before = await server.requestedBodySections.count
        await server.useMultipleTextPartsAndAdvanceClock(clock)
        let conversation = try await provider.fetchThread(message: source)
        #expect(await server.requestedBodySections.count == before + 1)
        #expect(conversation.messages.contains { $0.id == source.id && $0.body == source.body })
        #expect(conversation.messages.contains { $0.contentWarnings.contains { $0.contains("retrieval time budget") } })
    }
    @Test func missingCredentialsNeverOpensNetwork() async throws {
        let server = IMAPFixtureServer(uids: [])
        let account = MailAccount(name: "iCloud", address: MailAddress(name: "", email: "reader@icloud.com"), providerType: .iCloud)
        let provider = ICloudMailProvider(account: account, credentials: MemoryCredentialStore(), sessionFactory: server)
        await #expect(throws: MailSyncError.authenticationRequired) { try await provider.fetchAccounts() }
        #expect(await server.commands.isEmpty)
    }
}

private actor IMAPFixtureServer: IMAPSessionFactory, IMAPSession {
    var uids: [UInt32]; var validity: UInt32 = 77; var failedUID: UInt32?; var delayed = false
    var malformedStructureUID: UInt32?; var malformedRecordUID: UInt32?; var corruptBodyUID: UInt32?; var references: [UInt32: String] = [:]
    var requestedBodyUIDs: [UInt32] = []
    var multipleTextParts = false; var clockToAdvance: IMAPFixtureClock?
    var requestedBodySections: [String] = []; var metadataUIDs: [UInt32] = []; var commands: [String] = []; var closes = 0; var bodyStarted = false
    init(uids: [UInt32]) { self.uids = uids }
    func setUIDs(_ value: [UInt32]) { uids = value }; func setValidity(_ value: UInt32) { validity = value }
    func useMultipleTextPartsAndAdvanceClock(_ clock: IMAPFixtureClock) { multipleTextParts = true; clockToAdvance = clock }
    func malformedStructure(_ uid: UInt32) { malformedStructureUID = uid }
    func malformedRecord(_ uid: UInt32) { malformedRecordUID = uid }
    func corruptBody(_ uid: UInt32) { corruptBodyUID = uid }
    func reference(_ uid: UInt32, root: String) { references[uid] = root }
    func failMetadata(_ uid: UInt32) { failedUID = uid }; func delayBodies() { delayed = true }
    func makeSession(configuration: IMAPConfiguration) -> any IMAPSession { self }
    func close() { closes += 1 }
    func execute(_ command: IMAPCommand) async throws -> IMAPResponse {
        if case .login = command { commands.append("LOGIN [fixture]") } else { commands.append(try command.wireText()) }
        switch command {
        case .capability: return IMAPResponse(lines: ["* CAPABILITY IMAP4rev1"])
        case .login, .logout: return IMAPResponse(lines: [])
        case .list: return IMAPResponse(lines: [#"* LIST (\HasNoChildren) "/" "INBOX""#])
        case .examine: return IMAPResponse(lines: ["* OK [UIDVALIDITY \(validity)] Valid", "* OK [UIDNEXT 10] Next"])
        case .search(_, let minimum): return IMAPResponse(lines: ["* SEARCH " + uids.filter { uid in minimum.map { uid >= $0 } ?? true }.map(String.init).joined(separator: " ")])
        case .searchThread: return IMAPResponse(lines: ["* SEARCH " + uids.map(String.init).joined(separator: " ")])
        case .headers(let uid):
            let header = "From: Teacher <teacher@example.test>\r\nSubject: Headers remain readable\r\nMessage-ID: <\(uid)@example.test>\r\n\r\n"
            return IMAPResponse(lines: ["* 1 FETCH (UID \(uid) FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID)]<0> {\(header.utf8.count)}\r\n\(header))\r\n"])
        case .flags(let requested): return IMAPResponse(lines: requested.filter { uids.contains($0) }.map { "* 1 FETCH (UID \($0) FLAGS (\\Seen))" })
        case .metadata(let uid):
            if uid == failedUID { throw IMAPError.malformedResponse }; metadataUIDs.append(uid)
            var header = "From: Teacher <teacher@example.test>\r\nTo: Reader <reader@icloud.com>\r\nSubject: =?UTF-8?B?56CU56m2?= Update\r\nDate: Fri, 11 Sep 2026 09:00:00 +0000\r\nMessage-ID: <\(uid)@example.test>\r\n\r\n"
            if let root = references[uid] { header = "References: \(root)\r\n" + header }
            if uid == malformedRecordUID { return IMAPResponse(lines: ["* 1 FETCH (UID \(uid) BODYSTRUCTURE (broken)"]) }
            let textSize = "Hello=20Flora!=0AReview by Friday.".utf8.count
            var structure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" "# + String(textSize) + #" 2 NIL NIL)("APPLICATION" "PDF" ("NAME" "notes.pdf") NIL NIL "BASE64" 12 NIL ("ATTACHMENT" ("FILENAME" "notes.pdf"))) "MIXED")"#
            if multipleTextParts {
                let plain = "(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" \(textSize) 2 NIL NIL)"
                structure = "(\(plain)\(plain) \"MIXED\")"
            }
            if uid == malformedStructureUID { structure = #"("TEXT" "PLAIN" NIL NIL NIL "7BIT" -1)"# }
            return IMAPResponse(lines: ["* 1 FETCH (UID \(uid) FLAGS (\\Seen \\Flagged) INTERNALDATE \"11-Sep-2026 09:00:00 +0000\" BODYSTRUCTURE \(structure) BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO)] {\(header.utf8.count)}\r\n\(header))\r\n"])
        case .body(let uid, let section, let maximum):
            bodyStarted = true
            if delayed { try await Task.sleep(for: .seconds(30)) }
            requestedBodySections.append(section); requestedBodyUIDs.append(uid)
            if let clockToAdvance { await clockToAdvance.advance(); self.clockToAdvance = nil }
            let content = uid == corruptBodyUID ? "bad=QZ" : (section == "1" ? "Hello=20Flora!=0AReview by Friday." : "JVBERi0xLjQ=")
            let bytes = Data(content.utf8).prefix(maximum)
            var data = Data("* 1 FETCH (UID \(uid) BODY[\(section)]<0> {\(bytes.count)}\r\n".utf8); data.append(bytes); data.append(Data(")\r\n".utf8))
            return IMAPResponse(records: [data])
        }
    }
}

@Suite("Inert MIME projection")
struct MIMEParserTests {
    @Test func htmlStripsExecutableAndRemoteContentWithoutLoading() {
        let html = "<html><head><style>secretCSS</style></head><body><p>Hello &amp; welcome</p><script>alert('leak')</script><img src='https://tracker.test/pixel'><iframe src='https://evil.test'>hidden</iframe><p>Friday &#x2713;</p></body></html>"
        let text = MIMEParser.htmlToText(html)
        #expect(text.contains("Hello & welcome")); #expect(text.contains("Friday ✓"))
        #expect(!text.contains("alert")); #expect(!text.contains("https://")); #expect(!text.contains("hidden")); #expect(!text.contains("secretCSS"))
        #expect(MIMEParser.htmlToText("Text<script>neverclosed") == "Text")
    }
    @Test func decodesCommonEncodingsAndFoldedHeaders() {
        #expect(MIMEParser.decodeHeader("=?UTF-8?B?56CU56m2?=\r\n =?UTF-8?Q?_Update?=") == "研究 Update")
        #expect(MIMEParser.decodeHeader("=?ISO-8859-1?Q?Andr=E9?=") == "André")
        #expect(MIMEParser.decodeText(Data([99, 97, 102, 233]), charset: "iso-8859-1") == "café")
        #expect(String(data: MIMEParser.decodeTransfer(Data("line=20one=\r\ncontinued=0A".utf8), encoding: "quoted-printable"), encoding: .utf8) == "line onecontinued\n")
        #expect(MIMEParser.headers(Data("Subject: Long\r\n\tcontinued\r\n\r\nignored".utf8))["subject"] == "Long continued")
        #expect(MIMEParser.addresses("\"Smith, Jane\" <jane@example.test>, John <john@example.test>").count == 2)
    }
}


@MainActor
private final class IMAPFixtureClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance() { date = date.addingTimeInterval(121) }
}
