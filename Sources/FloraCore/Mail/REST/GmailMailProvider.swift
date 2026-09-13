import Foundation

/// Gmail labels remain many-to-many provider IDs; the folder role is a GUI projection.
@MainActor
public final class GmailMailProvider: ReadOnlyMailProvider {
    public let name = "Gmail · Read only"
    public let accountID: UUID
    let reference: MailCredentialReference
    let configuration: OAuthClientConfiguration
    private let reader: AuthorizedMailReader
    let writer: AuthorizedMailWriteTransport
    private var threadIDs: [UUID: String] = [:]
    public init(accountID: UUID, credentialReference: MailCredentialReference, configuration: OAuthClientConfiguration,
                credentials: any CredentialStore = KeychainCredentialStore(), http: any MailHTTPClient = SecureMailHTTPClient()) {
        self.accountID = accountID; reference = credentialReference; self.configuration = configuration
        let tokens = OAuthAccessTokenProvider(configuration: configuration, reference: credentialReference, credentials: credentials, http: http)
        writer = AuthorizedMailWriteTransport(configuration: configuration, tokens: tokens, http: http)
        reader = AuthorizedMailReader(tokens: tokens, http: http, host: "gmail.googleapis.com")
    }
    private func get(_ path: [String], query: [URLQueryItem] = []) async throws -> Data {
        guard configuration.provider == .gmail else { throw RemoteMailError.invalidConfiguration }
        return try await reader.get(MailHTTP.url(host: "gmail.googleapis.com", path: ["gmail", "v1", "users", "me"] + path, query: query))
    }
    func readForWrite(_ path: [String], query: [URLQueryItem] = []) async throws -> Data { try await get(path, query: query) }
    public func fetchAccounts() async throws -> [MailAccount] {
        let profile = try MailHTTP.decode(GmailProfile.self, await get(["profile"]))
        guard profile.emailAddress.contains("@") else { throw RemoteMailError.malformedResponse }
        return [MailAccount(id: accountID, name: "Gmail", address: MailAddress(name: profile.emailAddress, email: profile.emailAddress), provider: "Gmail", providerType: .gmail, providerAccountID: profile.emailAddress.lowercased(), credentialReference: reference, status: .connected, oauthClientID: configuration.clientID, oauthAccessLevel: configuration.accessLevel)]
    }
    public func fetchRemoteFolders() async throws -> [MailFolderDescriptor] {
        let labels = try MailHTTP.decode(GmailLabels.self, await get(["labels"]))
        return labels.labels.map { MailFolderDescriptor(id: $0.id, accountID: accountID, name: $0.name, role: GmailMapping.role(labels: [$0.id], fallback: nil), isLabel: true) }
    }
    public func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        try Task.checkCancellation()
        var state = try GmailSyncState.decode(request.checkpoint?.opaqueState)
        if request.checkpoint?.initialComplete != true {
            if state.since == nil { state.since = request.since }
            if state.historyID == nil {
                state.historyID = try MailHTTP.decode(GmailProfile.self, await get(["profile"])).historyId
            }
            var query = [URLQueryItem(name: "maxResults", value: String(request.limit)), URLQueryItem(name: "q", value: "after:\(Int((state.since ?? request.since).timeIntervalSince1970))"), URLQueryItem(name: "includeSpamTrash", value: "true")]
            if let token = request.checkpoint?.continuationToken { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try MailHTTP.decode(GmailMessageList.self, await get(["messages"], query: query))
            var messages: [MailMessage] = []
            for item in page.messages ?? [] {
                try Task.checkCancellation()
                do { messages.append(try await message(id: item.id)) }
                catch RemoteMailError.messageUnavailable { continue } // Deleted between listing and retrieval.
            }
            let checkpoint = SyncCheckpoint(opaqueState: try state.encoded(), continuationToken: page.nextPageToken, initialComplete: page.nextPageToken == nil)
            return MailSyncPage(messages: messages, checkpoint: checkpoint, hasMore: page.nextPageToken != nil)
        }
        guard let history = state.historyID else { throw RemoteMailError.staleCheckpoint }
        if state.pendingIDs.isEmpty {
            var query = [URLQueryItem(name: "startHistoryId", value: history), URLQueryItem(name: "maxResults", value: String(request.limit))]
            if let token = state.historyPageToken { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let data: Data
            do { data = try await get(["history"], query: query) }
            catch RemoteMailError.messageUnavailable { throw RemoteMailError.staleCheckpoint }
            let page = try MailHTTP.decode(GmailHistoryPage.self, data)
            var changed: Set<String> = []
            for record in page.history ?? [] {
                changed.formUnion((record.messages ?? []).map(\.id))
                changed.formUnion((record.messagesAdded ?? []).map(\.message.id))
                changed.formUnion((record.labelsAdded ?? []).map(\.message.id))
                changed.formUnion((record.labelsRemoved ?? []).map(\.message.id))
                changed.formUnion((record.messagesDeleted ?? []).map(\.message.id))
            }
            state.pendingIDs = changed.sorted()
            state.historyPageToken = page.nextPageToken
            state.nextHistoryID = page.historyId
        }
        let selected = Array(state.pendingIDs.prefix(request.limit))
        var messages: [MailMessage] = [], removed: [String] = []
        for id in selected {
            try Task.checkCancellation()
            do { messages.append(try await message(id: id)) }
            catch RemoteMailError.messageUnavailable { removed.append(id) }
        }
        state.pendingIDs.removeFirst(selected.count)
        let hasMore = !state.pendingIDs.isEmpty || state.historyPageToken != nil
        if !hasMore { state.historyID = state.nextHistoryID ?? state.historyID; state.nextHistoryID = nil }
        return MailSyncPage(messages: messages, checkpoint: SyncCheckpoint(opaqueState: try state.encoded(), initialComplete: true), hasMore: hasMore, deletedProviderMessageIDs: removed)
    }
    private func message(id: String) async throws -> MailMessage {
        let wire = try MailHTTP.decode(GmailMessageDTO.self, await get(["messages", id], query: [URLQueryItem(name: "format", value: "full")]))
        guard wire.id == id else { throw RemoteMailError.malformedResponse }
        return try await normalizedMessage(wire)
    }
    private func normalizedMessage(_ original: GmailMessageDTO) async throws -> MailMessage {
        var wire = original
        var warnings: [String] = []
        if let payload = wire.payload {
            do { wire.payload = try await hydrateText(payload, messageID: wire.id, depth: 0) }
            catch where RESTMailContent.isBodyFailure(error) {
                wire.payload = nil
                warnings.append(RESTMailContent.unavailableWarning)
            }
        }
        var mapped: MailMessage
        do { mapped = try GmailMapping.message(wire, accountID: accountID) }
        catch where RESTMailContent.isBodyFailure(error) {
            wire.payload = nil
            mapped = try GmailMapping.message(wire, accountID: accountID)
        }
        mapped.contentWarnings = Array(Set(mapped.contentWarnings + warnings)).sorted()
        threadIDs[mapped.threadID] = wire.threadId
        return mapped
    }
    private func hydrateText(_ part: GmailPart, messageID: String, depth: Int) async throws -> GmailPart {
        guard depth < 24 else { throw RemoteMailError.unsupportedContent }
        var result = part
        let disposition = part.headerMap["content-disposition"] ?? ""
        guard (part.filename ?? "").isEmpty, !disposition.lowercased().hasPrefix("attachment") else { return result }
        if ["text/plain", "text/html"].contains(part.mimeType?.lowercased() ?? ""),
           let attachment = part.body?.attachmentId, part.body?.data == nil {
            guard (part.body?.size ?? 0) <= MIMEParser.maximumTextBytes else { return result }
            let body = try MailHTTP.decode(GmailBody.self, await get(["messages", messageID, "attachments", attachment]))
            result.body = body
        }
        if let parts = part.parts {
            result.parts = []
            for child in parts { result.parts?.append(try await hydrateText(child, messageID: messageID, depth: depth + 1)) }
        }
        return result
    }
    public func fetchThread(message source: MailMessage) async throws -> MailThread {
        guard source.accountID == accountID, let remote = source.providerThreadID,
              source.threadID == StableMailIdentity.thread(accountID: accountID, providerID: remote) else { throw RemoteMailError.invalidConfiguration }
        let thread = try await fetchThread(providerThreadID: remote)
        guard thread.messages.contains(where: { $0.providerID == source.providerID }) else { throw RemoteMailError.messageUnavailable }
        return thread
    }
    public func fetchThread(id: UUID) async throws -> MailThread {
        guard let remote = threadIDs[id] else { throw RemoteMailError.messageUnavailable }
        return try await fetchThread(providerThreadID: remote)
    }
    public func fetchThread(providerThreadID: String) async throws -> MailThread {
        let thread = try MailHTTP.decode(GmailThreadDTO.self, await get(["threads", providerThreadID], query: [URLQueryItem(name: "format", value: "full")]))
        guard (thread.messages?.count ?? 0) <= 500 else { throw RemoteMailError.responseTooLarge }
        var mapped: [MailMessage] = []
        for wire in thread.messages ?? [] {
            try Task.checkCancellation()
            guard wire.threadId == providerThreadID else { throw RemoteMailError.malformedResponse }
            mapped.append(try await normalizedMessage(wire))
            _ = try RESTMailContent.validateThread(mapped, accountID: accountID, providerThreadID: providerThreadID)
        }
        return try RESTMailContent.validateThread(mapped, accountID: accountID, providerThreadID: providerThreadID)
    }
    public func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data {
        guard message.accountID == accountID, let id = attachment.providerID, message.attachments.contains(where: { $0.id == attachment.id && $0.providerID == id }) else { throw RemoteMailError.invalidConfiguration }
        guard attachment.size <= 20 * 1024 * 1024 else { throw RemoteMailError.responseTooLarge }
        let encoded: String?
        if id.hasPrefix("inline-part:") {
            let wire = try MailHTTP.decode(GmailMessageDTO.self, await get(["messages", message.providerID], query: [URLQueryItem(name: "format", value: "full")]))
            encoded = wire.payload?.find(partID: String(id.dropFirst("inline-part:".count)))?.body?.data
        } else {
            encoded = try MailHTTP.decode(GmailBody.self, await get(["messages", message.providerID, "attachments", id])).data
        }
        guard let encoded, let bytes = MIMEParser.base64URLDecode(encoded), bytes.count <= 20 * 1024 * 1024 else { throw RemoteMailError.unsupportedContent }
        return bytes
    }
}

private struct GmailSyncState: Codable {
    var historyID: String?
    var since: Date?
    var historyPageToken: String?
    var nextHistoryID: String?
    var pendingIDs: [String] = []
    static func decode(_ raw: String?) throws -> Self {
        guard let raw else { return Self() }
        guard raw.utf8.count < 1_048_576, let result = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)) else { throw RemoteMailError.staleCheckpoint }
        return result
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
struct GmailProfile: Decodable { let emailAddress: String; let historyId: String }
struct GmailLabel: Decodable { let id: String; let name: String }
struct GmailLabels: Decodable { let labels: [GmailLabel] }
struct GmailMessageReference: Decodable { let id: String }
struct GmailMessageList: Decodable { let messages: [GmailMessageReference]?; let nextPageToken: String? }
struct GmailChange: Decodable { let message: GmailMessageReference }
struct GmailHistory: Decodable {
    let messages: [GmailMessageReference]?
    let messagesAdded: [GmailChange]?
    let messagesDeleted: [GmailChange]?
    let labelsAdded: [GmailChange]?
    let labelsRemoved: [GmailChange]?
}
struct GmailHistoryPage: Decodable { let history: [GmailHistory]?; let nextPageToken: String?; let historyId: String }
struct GmailHeader: Decodable { let name: String; let value: String }
struct GmailBody: Decodable { let attachmentId: String?; let size: Int?; let data: String? }
struct GmailPart: Decodable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    var body: GmailBody?
    var parts: [GmailPart]?
    func find(partID: String, depth: Int = 0) -> GmailPart? {
        guard depth < 24 else { return nil }
        if partId == partID { return self }
        return parts?.compactMap { $0.find(partID: partID, depth: depth + 1) }.first
    }
    var headerMap: [String: String] {
        (headers ?? []).reduce(into: [:]) { result, header in
            let key = header.name.lowercased()
            if result[key] == nil { result[key] = MIMEParser.decodeHeader(header.value) }
        }
    }
}
struct GmailMessageDTO: Decodable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let internalDate: String?
    let snippet: String?
    var payload: GmailPart?
    let envelopeHeaders: [GmailHeader]
    private enum CodingKeys: String, CodingKey { case id, threadId, labelIds, internalDate, snippet, payload }
    private struct PayloadEnvelope: Decodable { let headers: [GmailHeader]? }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); threadId = try values.decode(String.self, forKey: .threadId)
        labelIds = try values.decodeIfPresent([String].self, forKey: .labelIds)
        internalDate = try values.decodeIfPresent(String.self, forKey: .internalDate)
        snippet = try values.decodeIfPresent(String.self, forKey: .snippet)
        envelopeHeaders = (try? values.decodeIfPresent(PayloadEnvelope.self, forKey: .payload))?.headers ?? []
        payload = try? values.decodeIfPresent(GmailPart.self, forKey: .payload)
    }
}
struct GmailThreadDTO: Decodable { let messages: [GmailMessageDTO]? }

enum GmailMapping {
    static func role(labels: [String], fallback: MailFolder? = .archive) -> MailFolder? {
        if labels.contains("TRASH") { return .trash }
        if labels.contains("DRAFT") { return .drafts }
        if labels.contains("INBOX") { return .inbox }
        if labels.contains("SENT") { return .sent }
        return fallback
    }
    static func message(_ wire: GmailMessageDTO, accountID: UUID) throws -> MailMessage {
        guard !wire.id.isEmpty, !wire.threadId.isEmpty else { throw RemoteMailError.malformedResponse }
        let payload = wire.payload ?? GmailPart(partId: nil, mimeType: "text/plain", filename: nil, headers: wire.envelopeHeaders, body: nil, parts: nil)
        let headers = payload.headerMap
        var warnings: [String] = wire.payload == nil ? [RESTMailContent.unavailableWarning] : []
        var plain: [String] = [], html: [String] = [], attachments: [MailAttachment] = []
        func walk(_ part: GmailPart, depth: Int) throws {
            guard depth < 24, attachments.count < 200 else { throw RemoteMailError.unsupportedContent }
            let mime = part.mimeType?.lowercased() ?? "application/octet-stream"
            let header = part.headerMap
            let disposition = header["content-disposition"] ?? ""
            let typeParameters = MIMEParser.headerParameters(header["content-type"] ?? "")
            let dispositionParameters = MIMEParser.headerParameters(disposition)
            let filename = MIMEParser.decodeHeader(part.filename.flatMap { $0.isEmpty ? nil : $0 } ?? dispositionParameters["filename"] ?? typeParameters["name"] ?? "")
            let isAttachment = !filename.isEmpty || header["content-disposition"]?.lowercased().hasPrefix("attachment") == true
            if isAttachment || (!mime.hasPrefix("multipart/") && mime != "text/plain" && mime != "text/html") {
                let remote = part.body?.attachmentId ?? part.partId.map { "inline-part:\($0)" }
                if let remote {
                    attachments.append(MailAttachment(id: StableMailIdentity.message(accountID: accountID, providerID: "attachment:\(wire.id):\(remote)"), name: filename.isEmpty ? "Unnamed attachment" : filename, size: max(0, part.body?.size ?? 0), providerID: remote, mimeType: mime, isInline: header["content-disposition"]?.lowercased().hasPrefix("inline") == true, contentID: MIMEParser.normalizedContentID(header["content-id"])))
                }
                // Attached MIME trees are not part of the original visible body.
                // Keep only metadata until the user requests their contents.
                return
            } else if let encoded = part.body?.data {
                guard let bytes = MIMEParser.base64URLDecode(encoded) else { throw RemoteMailError.unsupportedContent }
                let charset = header["content-type"].map(MIMEParser.headerParameters)?["charset"]
                if bytes.count > MIMEParser.maximumTextBytes { warnings.append("A text part exceeded the 512 KiB preview limit; its remaining content was not included.") }
                let text = MIMEParser.decodeText(bytes, charset: charset)
                if mime == "text/plain" { plain.append(text) }
                if mime == "text/html" { html.append(text) }
            } else if part.body?.attachmentId != nil, mime == "text/plain" || mime == "text/html" {
                warnings.append("A text part was not downloaded because it exceeded the 512 KiB preview limit.")
            }
            for child in part.parts ?? [] { try walk(child, depth: depth + 1) }
        }
        try walk(payload, depth: 0)
        let originalHTML = html.isEmpty ? nil : RESTMailContent.limitText(html.joined(separator: "\n"), warnings: &warnings)
        let body = plain.isEmpty ? originalHTML.map(MIMEParser.htmlToText) ?? "" : RESTMailContent.limitText(plain.joined(separator: "\n"), warnings: &warnings)
        if plain.isEmpty && originalHTML == nil && warnings.isEmpty { warnings.append("This message has no supported text body. Its available attachments are listed separately.") }
        let labels = wire.labelIds ?? []
        return MailMessage(id: StableMailIdentity.message(accountID: accountID, providerID: wire.id), providerID: wire.id, accountID: accountID,
                           threadID: StableMailIdentity.thread(accountID: accountID, providerID: wire.threadId),
                           from: MIMEParser.addresses(headers["from"] ?? "").first ?? MailAddress(name: "Unknown sender", email: ""),
                           to: MIMEParser.addresses(headers["to"] ?? ""), subject: headers["subject"] ?? "(No subject)", body: body,
                           date: wire.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? MIMEParser.date(headers["date"]) ?? Date(timeIntervalSince1970: 0),
                           folder: role(labels: labels) ?? .archive, isRead: !labels.contains("UNREAD"), isFlagged: labels.contains("STARRED"), attachments: attachments,
                           providerThreadID: wire.threadId, providerFolderIDs: labels, htmlBody: originalHTML, cc: MIMEParser.addresses(headers["cc"] ?? ""), isImportant: labels.contains("IMPORTANT"), contentWarnings: warnings, replyTo: MIMEParser.addresses(headers["reply-to"] ?? ""), internetMessageID: headers["message-id"], references: RESTMailContent.messageReferences(headers["references"]))
    }
}
