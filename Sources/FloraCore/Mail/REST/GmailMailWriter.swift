import Foundation

extension GmailMailProvider: RemoteMailWriter {
    public func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        try Task.checkCancellation()
        try RESTWriteValidation.validate(request, accountID: accountID, reference: reference, configuration: configuration)
        var acknowledged = false
        do {
            switch request.action {
            case .syncDraft, .sendDraft:
                guard let originalOutgoing = request.outgoing, let draft = request.draft else { throw RemoteActionError.invalidRequest }
                let outgoing = try await gmailReplyContext(originalOutgoing, draft: draft, request: request)
                var message: [String: Any] = ["raw": outgoing.rawData.base64URLString]
                if let thread = outgoing.providerThreadID { message["threadId"] = thread }
                var saved: RemoteDraftReference?
                if !request.action.isSend || draft.providerDraftID != nil {
                    let endpoint: MailWriteEndpoint = draft.providerDraftID.map(MailWriteEndpoint.gmailUpdateDraft) ?? .gmailCreateDraft
                    var object: [String: Any] = ["message": message]
                    if let id = draft.providerDraftID { object["id"] = id }
                    let response = try await writer.send(endpoint, data: RESTWriteValidation.json(object)); acknowledged = true
                    let result = try RESTWriteValidation.response(GmailWriteDraft.self, response)
                    guard RESTWriteValidation.validID(result.id), RESTWriteValidation.validID(result.message.id) else { throw RemoteActionError.outcomeUnknown }
                    saved = RemoteDraftReference(providerDraftID: result.id, providerMessageID: result.message.id)
                    if !request.action.isSend { return RemoteActionReceipt(draftReference: saved) }
                }
                let response: MailHTTPResponse
                if let saved { response = try await writer.send(.gmailSendDraft, data: RESTWriteValidation.json(["id": saved.providerDraftID])) }
                else { response = try await writer.send(.gmailSendMessage, data: RESTWriteValidation.json(message)) }
                acknowledged = true
                let result = try RESTWriteValidation.response(GmailWriteMessage.self, response)
                guard RESTWriteValidation.validID(result.id) else { throw RemoteActionError.outcomeUnknown }
                return RemoteActionReceipt(draftReference: saved, sentProviderMessageID: result.id)
            default:
                var add: [String] = [], remove: [String] = []
                switch request.action {
                case .markRead(_, let read): if read { remove = ["UNREAD"] } else { add = ["UNREAD"] }
                case .flag(_, let flagged): if flagged { add = ["STARRED"] } else { remove = ["STARRED"] }
                case .archive:
                    guard !request.messages.contains(where: { $0.folder == .trash || $0.providerFolderIDs.contains("TRASH") }) else { throw RemoteActionError.unsupported }
                    remove = ["INBOX"]
                case .move(_, let destination):
                    // Labels are not exclusive folders. Moving to a user label
                    // removes Inbox while preserving every unrelated label.
                    guard destination.id == "INBOX" || destination.id == "TRASH" || destination.id.hasPrefix("Label_") else { throw RemoteActionError.unsupported }
                    add = [destination.id]; if destination.id != "INBOX" { remove = ["INBOX"] }
                default: throw RemoteActionError.unsupported
                }
                let body = try RESTWriteValidation.json(["addLabelIds": add, "removeLabelIds": remove])
                var messages: [MailMessage] = []
                for source in request.messages {
                    let response: MailHTTPResponse
                    if add == ["TRASH"] { response = try await writer.send(.gmailTrash(source.providerID)) }
                    else {
                        if case .move = request.action, source.folder == .trash || source.providerFolderIDs.contains("TRASH") {
                            let restored = try await writer.send(.gmailUntrash(source.providerID)); acknowledged = true
                            let result = try RESTWriteValidation.response(GmailWriteMessage.self, restored)
                            guard result.id == source.providerID, result.labelIds?.contains("TRASH") == false else { throw RemoteActionError.outcomeUnknown }
                        }
                        response = try await writer.send(.gmailModify(source.providerID), data: body)
                    }
                    acknowledged = true
                    let result = try RESTWriteValidation.response(GmailWriteMessage.self, response)
                    guard result.id == source.providerID, let labels = result.labelIds,
                          Set(add).isSubset(of: Set(labels)), Set(remove).isDisjoint(with: Set(labels)) else { throw RemoteActionError.outcomeUnknown }
                    var updated = source
                    updated.providerFolderIDs = labels; updated.folder = GmailMapping.role(labels: labels) ?? .archive
                    updated.isRead = !labels.contains("UNREAD"); updated.isFlagged = labels.contains("STARRED"); updated.isImportant = labels.contains("IMPORTANT")
                    messages.append(updated)
                }
                return RemoteActionReceipt(messages: messages)
            }
        } catch {
            if acknowledged { throw RemoteActionError.outcomeUnknown }
            throw error
        }
    }
    private func gmailReplyContext(_ outgoing: OutgoingMail, draft: Draft, request: AuthorizedRemoteAction) async throws -> OutgoingMail {
        guard outgoing.inReplyTo == nil, let sourceID = draft.replyToMessageID else { return outgoing }
        guard var source = request.messages.first(where: { $0.id == sourceID }) else { throw RemoteActionError.invalidRequest }
        let bytes = try await RESTWriteValidation.preflight { try await readForWrite(["messages", source.providerID], query: [
            URLQueryItem(name: "format", value: "metadata"), URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
            URLQueryItem(name: "metadataHeaders", value: "References")]) }
        guard let metadata = try? JSONDecoder().decode(GmailMessageDTO.self, from: bytes), metadata.id == source.providerID,
              metadata.threadId == source.providerThreadID else { throw RemoteActionError.invalidRequest }
        let headers = (metadata.envelopeHeaders).reduce(into: [String: String]()) { values, item in
            if values[item.name.lowercased()] == nil { values[item.name.lowercased()] = item.value }
        }
        source.internetMessageID = headers["message-id"]; source.references = RESTMailContent.messageReferences(headers["references"])
        let result = try OutgoingMIMEComposer.compose(account: request.account, draft: draft, source: source, attachments: outgoing.attachments, allowEmptyRecipients: !request.action.isSend)
        guard result.inReplyTo != nil else { throw RemoteActionError.unsupported }
        return result
    }

}

private struct GmailWriteMessage: Decodable { let id: String; let labelIds: [String]? }
private struct GmailWriteDraft: Decodable { let id: String; let message: GmailWriteMessage }
