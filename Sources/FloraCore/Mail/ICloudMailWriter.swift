import Foundation

/// This adapter has no autonomous entry point. The coordinator supplies an
/// AuthorizedRemoteAction only after account opt-in, preview and confirmation.
@MainActor
public final class ICloudMailWriter: RemoteMailWriter {
    public var accountID: UUID { account.id }
    private let account: MailAccount
    private let credentials: any CredentialStore
    private let sessions: any IMAPSessionFactory
    private let smtp: any SMTPClient
    public init(account: MailAccount, credentials: any CredentialStore = KeychainCredentialStore(), sessionFactory: any IMAPSessionFactory = NetworkIMAPSessionFactory(), smtp: any SMTPClient = ICloudSMTPClient()) {
        self.account = account; self.credentials = credentials; sessions = sessionFactory; self.smtp = smtp
    }
    public func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        guard request.account.id == accountID, request.account.providerType == .iCloud, account.providerType == .iCloud,
              account.writePermission == .userAuthorized, request.account.writePermission == .userAuthorized,
              request.account.credentialReference == account.credentialReference else { throw RemoteActionError.permissionDenied }
        guard request.messages.count <= 100, Set(request.action.messageIDs) == Set(request.messages.map(\.id)),
              request.messages.allSatisfy({ $0.accountID == accountID }) else { throw RemoteActionError.invalidRequest }
        let credential = try await credential()
        if case .sendDraft(let draftID) = request.action {
            guard let draft = request.draft, draft.id == draftID, draft.accountID == accountID,
                  draft.deliveryState == .notSent || draft.deliveryState == .sending,
                  let mail = request.outgoing, mail.from.email.caseInsensitiveCompare(account.address.email) == .orderedSame else { throw RemoteActionError.invalidRequest }
            try await smtp.send(mail, credential: credential)
            // SMTP has acknowledged acceptance. Cleanup is normal draft
            // finalization, but can never turn this into a retryable send.
            return await finalizeSentDraft(draft, credential: credential)
        }
        let session: any IMAPSession
        do { session = try await sessions.makeSession(configuration: .iCloud) }
        catch { if error is CancellationError { throw error }; throw RemoteActionError.unavailable }
        do {
            _ = try await session.execute(.login(credential))
            guard let writable = session as? any IMAPWritableSession else { throw RemoteActionError.unsupported }
            let capabilities = IMAPWriteMapping.capabilities(try await session.execute(.capability))
            let receipt = try await perform(request, session: writable, capabilities: capabilities)
            await session.close(); return receipt
        } catch {
            await session.close()
            if let error = error as? RemoteActionError { throw error }
            if error is CancellationError { throw error }
            if error as? IMAPError == .authenticationFailed { throw RemoteActionError.authenticationRequired }
            throw RemoteActionError.unavailable
        }
    }
    private func finalizeSentDraft(_ draft: Draft, credential: IMAPCredential) async -> RemoteActionReceipt {
        guard let priorID = draft.providerDraftID else { return RemoteActionReceipt() }
        let advisory = RemoteActionReceipt(advisories: ["The message was sent. Flora could not confirm removal of the previously saved iCloud draft; review Drafts in the account. Do not send the message again to remove that draft."])
        guard !Task.isCancelled, draft.providerDraftMessageID == nil || draft.providerDraftMessageID == priorID,
              let previous = try? IMAPWriteIdentity(providerID: priorID) else { return advisory }
        var openedSession: (any IMAPSession)?
        do {
            let session = try await sessions.makeSession(configuration: .iCloud); openedSession = session
            _ = try await session.execute(.login(credential))
            guard let writable = session as? any IMAPWritableSession,
                  IMAPWriteMapping.capabilities(try await session.execute(.capability)).contains("UIDPLUS") else { throw RemoteActionError.unsupported }
            let folder = try await specialFolder(.drafts, session: session)
            guard previous.folder == folder.id else { throw RemoteActionError.invalidRequest }
            try await select(previous, session: writable)
            let states = try IMAPMapping.flagStates(await session.execute(.flags(uids: [previous.uid])))
            if let flags = states[previous.uid] {
                guard flags.contains("\\draft") else { throw RemoteActionError.invalidRequest }
                try await removeExactUID(previous.uid, session: writable)
                let remaining = try IMAPMapping.flagStates(await session.execute(.flags(uids: [previous.uid])))
                guard remaining[previous.uid] == nil else { throw RemoteActionError.outcomeUnknown }
            }
            await session.close()
            return RemoteActionReceipt(removedProviderMessageIDs: [priorID])
        } catch {
            if let openedSession { await openedSession.close() }
            // Includes cancellation, authentication expiry, unsupported safe
            // capabilities and lost cleanup acknowledgment. SMTP is complete.
            return advisory
        }
    }
    private func perform(_ request: AuthorizedRemoteAction, session: any IMAPWritableSession, capabilities: Set<String>) async throws -> RemoteActionReceipt {
        if case .syncDraft(let id) = request.action {
            guard let draft = request.draft, draft.id == id, draft.accountID == accountID,
                  draft.draftSyncStatus != .outcomeUnknown, let outgoing = request.outgoing,
                  outgoing.from.email.caseInsensitiveCompare(account.address.email) == .orderedSame else { throw RemoteActionError.invalidRequest }
            return try await saveDraft(draft, outgoing: outgoing, session: session, capabilities: capabilities)
        }
        guard !request.messages.isEmpty else { throw RemoteActionError.invalidRequest }
        let references = try request.messages.map { try IMAPWriteIdentity(providerID: $0.providerID) }
        let destination: MailFolderDescriptor?
        switch request.action {
        case .archive:
            destination = try await specialFolder(.archive, session: session)
        case .move(_, let requested):
            guard requested.accountID == accountID else { throw RemoteActionError.invalidRequest }
            let folders = try IMAPMapping.folders(await session.execute(.list), accountID: accountID)
            guard let found = folders.first(where: { $0.id == requested.id }) else { throw RemoteActionError.invalidRequest }
            destination = found
        case .markRead, .flag: destination = nil
        default: throw RemoteActionError.invalidRequest
        }
        if destination != nil, !capabilities.contains("UIDPLUS") { throw RemoteActionError.unsupported }
        var changed: [MailMessage] = []; var removed: [String] = []; var anyEffect = false
        do {
            for (message, reference) in zip(request.messages, references) {
                try await select(reference, session: session)
                let flags = try await existingFlags(reference.uid, session: session)
                var result = message; result.isRead = flags.contains("\\seen"); result.isFlagged = flags.contains("\\flagged")
                switch request.action {
                case .markRead(_, let value):
                    if flags.contains("\\seen") != value {
                        _ = try await session.executeWrite(.setFlag(uid: reference.uid, flag: .seen, enabled: value)); anyEffect = true
                        let updated = try await existingFlags(reference.uid, session: session)
                        guard updated.contains("\\seen") == value else { throw RemoteActionError.outcomeUnknown }
                    }
                    result.isRead = value
                case .flag(_, let value):
                    if flags.contains("\\flagged") != value {
                        _ = try await session.executeWrite(.setFlag(uid: reference.uid, flag: .flagged, enabled: value)); anyEffect = true
                        let updated = try await existingFlags(reference.uid, session: session)
                        guard updated.contains("\\flagged") == value else { throw RemoteActionError.outcomeUnknown }
                    }
                    result.isFlagged = value
                case .archive, .move:
                    guard let destination else { throw RemoteActionError.invalidRequest }
                    if reference.folder != destination.id {
                        let command: IMAPWriteCommand = capabilities.contains("MOVE") ? .move(uid: reference.uid, mailbox: destination.id) : .copy(uid: reference.uid, mailbox: destination.id)
                        let response = try await session.executeWrite(command); anyEffect = true
                        let newReference = try IMAPWriteMapping.copied(response, sourceUID: reference.uid, mailbox: destination.id)
                        if !capabilities.contains("MOVE") { try await removeExactUID(reference.uid, session: session) }
                        result = try remap(message, to: newReference, folder: destination.role ?? .archive)
                        removed.append(message.providerID)
                    }
                default: throw RemoteActionError.invalidRequest
                }
                changed.append(result)
            }
            return RemoteActionReceipt(messages: changed, removedProviderMessageIDs: removed)
        } catch {
            if anyEffect { throw RemoteActionError.outcomeUnknown }
            throw error
        }
    }
    private func saveDraft(_ draft: Draft, outgoing: OutgoingMail, session: any IMAPWritableSession, capabilities: Set<String>) async throws -> RemoteActionReceipt {
        // APPENDUID is essential: missing/lost receipts cannot safely be retried.
        guard capabilities.contains("UIDPLUS") else { throw RemoteActionError.unsupported }
        let folder = try await specialFolder(.drafts, session: session)
        let previous = try draft.providerDraftID.map { try IMAPWriteIdentity(providerID: $0) }
        if let previous {
            guard previous.folder == folder.id else { throw RemoteActionError.invalidRequest }
            try await select(previous, session: session)
            let flags = try await existingFlags(previous.uid, session: session)
            guard flags.contains("\\draft") else { throw RemoteActionError.invalidRequest }
        }
        var appended = false
        do {
            let response = try await session.executeWrite(.append(mailbox: folder.id, data: outgoing.rawData)); appended = true
            let identity = try IMAPWriteMapping.appended(response, mailbox: folder.id)
            if let previous {
                guard identity.validity == previous.validity, identity.uid > previous.uid else { throw RemoteActionError.outcomeUnknown }
                try await select(previous, session: session)
                try await removeExactUID(previous.uid, session: session)
            }
            let providerID = try identity.providerID
            return RemoteActionReceipt(removedProviderMessageIDs: previous.map { _ in [draft.providerDraftMessageID ?? draft.providerDraftID ?? ""] } ?? [],
                                       draftReference: RemoteDraftReference(providerDraftID: providerID, providerMessageID: providerID))
        } catch {
            if appended { throw RemoteActionError.outcomeUnknown }
            throw error
        }
    }
    private func select(_ reference: IMAPWriteIdentity, session: any IMAPWritableSession) async throws {
        let response = try await session.executeWrite(.select(reference.folder))
        guard try IMAPMapping.validity(response) == reference.validity,
              !([response.completion].compactMap { $0 } + response.strings).contains(where: { $0.uppercased().contains("[READ-ONLY]") }) else { throw RemoteActionError.invalidRequest }
    }
    private func existingFlags(_ uid: UInt32, session: any IMAPSession) async throws -> Set<String> {
        guard let flags = try IMAPMapping.flagStates(await session.execute(.flags(uids: [uid])))[uid] else { throw RemoteActionError.invalidRequest }
        return flags
    }
    private func removeExactUID(_ uid: UInt32, session: any IMAPWritableSession) async throws {
        _ = try await session.executeWrite(.setFlag(uid: uid, flag: .deleted, enabled: true))
        _ = try await session.executeWrite(.expunge(uid: uid))
    }
    private func specialFolder(_ role: MailFolder, session: any IMAPSession) async throws -> MailFolderDescriptor {
        let response = try await session.execute(.list)
        let folders = try IMAPMapping.folders(response, accountID: accountID)
        let attribute = role == .archive ? "\\archive" : "\\drafts"
        for record in response.records {
            var parser = IMAPValueParser(record); let values = try parser.parse()
            if values.count >= 5, values[1].text?.uppercased() == "LIST",
               values[2].values?.contains(where: { $0.text?.lowercased() == attribute }) == true,
               let folder = folders.first(where: { $0.id == values[4].text }) { return folder }
        }
        // Generic custom folders are projected under Archive for browsing, so
        // role alone must never choose an arbitrary user folder for mutation.
        guard let folder = folders.first(where: { $0.name.caseInsensitiveCompare(role == .archive ? "Archive" : "Drafts") == .orderedSame }) else { throw RemoteActionError.unsupported }
        return folder
    }
    private func remap(_ message: MailMessage, to identity: IMAPWriteIdentity, folder: MailFolder) throws -> MailMessage {
        var result = message; result.providerID = try identity.providerID
        result.id = StableMailIdentity.message(accountID: accountID, providerID: result.providerID)
        result.folder = folder; result.providerFolderIDs = [identity.folder]
        if message.providerThreadID == message.providerID {
            result.providerThreadID = result.providerID; result.threadID = StableMailIdentity.thread(accountID: accountID, providerID: result.providerID)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        result.attachments = try message.attachments.map { attachment in
            guard let original = attachment.providerID, let data = original.data(using: .utf8),
                  var reference = try? JSONDecoder().decode(IMAPAttachmentReference.self, from: data), reference.accountID == accountID,
                  reference.messageID == message.providerID else { throw RemoteActionError.outcomeUnknown }
            reference.messageID = result.providerID; reference.validity = identity.validity; reference.uid = identity.uid
            var updated = attachment
            updated.id = StableMailIdentity.attachment(accountID: accountID, providerID: result.providerID + ":" + reference.section)
            updated.providerID = String(decoding: try encoder.encode(reference), as: UTF8.self)
            updated.downloadState = .notDownloaded; updated.localRelativePath = nil; return updated
        }
        return result
    }
    private func credential() async throws -> IMAPCredential {
        guard let reference = account.credentialReference, let bytes = try await credentials.read(reference: reference),
              let value = try? JSONDecoder().decode(IMAPCredential.self, from: bytes), let credential = try? value.validated(),
              credential.username.caseInsensitiveCompare(account.address.email) == .orderedSame else { throw RemoteActionError.authenticationRequired }
        return credential
    }
}
