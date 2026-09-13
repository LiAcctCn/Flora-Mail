import Foundation

enum RESTWriteValidation {
    static func validate(_ request: AuthorizedRemoteAction, accountID: UUID, reference: MailCredentialReference, configuration: OAuthClientConfiguration) throws {
        guard request.account.id == accountID, request.account.providerType == configuration.provider,
              request.account.credentialReference == reference, request.account.oauthClientID == configuration.clientID,
              request.account.oauthAccessLevel == .readWrite, configuration.accessLevel == .readWrite,
              request.account.writePermission == .userAuthorized else { throw RemoteActionError.permissionDenied }
        guard request.account.status != .disconnected, request.account.status != .reauthenticationRequired else { throw RemoteActionError.authenticationRequired }
        guard request.messages.allSatisfy({ $0.accountID == accountID && validID($0.providerID) }),
              Set(request.messages.map(\.id)).count == request.messages.count else { throw RemoteActionError.invalidRequest }
        if let draftID = request.action.draftID {
            guard let draft = request.draft, let outgoing = request.outgoing, draft.id == draftID, draft.accountID == accountID,
                  outgoing.from.email.caseInsensitiveCompare(request.account.address.email) == .orderedSame,
                  outgoing.rawData.count <= 20 * 1_024 * 1_024, !outgoing.rawData.isEmpty else { throw RemoteActionError.invalidRequest }
        } else {
            guard !request.messages.isEmpty, request.messages.count <= 100,
                  Set(request.action.messageIDs) == Set(request.messages.map(\.id)) else { throw RemoteActionError.invalidRequest }
        }
        if case .move(_, let folder) = request.action {
            guard folder.accountID == accountID, validID(folder.id) else { throw RemoteActionError.invalidRequest }
        }
    }
    static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 8_192 }
    static func json(_ value: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else { throw RemoteActionError.invalidRequest }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func response<T: Decodable>(_ type: T.Type, _ response: MailHTTPResponse) throws -> T {
        // A successful but unparseable acknowledgement is still a possible effect.
        guard let value = try? JSONDecoder().decode(type, from: response.data) else { throw RemoteActionError.outcomeUnknown }
        return value
    }
    @MainActor static func preflight<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch let error as RemoteActionError { throw error }
        catch { throw AuthorizedMailWriteTransport.preflightError(error) }
    }
}
