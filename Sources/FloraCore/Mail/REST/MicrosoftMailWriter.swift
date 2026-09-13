import Foundation

extension MicrosoftMailProvider: RemoteMailWriter {
    public func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        try Task.checkCancellation()
        try RESTWriteValidation.validate(request, accountID: accountID, reference: reference, configuration: configuration)
        var acknowledged = false
        do {
            if request.action.draftID != nil {
                let saved = try await saveGraphDraft(request); acknowledged = true
                if request.action.isSend {
                    let response = try await writer.send(.graphSend(saved.providerDraftID))
                    guard response.status == 202 else { throw RemoteActionError.outcomeUnknown }
                    // Graph acknowledges submission, not final delivery; the
                    // immutable draft ID can be reconciled during later sync.
                    return RemoteActionReceipt(draftReference: saved, sentProviderMessageID: saved.providerMessageID)
                }
                return RemoteActionReceipt(draftReference: saved)
            }
            var destination: MailFolderDescriptor?
            if case .archive = request.action {
                let bytes = try await RESTWriteValidation.preflight { try await readForWrite(["mailFolders", "archive"], query: [URLQueryItem(name: "$select", value: "id,displayName")]) }
                guard let folder = try? JSONDecoder().decode(GraphFolder.self, from: bytes), RESTWriteValidation.validID(folder.id) else { throw RemoteActionError.invalidRequest }
                destination = MailFolderDescriptor(id: folder.id, accountID: accountID, name: folder.displayName, role: .archive)
            } else if case .move(_, let folder) = request.action { destination = folder }
            var messages: [MailMessage] = [], removed: [String] = []
            for source in request.messages {
                var fields: [String: Any] = [:]
                let endpoint: MailWriteEndpoint
                if let destination { endpoint = .graphMove(source.providerID); fields = ["destinationId": destination.id] }
                else {
                    endpoint = .graphPatch(source.providerID)
                    switch request.action {
                    case .markRead(_, let read): fields = ["isRead": read]
                    case .flag(_, let flagged): fields = ["flag": ["flagStatus": flagged ? "flagged" : "notFlagged"]]
                    default: throw RemoteActionError.unsupported
                    }
                }
                let response = try await writer.send(endpoint, data: RESTWriteValidation.json(fields)); acknowledged = true
                let result = try RESTWriteValidation.response(GraphWriteMessage.self, response)
                guard RESTWriteValidation.validID(result.id), destination != nil || result.id == source.providerID else { throw RemoteActionError.outcomeUnknown }
                var updated = source
                if let destination {
                    guard result.parentFolderId == destination.id else { throw RemoteActionError.outcomeUnknown }
                    updated.providerFolderIDs = [destination.id]; updated.folder = destination.role ?? .archive
                    if result.id != source.providerID {
                        removed.append(source.providerID)
                        updated.providerID = result.id; updated.id = StableMailIdentity.message(accountID: accountID, providerID: result.id)
                    }
                }
                switch request.action {
                case .markRead(_, let read):
                    guard result.isRead == read else { throw RemoteActionError.outcomeUnknown }; updated.isRead = read
                case .flag(_, let flagged):
                    guard result.flag?.flagStatus == (flagged ? "flagged" : "notFlagged") else { throw RemoteActionError.outcomeUnknown }; updated.isFlagged = flagged
                default: break
                }
                messages.append(updated)
            }
            return RemoteActionReceipt(messages: messages, removedProviderMessageIDs: removed)
        } catch {
            if acknowledged { throw RemoteActionError.outcomeUnknown }
            throw error
        }
    }

    private func saveGraphDraft(_ request: AuthorizedRemoteAction) async throws -> RemoteDraftReference {
        guard let draft = request.draft, let outgoing = request.outgoing,
              outgoing.attachments.count <= 20, outgoing.attachments.allSatisfy({ $0.data.count <= 2 * 1_024 * 1_024 }),
              outgoing.attachments.reduce(0, { $0 + $1.data.count }) <= 8 * 1_024 * 1_024,
              outgoing.body.utf8.count <= 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
        let recipients: ([MailAddress]) -> [[String: Any]] = { addresses in addresses.map { ["emailAddress": ["name": $0.name, "address": $0.email]] } }
        let object: [String: Any] = ["subject": outgoing.subject, "body": ["contentType": "Text", "content": outgoing.body],
                                  "toRecipients": recipients(outgoing.to), "ccRecipients": recipients(outgoing.cc), "bccRecipients": recipients(outgoing.bcc),
                                  "internetMessageId": outgoing.messageID]
        let encoded = try RESTWriteValidation.json(object)
        guard encoded.count <= 4 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
        let existingID = draft.providerDraftID
        var existingAttachments: [GraphWriteAttachment] = []
        var replyID: String?
        if let id = existingID {
            guard RESTWriteValidation.validID(id) else { throw RemoteActionError.invalidRequest }
            let bytes = try await RESTWriteValidation.preflight { try await readForWrite(["messages", id], query: [URLQueryItem(name: "$select", value: "id,isDraft")]) }
            guard let existing = try? JSONDecoder().decode(GraphWriteMessage.self, from: bytes), existing.id == id, existing.isDraft == true else { throw RemoteActionError.invalidRequest }
            let attachmentBytes = try await RESTWriteValidation.preflight { try await readForWrite(["messages", id, "attachments"], query: [URLQueryItem(name: "$select", value: "id"), URLQueryItem(name: "$top", value: "100")]) }
            guard let page = try? JSONDecoder().decode(GraphWriteAttachmentPage.self, from: attachmentBytes), page.nextLink == nil,
                  page.value.count <= 100, page.value.allSatisfy({ RESTWriteValidation.validID($0.id) }) else { throw RemoteActionError.unsupported }
            existingAttachments = page.value
        } else if let sourceID = draft.replyToMessageID {
            guard let source = request.messages.first(where: { $0.id == sourceID }), source.accountID == accountID else { throw RemoteActionError.invalidRequest }
            replyID = source.providerID
        }
        // Precompute and validate every attachment before the first server write.
        let attachmentBodies = try outgoing.attachments.map { attachment in
            let data = try RESTWriteValidation.json(["@odata.type": "#microsoft.graph.fileAttachment", "name": attachment.name,
                                                     "contentType": attachment.mimeType, "contentBytes": attachment.data.base64EncodedString()])
            guard data.count < 4 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
            return data
        }
        var acknowledged = false
        do {
            let response: MailHTTPResponse
            if let id = existingID { response = try await writer.send(.graphPatch(id), data: encoded) }
            else if let replyID { response = try await writer.send(.graphCreateReply(replyID), data: RESTWriteValidation.json(["message": object])) }
            else { response = try await writer.send(.graphCreateDraft, data: encoded) }
            acknowledged = true
            let created = try RESTWriteValidation.response(GraphWriteMessage.self, response)
            guard RESTWriteValidation.validID(created.id), created.isDraft == true, existingID == nil || existingID == created.id else { throw RemoteActionError.outcomeUnknown }
            if replyID != nil {
                // Set the reviewed recipients explicitly; the server's default
                // Reply-To expansion must not silently alter the send preview.
                let patched = try RESTWriteValidation.response(GraphWriteMessage.self, await writer.send(.graphPatch(created.id), data: encoded))
                guard patched.id == created.id, patched.isDraft == true else { throw RemoteActionError.outcomeUnknown }
            }
            for attachment in existingAttachments {
                _ = try await writer.send(.graphDeleteAttachment(messageID: created.id, attachmentID: attachment.id))
            }
            for data in attachmentBodies {
                let attachment = try RESTWriteValidation.response(GraphWriteAttachment.self, await writer.send(.graphAddAttachment(created.id), data: data))
                guard RESTWriteValidation.validID(attachment.id) else { throw RemoteActionError.outcomeUnknown }
            }
            return RemoteDraftReference(providerDraftID: created.id, providerMessageID: created.id)
        } catch {
            if acknowledged { throw RemoteActionError.outcomeUnknown }
            throw error
        }
    }
}

private struct GraphWriteMessage: Decodable {
    let id: String
    let isDraft: Bool?
    let parentFolderId: String?
    let isRead: Bool?
    let flag: GraphFlag?
}
private struct GraphWriteAttachment: Decodable { let id: String }
private struct GraphWriteAttachmentPage: Decodable {
    let value: [GraphWriteAttachment]
    let nextLink: String?
    enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
}
