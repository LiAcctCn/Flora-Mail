import Foundation
import CryptoKit
import Security

/// Public native application identifiers, never client secrets.
public struct OAuthClientConfiguration: Codable, Equatable, Sendable {
    public let provider: MailProviderType
    public let clientID: String
    public init(provider: MailProviderType, clientID: String) { self.provider = provider; self.clientID = clientID }
    public func validated() throws -> OAuthClientConfiguration {
        guard provider == .gmail || provider == .microsoft, !clientID.isEmpty, clientID.count < 256,
              !clientID.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw RemoteMailError.invalidConfiguration }
        if provider == .gmail {
            guard clientID.hasSuffix(".apps.googleusercontent.com") else { throw RemoteMailError.invalidConfiguration }
        } else { guard UUID(uuidString: clientID) != nil else { throw RemoteMailError.invalidConfiguration } }
        return self
    }
    public var scopes: [String] {
        provider == .gmail ? ["https://www.googleapis.com/auth/gmail.readonly"] : ["https://graph.microsoft.com/Mail.Read", "https://graph.microsoft.com/User.Read", "offline_access"]
    }
    var tokenURL: URL {
        // Fixed compile-time URLs are isolated here; invalid public configuration is rejected before use.
        get throws {
            let text = provider == .gmail ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token"
            guard let result = URL(string: text) else { throw RemoteMailError.invalidConfiguration }
            return result
        }
    }
}

public struct OAuthAuthorizationRequest: Sendable, CustomDebugStringConvertible {
    public let authorizationURL: URL
    public let redirectURI: URL
    public let configuration: OAuthClientConfiguration
    fileprivate let verifier: String
    fileprivate let state: String
    fileprivate let createdAt: Date
    public var debugDescription: String { "OAuthAuthorizationRequest(authorization details redacted)" }
}

/// Authorization codes and tokens are deliberately not exposed to SwiftUI.
public struct OAuthService: Sendable {
    private let credentials: any CredentialStore
    private let http: any MailHTTPClient
    public init(credentials: any CredentialStore = KeychainCredentialStore(), http: any MailHTTPClient = SecureMailHTTPClient()) {
        self.credentials = credentials; self.http = http
    }
    public func makeAuthorizationRequest(configuration: OAuthClientConfiguration, redirectURI: URL) throws -> OAuthAuthorizationRequest {
        let configuration = try configuration.validated()
        guard let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false), redirect.scheme == "http",
              (redirect.host == "127.0.0.1" || configuration.provider == .microsoft && redirect.host == "localhost"), let port = redirect.port, port > 1023,
              redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil else {
            throw RemoteMailError.invalidConfiguration
        }
        let verifier = try randomURLSafeString(), state = try randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
        let host = configuration.provider == .gmail ? "accounts.google.com" : "login.microsoftonline.com"
        let path = configuration.provider == .gmail ? "/o/oauth2/v2/auth" : "/common/oauth2/v2.0/authorize"
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = path
        url.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID),
                          URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                          URLQueryItem(name: "response_type", value: "code"),
                          URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
                          URLQueryItem(name: "code_challenge", value: challenge),
                          URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        if configuration.provider == .gmail {
            url.queryItems?.append(contentsOf: [URLQueryItem(name: "access_type", value: "offline"), URLQueryItem(name: "prompt", value: "consent select_account")])
        } else {
            url.queryItems?.append(contentsOf: [URLQueryItem(name: "response_mode", value: "query"), URLQueryItem(name: "prompt", value: "select_account")])
        }
        guard let authorizationURL = url.url else { throw RemoteMailError.invalidConfiguration }
        return OAuthAuthorizationRequest(authorizationURL: authorizationURL, redirectURI: redirectURI,
                                         configuration: configuration, verifier: verifier, state: state, createdAt: Date())
    }
    public func exchange(callbackURL: URL, request: OAuthAuthorizationRequest, credentialReference: MailCredentialReference) async throws {
        try Task.checkCancellation()
        let code = try authorizationCode(callbackURL: callbackURL, request: request)
        let values = ["client_id": request.configuration.clientID, "code": code, "code_verifier": request.verifier,
                      "redirect_uri": request.redirectURI.absoluteString, "grant_type": "authorization_code"]
        let token = try await OAuthTokenExchange.exchange(configuration: request.configuration, values: values, previous: nil, http: http)
        try Task.checkCancellation()
        try await credentials.write(JSONEncoder().encode(token), reference: credentialReference)
    }
    private func authorizationCode(callbackURL: URL, request: OAuthAuthorizationRequest) throws -> String {
        guard Date().timeIntervalSince(request.createdAt) < 600,
              let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false),
              callback.scheme == expected.scheme, callback.host == expected.host, callback.port == expected.port,
              callback.path == expected.path, callback.fragment == nil, callback.user == nil, callback.password == nil else {
            throw RemoteMailError.authenticationRequired
        }
        let items = callback.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == request.state else { throw RemoteMailError.authenticationRequired }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? RemoteMailError.cancelled : RemoteMailError.authorizationDenied
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.count < 8_192 else { throw RemoteMailError.authenticationRequired }
        return code
    }
    private func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CredentialError.unavailable }
        return Data(bytes).base64URLString
    }
}

struct OAuthCredential: Codable, Sendable, CustomDebugStringConvertible {
    let provider: MailProviderType
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String
    var debugDescription: String { "OAuthCredential(redacted)" }
}

private enum OAuthTokenExchange {
    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let token_type: String
        let expires_in: Double
        let scope: String?
    }
    static func exchange(configuration: OAuthClientConfiguration, values: [String: String], previous: OAuthCredential?, http: any MailHTTPClient) async throws -> OAuthCredential {
        var request = URLRequest(url: try configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(values.keys.sorted().map { key in
            "\(key)=\(values[key]?.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
        let response = try await http.send(request)
        guard response.status != 400, response.status != 401 else { throw RemoteMailError.authenticationRequired }
        let decoded = try MailHTTP.decode(TokenResponse.self, MailHTTP.checked(response))
        guard decoded.token_type.lowercased() == "bearer", !decoded.access_token.isEmpty, decoded.access_token.count <= 32_768,
              decoded.expires_in.isFinite, decoded.expires_in > 0, decoded.expires_in <= 31_536_000,
              let refresh = decoded.refresh_token ?? previous?.refreshToken, !refresh.isEmpty, refresh.count <= 32_768 else {
            throw RemoteMailError.authenticationRequired
        }
        let scope = decoded.scope ?? previous?.scope ?? configuration.scopes.joined(separator: " ")
        try validateScope(scope, configuration: configuration)
        return OAuthCredential(provider: configuration.provider, clientID: configuration.clientID, accessToken: decoded.access_token,
                               refreshToken: refresh, expiresAt: Date().addingTimeInterval(decoded.expires_in), scope: scope)
    }
    static func validateScope(_ scope: String, configuration: OAuthClientConfiguration) throws {
        let scopes = Set(scope.split(separator: " ").map { $0.lowercased().replacingOccurrences(of: "https://graph.microsoft.com/", with: "") })
        if configuration.provider == .gmail {
            guard scopes.contains("https://www.googleapis.com/auth/gmail.readonly"),
                  scopes.isSubset(of: ["https://www.googleapis.com/auth/gmail.readonly"]) else { throw RemoteMailError.authorizationDenied }
        } else {
            guard scopes.contains("mail.read"), scopes.contains("user.read"),
                  scopes.isSubset(of: ["mail.read", "user.read", "offline_access", "openid", "profile", "email"]) else { throw RemoteMailError.authorizationDenied }
        }
    }
}

/// Refreshes use the same public-client registration and rotate refresh tokens in Keychain.
public actor OAuthAccessTokenProvider {
    private let configuration: OAuthClientConfiguration
    private let reference: MailCredentialReference
    private let credentials: any CredentialStore
    private let http: any MailHTTPClient
    private var refreshTask: Task<String, Error>?
    public init(configuration: OAuthClientConfiguration, reference: MailCredentialReference, credentials: any CredentialStore, http: any MailHTTPClient) {
        self.configuration = configuration; self.reference = reference; self.credentials = credentials; self.http = http
    }
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        if let refreshTask { return try await withTaskCancellationHandler { try await refreshTask.value } onCancel: { refreshTask.cancel() } }
        _ = try configuration.validated()
        guard let bytes = try await credentials.read(reference: reference),
              let token = try? JSONDecoder().decode(OAuthCredential.self, from: bytes),
              token.provider == configuration.provider, token.clientID == configuration.clientID else { throw RemoteMailError.authenticationRequired }
        try OAuthTokenExchange.validateScope(token.scope, configuration: configuration)
        if !forceRefresh && token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
        if let refreshTask { return try await withTaskCancellationHandler { try await refreshTask.value } onCancel: { refreshTask.cancel() } }
        let task = Task { [configuration, credentials, reference, http] in
            var values = ["client_id": configuration.clientID, "grant_type": "refresh_token", "refresh_token": token.refreshToken]
            if configuration.provider == .microsoft { values["scope"] = configuration.scopes.joined(separator: " ") }
            let refreshed = try await OAuthTokenExchange.exchange(configuration: configuration, values: values, previous: token, http: http)
            try Task.checkCancellation()
            try await credentials.write(JSONEncoder().encode(refreshed), reference: reference)
            return refreshed.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

extension Data {
    var base64URLString: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

/// Internal bearer transport is GET-only. No remote mutation API is exposed.
struct AuthorizedMailReader: Sendable {
    let tokens: OAuthAccessTokenProvider
    let http: any MailHTTPClient
    let host: String
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try SecureMailHTTPClient.validate(url)
        guard url.host == host else { throw RemoteMailError.invalidConfiguration }
        for attempt in 0...1 {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: attempt == 1)
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let response = try await http.send(request)
            try Task.checkCancellation()
            if response.status == 401 && attempt == 0 { continue }
            return try MailHTTP.checked(response)
        }
        throw RemoteMailError.authenticationRequired
    }
}
