import Foundation

/// Routes, verbs and origins are fixed here. This transport cannot delete mail,
/// change account settings, forward credentials or execute arbitrary Graph URLs.
enum MailWriteEndpoint: Sendable {
    case gmailModify(String), gmailTrash(String), gmailUntrash(String), gmailCreateDraft, gmailUpdateDraft(String), gmailSendMessage, gmailSendDraft
    case graphPatch(String), graphMove(String), graphCreateDraft, graphCreateReply(String), graphSend(String)
    case graphAddAttachment(String), graphDeleteAttachment(messageID: String, attachmentID: String)

    var provider: MailProviderType {
        switch self {
        case .gmailModify, .gmailTrash, .gmailUntrash, .gmailCreateDraft, .gmailUpdateDraft, .gmailSendMessage, .gmailSendDraft: .gmail
        default: .microsoft
        }
    }
    var route: (method: String, path: [String]) {
        switch self {
        case .gmailModify(let id): ("POST", ["messages", id, "modify"])
        case .gmailTrash(let id): ("POST", ["messages", id, "trash"])
        case .gmailUntrash(let id): ("POST", ["messages", id, "untrash"])
        case .gmailCreateDraft: ("POST", ["drafts"])
        case .gmailUpdateDraft(let id): ("PUT", ["drafts", id])
        case .gmailSendMessage: ("POST", ["messages", "send"])
        case .gmailSendDraft: ("POST", ["drafts", "send"])
        case .graphPatch(let id): ("PATCH", ["messages", id])
        case .graphMove(let id): ("POST", ["messages", id, "move"])
        case .graphCreateDraft: ("POST", ["messages"])
        case .graphCreateReply(let id): ("POST", ["messages", id, "createReply"])
        case .graphSend(let id): ("POST", ["messages", id, "send"])
        case .graphAddAttachment(let id): ("POST", ["messages", id, "attachments"])
        case .graphDeleteAttachment(let messageID, let attachmentID): ("DELETE", ["messages", messageID, "attachments", attachmentID])
        }
    }
}

/// Separate from the GET-only mail reader. No request is automatically replayed,
/// including 401 responses: a later user action can retry after reauthentication.
struct AuthorizedMailWriteTransport: Sendable {
    let configuration: OAuthClientConfiguration
    let tokens: OAuthAccessTokenProvider
    let http: any MailHTTPClient

    func send(_ endpoint: MailWriteEndpoint, data: Data = Data(), contentType: String = "application/json") async throws -> MailHTTPResponse {
        try Task.checkCancellation()
        guard configuration.accessLevel == .readWrite, endpoint.provider == configuration.provider else { throw RemoteActionError.permissionDenied }
        let route = endpoint.route
        guard route.path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 }),
              data.count <= 28 * 1_024 * 1_024,
              ["application/json", "text/plain"].contains(contentType) else { throw RemoteActionError.invalidRequest }
        let host = configuration.provider == .gmail ? "gmail.googleapis.com" : "graph.microsoft.com"
        let prefix = configuration.provider == .gmail ? ["gmail", "v1", "users", "me"] : ["v1.0", "me"]
        let url = try MailHTTP.url(host: host, path: prefix + route.path)
        try SecureMailHTTPClient.validate(url)
        let token: String
        do { token = try await tokens.accessToken() }
        catch is CancellationError { throw CancellationError() }
        catch { throw Self.preflightError(error) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = route.method; request.httpBody = data
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        if configuration.provider == .microsoft { request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer") }
        let response: MailHTTPResponse
        // Once handed to the network, a transport error or cancellation cannot
        // prove that the service did not apply the operation.
        do { response = try await http.send(request) }
        catch { throw RemoteActionError.outcomeUnknown }
        switch response.status {
        case 200...299: return response
        case 401: throw RemoteActionError.authenticationRequired
        case 403:
            do { _ = try MailHTTP.checked(response) }
            catch RemoteMailError.rateLimited { throw RemoteActionError.rateLimited }
            catch { throw RemoteActionError.permissionDenied }
            throw RemoteActionError.permissionDenied
        case 429: throw RemoteActionError.rateLimited
        case 400, 404, 409, 410, 412, 413, 422: throw RemoteActionError.invalidRequest
        default: throw RemoteActionError.outcomeUnknown
        }
    }
    static func preflightError(_ error: any Error) -> RemoteActionError {
        switch error as? RemoteMailError {
        case .authenticationRequired: .authenticationRequired
        case .authorizationDenied, .readOnly: .permissionDenied
        case .rateLimited: .rateLimited
        case .invalidConfiguration, .malformedResponse, .messageUnavailable: .invalidRequest
        default: .unavailable
        }
    }
}
