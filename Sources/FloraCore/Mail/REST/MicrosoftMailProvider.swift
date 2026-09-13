import Foundation

@MainActor
public final class MicrosoftMailProvider: ReadOnlyMailProvider {
    public let name = "Microsoft · Read only"
    public let accountID: UUID
    private let reference: MailCredentialReference
    private let configuration: OAuthClientConfiguration
    private let reader: AuthorizedMailReader
    private var folderCache: [MailFolderDescriptor] = []
    private var hasDiscoveredFolders = false
    private var threadIDs: [UUID: String] = [:]
    private let immutablePreference = "IdType=\"ImmutableId\""
    private static let messageFields = "id,conversationId,from,toRecipients,ccRecipients,subject,body,receivedDateTime,sentDateTime,parentFolderId,isRead,flag,importance,hasAttachments,isDraft"
    public init(accountID: UUID, credentialReference: MailCredentialReference, configuration: OAuthClientConfiguration,
                credentials: any CredentialStore = KeychainCredentialStore(), http: any MailHTTPClient = SecureMailHTTPClient()) {
        self.accountID = accountID; reference = credentialReference; self.configuration = configuration
        reader = AuthorizedMailReader(tokens: OAuthAccessTokenProvider(configuration: configuration, reference: credentialReference, credentials: credentials, http: http), http: http, host: "graph.microsoft.com")
    }
    private func url(_ path: [String], query: [URLQueryItem] = []) throws -> URL { try MailHTTP.url(host: "graph.microsoft.com", path: ["v1.0", "me"] + path, query: query) }
    private func get(_ url: URL, pageSize: Int? = nil) async throws -> Data {
        guard configuration.provider == .microsoft else { throw RemoteMailError.invalidConfiguration }
        var preference = immutablePreference
        if let pageSize { preference += ", odata.maxpagesize=\(min(max(pageSize, 1), 100))" }
        return try await reader.get(url, headers: ["Prefer": preference])
    }
    /// Continuation URLs are untrusted provider data, restricted to this mailbox's v1 API.
    private func nextURL(_ raw: String, expectedURL: URL? = nil) throws -> URL {
        guard raw.utf8.count < 32_768, let result = URL(string: raw), result.host == "graph.microsoft.com",
              result.path.lowercased().hasPrefix("/v1.0/me/") else { throw RemoteMailError.malformedResponse }
        try SecureMailHTTPClient.validate(result)
        if let expectedURL { try GraphResourcePath.validate(result, matches: expectedURL) }
        return result
    }
    public func fetchAccounts() async throws -> [MailAccount] {
        let profile = try MailHTTP.decode(GraphProfile.self, await get(url([], query: [URLQueryItem(name: "$select", value: "id,displayName,mail,userPrincipalName")])) )
        let email = profile.mail.flatMap { $0.isEmpty ? nil : $0 } ?? profile.userPrincipalName
        guard !profile.id.isEmpty, email.contains("@") else { throw RemoteMailError.malformedResponse }
        return [MailAccount(id: accountID, name: "Microsoft", address: MailAddress(name: profile.displayName ?? email, email: email), provider: "Microsoft", providerType: .microsoft, providerAccountID: profile.id, credentialReference: reference, status: .connected, oauthClientID: configuration.clientID)]
    }
    public func fetchRemoteFolders() async throws -> [MailFolderDescriptor] {
        let known: [(String, MailFolder)] = [("inbox", .inbox), ("sentitems", .sent), ("drafts", .drafts), ("deleteditems", .trash), ("archive", .archive)]
        var roles: [String: MailFolder] = [:], values: [String: GraphFolder] = [:]
        for (wellKnown, role) in known {
            do {
                let folder = try MailHTTP.decode(GraphFolder.self, await get(url(["mailFolders", wellKnown], query: [URLQueryItem(name: "$select", value: "id,displayName,childFolderCount")])) )
                roles[folder.id] = role; values[folder.id] = folder
            } catch RemoteMailError.messageUnavailable { continue }
        }
        var queue = [try url(["mailFolders"], query: [URLQueryItem(name: "$top", value: "100"), URLQueryItem(name: "$select", value: "id,displayName,childFolderCount")])]
        var visited: Set<String> = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            guard visited.count < 100, values.count < 1_000 else { throw RemoteMailError.responseTooLarge }
            let current = queue.removeFirst()
            guard visited.insert(current.absoluteString).inserted else { throw RemoteMailError.malformedResponse }
            let page = try MailHTTP.decode(GraphFolderPage.self, await get(current))
            for folder in page.value {
                let firstSeen = values[folder.id] == nil
                values[folder.id] = folder
                // Well-known folders may also have children; discover them once from root listing.
                if (firstSeen || roles[folder.id] != nil), folder.childFolderCount ?? 0 > 0 {
                    let child = try url(["mailFolders", folder.id, "childFolders"], query: [URLQueryItem(name: "$top", value: "100"), URLQueryItem(name: "$select", value: "id,displayName,childFolderCount")])
                    if !visited.contains(child.absoluteString), !queue.contains(child) { queue.append(child) }
                }
            }
            if let next = page.nextLink { queue.append(try nextURL(next, expectedURL: current)) }
        }
        folderCache = values.values.map { MailFolderDescriptor(id: $0.id, accountID: accountID, name: $0.displayName, role: roles[$0.id]) }.sorted { lhs, rhs in
            if lhs.role == .inbox { return rhs.role != .inbox }; if rhs.role == .inbox { return false }; return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        hasDiscoveredFolders = true
        return folderCache
    }
    public func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        try Task.checkCancellation()
        var state = try GraphSyncState.decode(request.checkpoint?.opaqueState)
        let discovered = hasDiscoveredFolders ? folderCache : try await fetchRemoteFolders()
        try state.reconcileFolders(discovered)
        if state.since == nil { state.since = request.since }
        guard !state.folders.isEmpty, state.index < state.folders.count else {
            state.index = 0
            return MailSyncPage(messages: [], checkpoint: SyncCheckpoint(opaqueState: try state.encoded(), initialComplete: true))
        }
        let folder = state.folders[state.index]
        let initialURL = try url(["mailFolders", folder.id, "messages", "delta"], query: [
            URLQueryItem(name: "$select", value: Self.messageFields), URLQueryItem(name: "$top", value: String(request.limit)),
            URLQueryItem(name: "$filter", value: "receivedDateTime ge \(ISO8601DateFormatter().string(from: state.since ?? request.since))"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc")])
        let current = try state.links[folder.id].map { try nextURL($0, expectedURL: initialURL) } ?? initialURL
        if state.pendingIDs.isEmpty {
            let page: GraphMessagePage
            do { page = try MailHTTP.decode(GraphMessagePage.self, await get(current, pageSize: request.limit)) }
            catch RemoteMailError.staleCheckpoint {
                // Delta retention is finite. Reset only this folder, preserve
                // all other folder cursors and every already cached message.
                guard state.links[folder.id] != nil else { throw RemoteMailError.staleCheckpoint }
                state.links[folder.id] = nil
                page = try MailHTTP.decode(GraphMessagePage.self, await get(initialURL, pageSize: request.limit))
            } catch RemoteMailError.messageUnavailable {
                // A mailbox folder can disappear after discovery. Confirm its
                // absence without treating its formerly cached mail as deleted.
                do {
                    _ = try await get(url(["mailFolders", folder.id], query: [URLQueryItem(name: "$select", value: "id")]))
                    throw RemoteMailError.staleCheckpoint
                } catch RemoteMailError.messageUnavailable {
                    state.removeCurrentFolder()
                    folderCache.removeAll { $0.id == folder.id }
                    let complete = state.index >= state.folders.count
                    if complete { state.index = 0 }
                    return MailSyncPage(messages: [], checkpoint: SyncCheckpoint(opaqueState: try state.encoded(), initialComplete: request.checkpoint?.initialComplete == true || complete), hasMore: !complete)
                }
            }
            guard page.value.count <= 1_000 else { throw RemoteMailError.responseTooLarge }
            state.pendingIDs = Array(Set(page.value.map(\.id))).sorted()
            if let next = page.nextLink {
                state.pendingLink = try nextURL(next, expectedURL: initialURL).absoluteString
                state.pendingCompletesFolder = false
            } else if let delta = page.deltaLink {
                state.pendingLink = try nextURL(delta, expectedURL: initialURL).absoluteString
                state.pendingCompletesFolder = true
            } else { throw RemoteMailError.malformedResponse }
        }
        var messages: [MailMessage] = [], removed: [String] = []
        let selected = Array(state.pendingIDs.prefix(request.limit))
        for id in selected {
            try Task.checkCancellation()
            // Folder removals can mean a move. Resolve immutable IDs against the mailbox
            // before treating anything as a deletion, including out-of-window delta events.
            do { messages.append(try await message(id: id)) }
            catch RemoteMailError.messageUnavailable { removed.append(id) }
        }
        state.pendingIDs.removeFirst(selected.count)
        if state.pendingIDs.isEmpty {
            guard let link = state.pendingLink else { throw RemoteMailError.malformedResponse }
            state.links[folder.id] = link
            if state.pendingCompletesFolder { state.index += 1 }
            state.pendingLink = nil
        }
        let complete = state.index >= state.folders.count
        if complete { state.index = 0 }
        return MailSyncPage(messages: messages, checkpoint: SyncCheckpoint(opaqueState: try state.encoded(), initialComplete: request.checkpoint?.initialComplete == true || complete), hasMore: !complete, deletedProviderMessageIDs: removed)
    }
    private func message(id: String) async throws -> MailMessage {
        let wire = try MailHTTP.decode(GraphMessageDTO.self, await get(url(["messages", id], query: [URLQueryItem(name: "$select", value: Self.messageFields)])))
        let needsMetadata = wire.hasAttachments == true || wire.body?.content.range(of: "cid:", options: .caseInsensitive) != nil
        guard wire.id == id else { throw RemoteMailError.malformedResponse }
        var attachments: [MailAttachment] = [], warnings: [String] = []
        if needsMetadata {
            do { attachments = try await attachmentMetadata(messageID: id) }
            catch where RESTMailContent.isBodyFailure(error) { warnings.append("Attachment metadata could not be decoded. Retry this message to retrieve it again.") }
        }
        let role = folderCache.first(where: { $0.id == wire.parentFolderId })?.role
        var mapped = try MicrosoftMapping.message(wire, accountID: accountID, role: role, attachments: attachments)
        mapped.contentWarnings += warnings
        threadIDs[mapped.threadID] = wire.conversationId
        return mapped
    }
    private func attachmentMetadata(messageID: String) async throws -> [MailAttachment] {
        var current: URL? = try url(["messages", messageID, "attachments"], query: [URLQueryItem(name: "$select", value: "id,name,contentType,size,isInline")])
        var result: [MailAttachment] = [], visited: Set<String> = []
        while let next = current {
            guard visited.count < 10, visited.insert(next.absoluteString).inserted else { throw RemoteMailError.responseTooLarge }
            let page = try MailHTTP.decode(GraphAttachmentPage.self, await get(next))
            result.append(contentsOf: page.value.map { MicrosoftMapping.attachment($0, accountID: accountID, messageID: messageID) })
            current = try page.nextLink.map { try nextURL($0, expectedURL: next) }
        }
        return result
    }
    public func fetchThread(message source: MailMessage) async throws -> MailThread {
        guard source.accountID == accountID, let remote = source.providerThreadID,
              source.threadID == StableMailIdentity.thread(accountID: accountID, providerID: remote) else { throw RemoteMailError.invalidConfiguration }
        let thread = try await fetchThread(providerConversationID: remote)
        guard thread.messages.contains(where: { $0.providerID == source.providerID }) else { throw RemoteMailError.messageUnavailable }
        return thread
    }
    public func fetchThread(id: UUID) async throws -> MailThread {
        guard let remote = threadIDs[id] else { throw RemoteMailError.messageUnavailable }
        return try await fetchThread(providerConversationID: remote)
    }
    public func fetchThread(providerConversationID: String) async throws -> MailThread {
        // A provider reconstructed after restart has no in-memory folder roles.
        // Discover them before normalizing thread messages into the local store.
        if !hasDiscoveredFolders { _ = try await fetchRemoteFolders() }
        let escaped = providerConversationID.replacingOccurrences(of: "'", with: "''")
        var current: URL? = try url(["messages"], query: [URLQueryItem(name: "$filter", value: "conversationId eq '\(escaped)'"), URLQueryItem(name: "$select", value: "id"), URLQueryItem(name: "$top", value: "50")])
        var mapped: [MailMessage] = [], visited: Set<String> = []
        while let next = current {
            try Task.checkCancellation()
            guard visited.count < 10, visited.insert(next.absoluteString).inserted else { throw RemoteMailError.responseTooLarge }
            let page = try MailHTTP.decode(GraphMessagePage.self, await get(next))
            guard mapped.count + page.value.count <= 500 else { throw RemoteMailError.responseTooLarge }
            for item in page.value {
                mapped.append(try await message(id: item.id))
                _ = try RESTMailContent.validateThread(mapped, accountID: accountID, providerThreadID: providerConversationID)
            }
            current = try page.nextLink.map { try nextURL($0, expectedURL: next) }
        }
        return try RESTMailContent.validateThread(mapped, accountID: accountID, providerThreadID: providerConversationID)
    }
    public func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data {
        guard message.accountID == accountID, let id = attachment.providerID, message.attachments.contains(where: { $0.id == attachment.id && $0.providerID == id }) else { throw RemoteMailError.invalidConfiguration }
        guard attachment.size <= 20 * 1024 * 1024 else { throw RemoteMailError.responseTooLarge }
        let bytes = try await get(url(["messages", message.providerID, "attachments", id, "$value"]))
        guard bytes.count <= 20 * 1024 * 1024 else { throw RemoteMailError.responseTooLarge }
        return bytes
    }
}

private struct GraphSyncFolder: Codable { let id: String; let role: MailFolder? }
private struct GraphSyncState: Codable {
    var folders: [GraphSyncFolder] = []
    var links: [String: String] = [:]
    var index = 0
    var pendingIDs: [String] = []
    var pendingLink: String?
    var pendingCompletesFolder = false
    var since: Date?
    mutating func reconcileFolders(_ discovered: [MailFolderDescriptor]) throws {
        guard index >= 0, index <= folders.count else { throw RemoteMailError.staleCheckpoint }
        let available = Dictionary(discovered.map { ($0.id, $0.role) }, uniquingKeysWith: { first, _ in first })
        let currentID = folders.indices.contains(index) ? folders[index].id : nil
        let previousIDs = Set(folders.map(\.id))
        let processed = folders.prefix(index).filter { available.keys.contains($0.id) }
        let remaining = folders.dropFirst(index).filter { available.keys.contains($0.id) }
        folders = (Array(processed) + Array(remaining)).map { GraphSyncFolder(id: $0.id, role: available[$0.id] ?? nil) }
        folders.append(contentsOf: discovered.filter { !previousIDs.contains($0.id) }.map { GraphSyncFolder(id: $0.id, role: $0.role) })
        index = processed.count
        links = links.filter { available.keys.contains($0.key) }
        if let currentID, !available.keys.contains(currentID) { pendingIDs = []; pendingLink = nil; pendingCompletesFolder = false }
    }
    mutating func removeCurrentFolder() {
        let folder = folders.remove(at: index)
        links[folder.id] = nil; pendingIDs = []; pendingLink = nil; pendingCompletesFolder = false
    }
    static func decode(_ raw: String?) throws -> Self {
        guard let raw else { return Self() }
        guard raw.utf8.count < 4_194_304, let result = try? JSONDecoder().decode(Self.self, from: Data(raw.utf8)) else { throw RemoteMailError.staleCheckpoint }
        return result
    }
    func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
struct GraphProfile: Decodable { let id: String; let displayName: String?; let mail: String?; let userPrincipalName: String }
struct GraphFolder: Decodable { let id: String; let displayName: String; let childFolderCount: Int? }
struct GraphFolderPage: Decodable {
    let value: [GraphFolder]; let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}
struct GraphEmailAddress: Decodable { let name: String?; let address: String? }
struct GraphRecipient: Decodable { let emailAddress: GraphEmailAddress }
struct GraphBody: Decodable { let contentType: String; let content: String }
struct GraphFlag: Decodable { let flagStatus: String? }
struct GraphMessageDTO: Decodable {
    let id: String
    let conversationId: String?
    let from: GraphRecipient?
    let toRecipients: [GraphRecipient]?
    let ccRecipients: [GraphRecipient]?
    let subject: String?
    let body: GraphBody?
    let receivedDateTime: String?
    let sentDateTime: String?
    let parentFolderId: String?
    let isRead: Bool?
    let flag: GraphFlag?
    let importance: String?
    let hasAttachments: Bool?
    let isDraft: Bool?
    private enum CodingKeys: String, CodingKey { case id, conversationId, from, toRecipients, ccRecipients, subject, body, receivedDateTime, sentDateTime, parentFolderId, isRead, flag, importance, hasAttachments, isDraft }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        conversationId = try values.decodeIfPresent(String.self, forKey: .conversationId)
        from = try values.decodeIfPresent(GraphRecipient.self, forKey: .from)
        toRecipients = try values.decodeIfPresent([GraphRecipient].self, forKey: .toRecipients)
        ccRecipients = try values.decodeIfPresent([GraphRecipient].self, forKey: .ccRecipients)
        subject = try values.decodeIfPresent(String.self, forKey: .subject)
        body = try? values.decodeIfPresent(GraphBody.self, forKey: .body)
        receivedDateTime = try values.decodeIfPresent(String.self, forKey: .receivedDateTime)
        sentDateTime = try values.decodeIfPresent(String.self, forKey: .sentDateTime)
        parentFolderId = try values.decodeIfPresent(String.self, forKey: .parentFolderId)
        isRead = try values.decodeIfPresent(Bool.self, forKey: .isRead)
        flag = try values.decodeIfPresent(GraphFlag.self, forKey: .flag)
        importance = try values.decodeIfPresent(String.self, forKey: .importance)
        hasAttachments = try values.decodeIfPresent(Bool.self, forKey: .hasAttachments)
        isDraft = try values.decodeIfPresent(Bool.self, forKey: .isDraft)
    }
}
struct GraphMessageReference: Decodable { let id: String }
struct GraphMessagePage: Decodable {
    let value: [GraphMessageReference]; let nextLink: String?; let deltaLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink"; case deltaLink = "@odata.deltaLink" }
}
struct GraphAttachment: Decodable { let id: String; let name: String?; let contentType: String?; let size: Int?; let isInline: Bool? }
struct GraphAttachmentPage: Decodable {
    let value: [GraphAttachment]; let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}

enum MicrosoftMapping {
    static func address(_ value: GraphRecipient) -> MailAddress {
        MailAddress(name: value.emailAddress.name ?? value.emailAddress.address ?? "Unknown sender", email: value.emailAddress.address ?? "")
    }
    static func message(_ wire: GraphMessageDTO, accountID: UUID, role: MailFolder?, attachments: [MailAttachment] = []) throws -> MailMessage {
        guard !wire.id.isEmpty else { throw RemoteMailError.malformedResponse }
        let body = wire.body ?? GraphBody(contentType: "unavailable", content: "")
        let thread = wire.conversationId ?? wire.id
        let isHTML = body.contentType.lowercased() == "html"
        let supported = isHTML || body.contentType.lowercased() == "text"
        var warnings: [String] = supported ? [] : [RESTMailContent.unavailableWarning]
        let limited = supported ? RESTMailContent.limitText(body.content, warnings: &warnings) : ""
        let formatter = ISO8601DateFormatter()
        var date: Date?
        if let stamp = wire.receivedDateTime ?? wire.sentDateTime {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; date = formatter.date(from: stamp)
            if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: stamp) }
        }
        return MailMessage(id: StableMailIdentity.message(accountID: accountID, providerID: wire.id), providerID: wire.id, accountID: accountID,
                           threadID: StableMailIdentity.thread(accountID: accountID, providerID: thread),
                           from: wire.from.map(address) ?? MailAddress(name: "Unknown sender", email: ""), to: (wire.toRecipients ?? []).map(address),
                           subject: wire.subject ?? "(No subject)", body: isHTML ? MIMEParser.htmlToText(limited) : limited,
                           date: date ?? Date(timeIntervalSince1970: 0), folder: wire.isDraft == true ? .drafts : role ?? .archive,
                           isRead: wire.isRead ?? false, isFlagged: wire.flag?.flagStatus == "flagged", attachments: attachments,
                           providerThreadID: thread, providerFolderIDs: wire.parentFolderId.map { [$0] } ?? [], htmlBody: isHTML ? limited : nil,
                           cc: (wire.ccRecipients ?? []).map(address), isImportant: wire.importance == "high", contentWarnings: warnings)
    }
    static func attachment(_ wire: GraphAttachment, accountID: UUID, messageID: String) -> MailAttachment {
        MailAttachment(id: StableMailIdentity.message(accountID: accountID, providerID: "attachment:\(messageID):\(wire.id)"),
                       name: wire.name ?? "Unnamed attachment", size: max(0, wire.size ?? 0), providerID: wire.id,
                       mimeType: wire.contentType ?? "application/octet-stream", isInline: wire.isInline ?? false)
    }
}
