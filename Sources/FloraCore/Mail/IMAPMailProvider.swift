import Foundation

/// iCloud read-only adapter. Each bounded page owns a TLS session; no session or
/// runtime objects escape to views. The local sync coordinator owns persistence.
@MainActor
public final class ICloudMailProvider: ReadOnlyMailProvider {
    public let name = "iCloud Mail · Read only"
    public var accountID: UUID { account.id }
    private let account: MailAccount
    private let credentials: any CredentialStore
    private let sessionFactory: any IMAPSessionFactory
    private let configuration: IMAPConfiguration
    public init(account: MailAccount, credentials: any CredentialStore = KeychainCredentialStore(), sessionFactory: any IMAPSessionFactory = NetworkIMAPSessionFactory(), configuration: IMAPConfiguration = .iCloud) {
        self.account = account; self.credentials = credentials; self.sessionFactory = sessionFactory; self.configuration = configuration
    }
    public func fetchAccounts() async throws -> [MailAccount] {
        let session = try await authenticatedSession(); await session.close(); return [account]
    }
    public func fetchRemoteFolders() async throws -> [MailFolderDescriptor] {
        let session = try await authenticatedSession()
        do { let result = try IMAPMapping.folders(await session.execute(.list), accountID: accountID); await session.close(); return result }
        catch { await session.close(); throw error }
    }
    public func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        try Task.checkCancellation()
        var state: IMAPCheckpoint = try Self.decode(request.checkpoint?.opaqueState) ?? IMAPCheckpoint(accountID: accountID)
        guard state.accountID == accountID else { throw MailSyncError.invalidCheckpoint }
        let session = try await authenticatedSession()
        do {
            let folders = try IMAPMapping.folders(await session.execute(.list), accountID: accountID)
            var cursor: IMAPCursor
            if let pending: IMAPCursor = try Self.decode(request.checkpoint?.continuationToken) {
                guard pending.accountID == accountID, pending.folderIndex >= 0, pending.folderIndex <= pending.folders.count, pending.uids.count <= 100_000 else { throw MailSyncError.invalidCheckpoint }
                cursor = pending
            } else { cursor = IMAPCursor(accountID: accountID, folders: folders.map(\.id), since: request.since) }
            var messages: [MailMessage] = []
            var updates: [MailRemoteStateUpdate] = []; var deleted: [String] = []
            // At most one folder is processed in a page, including empty folders.
            // This bounds a request even for accounts with many custom folders.
            if cursor.folderIndex < cursor.folders.count {
                let wireName = cursor.folders[cursor.folderIndex]
                guard let folder = folders.first(where: { $0.id == wireName }) else {
                    cursor.folderIndex += 1; cursor.uids = []; cursor.validity = nil
                    await session.close(); return try page(messages: [], state: state, cursor: cursor)
                }
                let validity = try IMAPMapping.validity(await session.execute(.examine(wireName)))
                if cursor.validity != validity || !cursor.loaded {
                    if var known = state.mailboxes[wireName], known.validity == validity, !known.knownUIDs.isEmpty {
                        let currentFlags = try IMAPMapping.flagStates(await session.execute(.flags(uids: known.knownUIDs)))
                        for uid in known.knownUIDs {
                            let providerID = try Self.encode(IMAPMessageReference(folder: wireName, validity: validity, uid: uid))
                            if let flags = currentFlags[uid] { updates.append(MailRemoteStateUpdate(providerID: providerID, isRead: flags.contains("\\seen"), isFlagged: flags.contains("\\flagged"))) }
                            else { deleted.append(providerID) }
                        }
                        known.knownUIDs.removeAll { currentFlags[$0] == nil }; state.mailboxes[wireName] = known
                    }
                    let previous = state.mailboxes[wireName]
                    let minimum: UInt32? = previous?.validity == validity ? previous.flatMap { $0.highestUID < UInt32.max ? $0.highestUID + 1 : nil } : nil
                    // A new UIDVALIDITY namespaces IDs anew. Old cached mail remains
                    // available until a future explicit retention/reconciliation policy.
                    let response = try await session.execute(.search(since: cursor.since, minimumUID: minimum))
                    cursor.uids = try IMAPMapping.search(response).filter { uid in minimum.map { uid >= $0 } ?? true }.reversed()
                    cursor.validity = validity; cursor.loaded = true
                }
                let selected = Array(cursor.uids.prefix(request.limit))
                for uid in selected {
                    try Task.checkCancellation()
                    let metadata = try IMAPMapping.metadata(await session.execute(.metadata(uid: uid)), uid: uid)
                    messages.append(try await message(metadata, folder: folder, validity: validity, session: session))
                }
                if let highest = selected.max() {
                    let previous = state.mailboxes[wireName]
                    let priorUIDs = previous?.validity == validity ? previous?.knownUIDs ?? [] : []
                    let knownUIDs = Array(Set(priorUIDs + selected).sorted(by: >).prefix(500))
                    state.mailboxes[wireName] = IMAPMailboxCheckpoint(validity: validity, highestUID: previous?.validity == validity ? max(previous?.highestUID ?? 0, highest) : highest, knownUIDs: knownUIDs)
                } else if state.mailboxes[wireName]?.validity != validity { state.mailboxes[wireName] = IMAPMailboxCheckpoint(validity: validity, highestUID: 0) }
                cursor.uids.removeFirst(selected.count)
                if cursor.uids.isEmpty { cursor.folderIndex += 1; cursor.validity = nil; cursor.loaded = false }
            }
            try Task.checkCancellation(); await session.close()
            return try page(messages: messages, state: state, cursor: cursor, updates: updates, deleted: deleted)
        } catch { await session.close(); throw error }
    }
    public func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data {
        guard message.accountID == accountID, message.attachments.contains(where: { $0.id == attachment.id && $0.providerID == attachment.providerID }),
              let partID = attachment.providerID, let reference: IMAPAttachmentReference = try Self.decode(partID), let folder = message.providerFolderIDs.first,
              reference.accountID == accountID, reference.messageID == message.providerID,
              let source: IMAPMessageReference = try Self.decode(message.providerID), source.folder == folder,
              source.uid == reference.uid, source.validity == reference.validity,
              reference.encodedSize >= 0, reference.encodedSize < 25 * 1_024 * 1_024 else { throw MailSyncError.accountMismatch }
        let session = try await authenticatedSession()
        do {
            let validity = try IMAPMapping.validity(await session.execute(.examine(folder)))
            guard validity == reference.validity else { throw IMAPError.mailboxChanged }
            let response = try await session.execute(.body(uid: reference.uid, section: reference.section, maximumBytes: max(reference.encodedSize + 1, 1)))
            let data = try IMAPMapping.body(response, uid: reference.uid, section: reference.section)
            guard data.count == reference.encodedSize else { throw IMAPError.malformedResponse }
            let decoded = MIMEParser.decodeTransfer(data, encoding: reference.encoding)
            try Task.checkCancellation(); await session.close(); return decoded
        } catch { await session.close(); throw error }
    }
    private func authenticatedSession() async throws -> any IMAPSession {
        guard account.providerType == .iCloud, let reference = account.credentialReference,
              let bytes = try await credentials.read(reference: reference), let decoded = try? JSONDecoder().decode(IMAPCredential.self, from: bytes) else { throw MailSyncError.authenticationRequired }
        let credential = try decoded.validated()
        let session = try await sessionFactory.makeSession(configuration: configuration)
        do {
            _ = try await session.execute(.capability)
            _ = try await session.execute(.login(credential))
            return session
        } catch { await session.close(); throw error }
    }
    private func page(messages: [MailMessage], state: IMAPCheckpoint, cursor: IMAPCursor, updates: [MailRemoteStateUpdate] = [], deleted: [String] = []) throws -> MailSyncPage {
        let hasMore = cursor.folderIndex < cursor.folders.count
        return MailSyncPage(messages: messages, checkpoint: SyncCheckpoint(opaqueState: try Self.encode(state), continuationToken: hasMore ? try Self.encode(cursor) : nil, initialComplete: !hasMore), hasMore: hasMore, deletedProviderMessageIDs: deleted, messageStateUpdates: updates)
    }
    private func message(_ metadata: IMAPMessageMetadata, folder: MailFolderDescriptor, validity: UInt32, session: any IMAPSession) async throws -> MailMessage {
        let providerID = try Self.encode(IMAPMessageReference(folder: folder.id, validity: validity, uid: metadata.uid))
        let textParts = metadata.parts.filter { !$0.isAttachment && ["text/plain", "text/html"].contains($0.mimeType) }
        let preferred = textParts.contains(where: { $0.mimeType == "text/plain" }) ? textParts.filter { $0.mimeType == "text/plain" } : textParts
        var bodyParts: [String] = []; var htmlParts: [String] = []; var remaining = MIMEParser.maximumTextBytes
        for part in preferred.prefix(20) where remaining > 0 {
            let length = min(part.size, remaining)
            if length == 0 { continue }
            let response = try await session.execute(.body(uid: metadata.uid, section: part.section, maximumBytes: length))
            let encoded = try IMAPMapping.body(response, uid: metadata.uid, section: part.section)
            let text = MIMEParser.decodeText(MIMEParser.decodeTransfer(encoded, encoding: part.encoding), charset: part.charset)
            bodyParts.append(part.mimeType == "text/html" ? MIMEParser.htmlToText(text) : text)
            if part.mimeType == "text/html" { htmlParts.append(text) }
            remaining -= encoded.count
            if part.size > length { bodyParts.append("[Message preview truncated at Flora's local size limit.]") }
        }
        let attachments = try metadata.parts.filter(\.isAttachment).map { part in
            let reference = IMAPAttachmentReference(accountID: accountID, messageID: providerID, validity: validity, uid: metadata.uid, section: part.section, encoding: part.encoding, encodedSize: part.size)
            return MailAttachment(id: StableMailIdentity.attachment(accountID: accountID, providerID: providerID + ":" + part.section), name: part.name ?? "Attachment \(part.section)", size: part.encoding == "base64" ? part.size * 3 / 4 : part.size, providerID: try Self.encode(reference), mimeType: part.mimeType, isInline: part.isInline, contentID: part.contentID)
        }
        let headers = metadata.headers
        let threadReference = headers["references"]?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? headers["in-reply-to"] ?? headers["message-id"] ?? providerID
        let rendered = bodyParts.joined(separator: "\n\n")
        let body = rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No supported text preview. This message may contain only attachments." : rendered
        return MailMessage(id: StableMailIdentity.message(accountID: accountID, providerID: providerID), providerID: providerID, accountID: accountID,
                           threadID: StableMailIdentity.thread(accountID: accountID, providerID: threadReference), from: MIMEParser.addresses(headers["from"] ?? "").first ?? MailAddress(name: "Unknown sender", email: ""),
                           to: MIMEParser.addresses(headers["to"] ?? ""), subject: headers["subject"] ?? "(No subject)", body: body, date: MIMEParser.date(headers["date"]) ?? metadata.date ?? Date(timeIntervalSince1970: 0),
                           folder: folder.role ?? .archive, isRead: metadata.flags.contains("\\seen"), isFlagged: metadata.flags.contains("\\flagged"), attachments: attachments,
                           providerThreadID: threadReference, providerFolderIDs: [folder.id], htmlBody: htmlParts.isEmpty ? nil : htmlParts.joined(separator: "\n"), cc: MIMEParser.addresses(headers["cc"] ?? ""))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ value: String?) throws -> T? {
        guard let value else { return nil }
        guard value.utf8.count <= 2 * 1_024 * 1_024 else { throw MailSyncError.invalidCheckpoint }
        do { return try JSONDecoder().decode(T.self, from: Data(value.utf8)) } catch { throw MailSyncError.invalidCheckpoint }
    }
}
private struct IMAPMailboxCheckpoint: Codable {
    var validity: UInt32; var highestUID: UInt32; var knownUIDs: [UInt32]
    init(validity: UInt32, highestUID: UInt32, knownUIDs: [UInt32] = []) { self.validity = validity; self.highestUID = highestUID; self.knownUIDs = knownUIDs }
    private enum CodingKeys: String, CodingKey { case validity, highestUID, knownUIDs }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        validity = try values.decode(UInt32.self, forKey: .validity); highestUID = try values.decode(UInt32.self, forKey: .highestUID)
        knownUIDs = try values.decodeIfPresent([UInt32].self, forKey: .knownUIDs) ?? []
        guard validity > 0, knownUIDs.count <= 500, knownUIDs.allSatisfy({ $0 > 0 }) else { throw MailSyncError.invalidCheckpoint }
    }
}
private struct IMAPCheckpoint: Codable { var accountID: UUID; var mailboxes: [String: IMAPMailboxCheckpoint] = [:] }
private struct IMAPCursor: Codable {
    var accountID: UUID; var folders: [String]; var since: Date; var folderIndex = 0
    var uids: [UInt32] = []; var validity: UInt32?; var loaded = false
}
private struct IMAPMessageReference: Codable { var folder: String; var validity: UInt32; var uid: UInt32 }
private struct IMAPAttachmentReference: Codable { var accountID: UUID; var messageID: String; var validity: UInt32; var uid: UInt32; var section: String; var encoding: String; var encodedSize: Int }
