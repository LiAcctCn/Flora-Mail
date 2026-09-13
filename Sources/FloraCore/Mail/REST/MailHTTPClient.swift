import Foundation

public struct MailHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let retryAfter: TimeInterval?
    public init(data: Data, status: Int, retryAfter: TimeInterval? = nil) {
        self.data = data; self.status = status; self.retryAfter = retryAfter
    }
}

public protocol MailHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> MailHTTPResponse
}

public enum RemoteMailError: Error, LocalizedError, Equatable, Sendable, MailSyncFailure {
    case invalidConfiguration, authenticationRequired, authorizationDenied, cancelled
    case networkUnavailable, timedOut, rateLimited, malformedResponse, messageUnavailable
    case unsupportedContent, responseTooLarge, staleCheckpoint, readOnly
    public var syncError: MailSyncError {
        switch self {
        case .authenticationRequired, .authorizationDenied: .authenticationRequired
        case .invalidConfiguration: .invalidCredentials
        case .timedOut: .timedOut
        case .rateLimited: .rateLimited
        case .staleCheckpoint: .invalidCheckpoint
        case .malformedResponse: .malformedResponse
        case .unsupportedContent, .responseTooLarge: .unsupportedContent
        case .networkUnavailable, .cancelled, .messageUnavailable, .readOnly: .unavailable
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Account configuration is incomplete or invalid. Check the registered application ID."
        case .authenticationRequired: "Authentication expired or was revoked. Reconnect this account."
        case .authorizationDenied: "Mail access was not granted. Reconnect and approve read-only mail access."
        case .cancelled: "Account sign-in was cancelled."
        case .networkUnavailable: "Unable to reach the mail service. Cached mail remains available."
        case .timedOut: "The mail service took too long to respond. Try again."
        case .rateLimited: "The mail service is limiting requests. Try again later."
        case .malformedResponse: "The mail service returned an unsupported response. Try syncing again."
        case .messageUnavailable: "This message or attachment is no longer available from the server."
        case .unsupportedContent: "This message content is not supported yet."
        case .responseTooLarge: "This message or attachment exceeds the prototype's download limit."
        case .staleCheckpoint: "The saved sync position expired. A new recent-mail sync is required."
        case .readOnly: "Real accounts are read-only in this version of Flora Mail."
        }
    }
}

/// Only known TLS provider endpoints are reachable. Redirects are rejected so bearer
/// credentials can never follow a provider-supplied URL to a different origin.
public final class SecureMailHTTPClient: MailHTTPClient, @unchecked Sendable {
    public static let allowedHosts: Set<String> = ["gmail.googleapis.com", "oauth2.googleapis.com", "graph.microsoft.com", "login.microsoftonline.com"]
    public static let maximumResponseBytes = 32 * 1024 * 1024
    private let session: URLSession
    private let delegate: NoMailRedirects
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
        let delegate = NoMailRedirects()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public static func validate(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host?.lowercased(), allowedHosts.contains(host),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443 else { throw RemoteMailError.invalidConfiguration }
    }
    public func send(_ request: URLRequest) async throws -> MailHTTPResponse {
        guard let url = request.url else { throw RemoteMailError.invalidConfiguration }
        try Self.validate(url)
        try Task.checkCancellation()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteMailError.malformedResponse }
            guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw RemoteMailError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                if data.count >= Self.maximumResponseBytes { throw RemoteMailError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return MailHTTPResponse(data: data, status: http.statusCode,
                                    retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        } catch is CancellationError { throw CancellationError() }
        catch let error as RemoteMailError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? RemoteMailError.timedOut : RemoteMailError.networkUnavailable
        } catch { throw RemoteMailError.networkUnavailable }
    }
}

private final class NoMailRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum MailHTTP {
    static func checked(_ response: MailHTTPResponse) throws -> Data {
        switch response.status {
        case 200...299: return response.data
        case 401: throw RemoteMailError.authenticationRequired
        case 403:
            // Gmail can use 403 for quota limits; only known machine codes are
            // interpreted. Arbitrary provider text is never persisted or shown.
            if let body = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
               let error = body["error"] as? [String: Any], let errors = error["errors"] as? [[String: Any]],
               errors.contains(where: { ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"].contains($0["reason"] as? String ?? "") }) {
                throw RemoteMailError.rateLimited
            }
            throw RemoteMailError.authorizationDenied
        case 404: throw RemoteMailError.messageUnavailable
        case 410: throw RemoteMailError.staleCheckpoint
        case 429: throw RemoteMailError.rateLimited
        case 400, 422: throw RemoteMailError.malformedResponse
        case 413: throw RemoteMailError.responseTooLarge
        default: throw RemoteMailError.networkUnavailable
        }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw RemoteMailError.malformedResponse }
    }
    static func url(host: String, path: [String], query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = host
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        parts.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw RemoteMailError.invalidConfiguration }
        return url
    }
}
