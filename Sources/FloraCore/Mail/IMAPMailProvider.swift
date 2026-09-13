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
    private let now: () -> Date
    public init(account: MailAccount, credentials: any CredentialStore = KeychainCredentialStore(), sessionFactory: any IMAPSessionFactory = NetworkIMAPSessionFactory(), configuration: IMAPConfiguration = .iCloud, now: @escaping () -> Date = Date.init) {
        self.account = account; self.credentials = credentials; self.sessionFactory = sessionFactory; self.configuration = configuration; self.now = now
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
                    let metadata = try await loadMetadata(uid: uid, session: session)
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
    public func fetchThread(message source: MailMessage) async throws -> MailThread {
        guard source.accountID == accountID, let anchor = source.providerThreadID,
              MIMEParser.messageIdentifiers(anchor) == [anchor],
              source.threadID == StableMailIdentity.thread(accountID: accountID, providerID: anchor) else { throw MailSyncError.unsupportedContent }
        _ = try IMAPCommand.searchThread(anchor: anchor).wireText()
        let session = try await authenticatedSession()
        do {
            let folders = try IMAPMapping.folders(await session.execute(.list), accountID: accountID)
            let preferred = folders.filter { source.providerFolderIDs.contains($0.id) }
                + folders.filter { !source.providerFolderIDs.contains($0.id) && ($0.role == .inbox || $0.role == .sent) }
                + folders.filter { !source.providerFolderIDs.contains($0.id) && $0.role != .inbox && $0.role != .sent }
            var result: [String: MailMessage] = [source.providerID: source]; var examined = 0
            var textBytes = source.body.utf8.count + (source.htmlBody?.utf8.count ?? 0)
            guard textBytes <= 32 * 1_024 * 1_024 else { throw IMAPError.responseTooLarge }
            let deadline = now().addingTimeInterval(120)
            var limited = preferred.count > 20
            folderLoop: for folder in preferred.prefix(20) {
                try Task.checkCancellation()
                guard now() < deadline else { limited = true; break }
                let validity = try IMAPMapping.validity(await session.execute(.examine(folder.id)))
                guard now() < deadline else { limited = true; break }
                let uids = try IMAPMapping.search(await session.execute(.searchThread(anchor: anchor))).reversed()
                for uid in uids {
                    guard examined < 500, now() < deadline else { limited = true; break folderLoop }
                    examined += 1; try Task.checkCancellation()
                    let metadata: IMAPMessageMetadata
                    do { metadata = try await loadMetadata(uid: uid, session: session, deadline: deadline) }
                    catch is IMAPConversationBudgetExceeded { limited = true; break folderLoop }
                    // IMAP HEADER search is a substring search. Filter unrelated
                    // matches before loading bodies and again after normalization.
                    let root = MIMEParser.messageIdentifiers(metadata.headers["references"]).first
                        ?? MIMEParser.messageIdentifiers(metadata.headers["in-reply-to"]).first
                        ?? MIMEParser.messageIdentifiers(metadata.headers["message-id"]).first
                    guard root == anchor else { continue }
                    let item: MailMessage
                    do { item = try await message(metadata, folder: folder, validity: validity, session: session, deadline: deadline) }
                    catch is IMAPConversationBudgetExceeded { limited = true; break folderLoop }
                    guard item.accountID == accountID, item.providerThreadID == anchor, item.threadID == source.threadID else { continue }
                    guard result.count < 500 || result[item.providerID] != nil else { limited = true; break folderLoop }
                    let bytes = item.body.utf8.count + (item.htmlBody?.utf8.count ?? 0)
                    let previousBytes = result[item.providerID].map { $0.body.utf8.count + ($0.htmlBody?.utf8.count ?? 0) } ?? 0
                    guard bytes <= 32 * 1_024 * 1_024 - textBytes + previousBytes else { limited = true; break folderLoop }
                    textBytes += bytes - previousBytes; result[item.providerID] = item
                }
            }
            try Task.checkCancellation(); await session.close()
            var messages = result.values.sorted { $0.date < $1.date }
            if limited, !messages.isEmpty {
                messages[0].contentWarnings.append("Conversation retrieval reached Flora's limit of 20 folders, 500 candidate messages, 32 MiB of text or its retrieval time budget. Additional messages may remain on the server.")
            }
            return MailThread(id: source.threadID, messages: messages)
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
            let decoded = try MIMEParser.decodeTransferValidated(data, encoding: reference.encoding)
            try Task.checkCancellation(); await session.close(); return decoded
        } catch { await session.close(); throw error }
    }
    private func loadMetadata(uid: UInt32, session: any IMAPSession, deadline: Date? = nil) async throws -> IMAPMessageMetadata {
        try checkConversationDeadline(deadline)
        let response = try await session.execute(.metadata(uid: uid))
        do { return try IMAPMapping.metadata(response, uid: uid) }
        catch {
            // BODYSTRUCTURE syntax from one message can be malformed even when
            // the tagged IMAP command completed. Retry only bounded headers;
            // transport/protocol failures from execute are never swallowed.
            try checkConversationDeadline(deadline)
            let headers = try await session.execute(.headers(uid: uid))
            var metadata: IMAPMessageMetadata
            do { metadata = try IMAPMapping.metadata(headers, uid: uid, requireStructure: false) }
            catch { metadata = IMAPMessageMetadata(uid: uid, flags: [], headers: [:], date: nil, parts: []) }
            metadata.warnings.append("The server returned malformed message metadata. Available headers are shown; later messages can still synchronize.")
            return metadata
        }
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
    private func message(_ metadata: IMAPMessageMetadata, folder: MailFolderDescriptor, validity: UInt32, session: any IMAPSession, deadline: Date? = nil) async throws -> MailMessage {
        let providerID = try Self.encode(IMAPMessageReference(folder: folder.id, validity: validity, uid: metadata.uid))
        let preferred = metadata.parts.filter { !$0.isAttachment && $0.isPreferredText && ["text/plain", "text/html"].contains($0.mimeType) }
        var bodyParts: [String] = []; var htmlParts: [String] = []; var remaining = MIMEParser.maximumTextBytes
        var warnings = metadata.warnings
        for part in preferred.prefix(20) where remaining > 0 {
            let length = min(part.size, remaining)
            if length == 0 { continue }
            // Network failures still stop the page. A successfully retrieved but
            // malformed MIME part produces a partial preview and can advance.
            try checkConversationDeadline(deadline)
            let response = try await session.execute(.body(uid: metadata.uid, section: part.section, maximumBytes: length))
            do {
                let encoded = try IMAPMapping.body(response, uid: metadata.uid, section: part.section)
                guard encoded.count <= length else { throw IMAPError.malformedResponse }
                let decoded = try MIMEParser.decodeTransferValidated(encoded, encoding: part.encoding, allowTruncated: part.size > length)
                let text = MIMEParser.decodeText(decoded, charset: part.charset)
                bodyParts.append(part.mimeType == "text/html" ? MIMEParser.htmlToText(text) : text)
                if part.mimeType == "text/html" { htmlParts.append(text) }
                if let header = part.forwardedHeader { warnings.append("Included inline \(header.lowercased()).") }
                if part.size > length { warnings.append("Message preview is truncated at Flora's local size limit.") }
            } catch {
                warnings.append("A message part could not be decoded. Other readable content is still shown.")
            }
            // Charge requested bytes even for bad/empty responses so malformed
            // alternatives cannot bypass the per-message preview budget.
            remaining -= length
        }
        if preferred.count > 20 || (remaining == 0 && preferred.reduce(0, { $0 + min($1.size, MIMEParser.maximumTextBytes) }) > MIMEParser.maximumTextBytes) {
            warnings.append("Additional message text exceeds Flora's bounded preview limit.")
        }
        let attachments = try metadata.parts.filter(\.isAttachment).map { part in
            let reference = IMAPAttachmentReference(accountID: accountID, messageID: providerID, validity: validity, uid: metadata.uid, section: part.section, encoding: part.encoding, encodedSize: part.size)
            return MailAttachment(id: StableMailIdentity.attachment(accountID: accountID, providerID: providerID + ":" + part.section), name: part.name ?? "Attachment \(part.section)", size: part.encoding == "base64" ? part.size * 3 / 4 : part.size, providerID: try Self.encode(reference), mimeType: part.mimeType, isInline: part.isInline, contentID: part.contentID)
        }
        let headers = metadata.headers
        let threadReference = MIMEParser.messageIdentifiers(headers["references"]).first ?? MIMEParser.messageIdentifiers(headers["in-reply-to"]).first ?? MIMEParser.messageIdentifiers(headers["message-id"]).first ?? providerID
        let rendered = bodyParts.joined(separator: "\n\n")
        if rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("No readable text preview is available. This message may contain only attachments or unsupported content.")
        }
        let body = rendered
        return MailMessage(id: StableMailIdentity.message(accountID: accountID, providerID: providerID), providerID: providerID, accountID: accountID,
                           threadID: StableMailIdentity.thread(accountID: accountID, providerID: threadReference), from: MIMEParser.addresses(headers["from"] ?? "").first ?? MailAddress(name: "Unknown sender", email: ""),
                           to: MIMEParser.addresses(headers["to"] ?? ""), subject: headers["subject"] ?? "(No subject)", body: body, date: MIMEParser.date(headers["date"]) ?? metadata.date ?? Date(timeIntervalSince1970: 0),
                           folder: folder.role ?? .archive, isRead: metadata.flags.contains("\\seen"), isFlagged: metadata.flags.contains("\\flagged"), attachments: attachments,
                           providerThreadID: threadReference, providerFolderIDs: [folder.id], htmlBody: htmlParts.isEmpty ? nil : htmlParts.joined(separator: "\n"), cc: MIMEParser.addresses(headers["cc"] ?? ""), contentWarnings: Array(Set(warnings)).sorted())
    }
    private func checkConversationDeadline(_ deadline: Date?) throws {
        if let deadline, now() >= deadline { throw IMAPConversationBudgetExceeded() }
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

/// Internal control flow for returning an already retrieved partial conversation.
private struct IMAPConversationBudgetExceeded: Error {}
