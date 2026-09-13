import Foundation

public protocol LocalModelClient: Sendable {
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput
}

/// Ollama's native local API. Even a loopback Ollama server can forward cloud models;
/// metadata checks and the server-enforced :local selector both precede inference.
/// The runtime contract is verified against Ollama 0.34.0, the minimum supported version.
public struct OllamaLocalModelClient: LocalModelClient {
    private let protocolClasses: [AnyClass]?

    public init() { protocolClasses = nil }

    // Only tests can inject a URLProtocol. All other transport policy remains enforced.
    init(protocolClasses: [AnyClass]) { self.protocolClasses = protocolClasses }

    public func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity {
        try Task.checkCancellation()
        let configuration = try configuration.validated()
        let version: VersionResponse = try await send(path: "version", configuration: configuration)
        guard supportsLocalSelector(version.version) else { throw AIError.unsupportedRuntime }
        let listing: TagsResponse = try await send(path: "tags", configuration: configuration)
        let requested = configuration.model.lowercased()
        guard let installed = listing.models.first(where: {
            $0.name.lowercased() == requested || $0.model?.lowercased() == requested ||
            (!requested.contains(":") && $0.name.lowercased() == requested + ":latest")
        }) else { throw AIError.modelUnavailable }
        guard installed.remoteHost?.isEmpty != false, installed.remoteModel?.isEmpty != false,
              installed.details?.format == "gguf" || installed.details?.format == "safetensors",
              installed.size > 0, validDigest(installed.digest) else {
            throw AIError.invalidResponse("The runtime did not identify an installed on-device model.")
        }
        let selected = try AIModelConfiguration(endpoint: configuration.endpoint, model: installed.name,
                                                timeoutSeconds: configuration.timeoutSeconds).validated()
        let shown: ShowResponse = try await send(path: "show", body: ["model": selected.model + ":local"], configuration: configuration)
        guard shown.remoteHost?.isEmpty != false, shown.remoteModel?.isEmpty != false,
              shown.details?.format == "gguf" || shown.details?.format == "safetensors" else {
            throw AIError.invalidResponse("The selected model cannot be verified as on-device.")
        }
        guard shown.capabilities?.contains("completion") == true else { throw AIError.unsupportedCapability }
        try Task.checkCancellation()
        return LocalModelIdentity(runtimeVersion: version.version, model: selected.model, digest: installed.digest)
    }

    public func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        try Task.checkCancellation()
        let configuration = try configuration.validated()
        guard request.system.utf8.count + request.prompt.utf8.count <= 96 * 1024,
              request.schemaJSON.utf8.count <= 16 * 1024 else { throw AIError.inputTooLong }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyText }
        guard (1...2048).contains(request.maxTokens) else {
            throw AIError.invalidConfiguration("Use a generation limit between 1 and 2048 tokens.")
        }
        guard let schemaData = request.schemaJSON.data(using: .utf8),
              let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              schema["type"] as? String == "object" else {
            throw AIError.invalidConfiguration("A structured JSON object schema is required.")
        }
        let identity = try await inspect(configuration)
        try Task.checkCancellation()
        let response: ChatResponse = try await send(path: "chat", body: [
            "model": identity.model + ":local",
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.prompt]],
            "format": schema, "stream": false, "think": false,
            // The provider discloses its own context limit. Do not let the runtime
            // silently remove additional source text or instructions to fit memory.
            "truncate": false, "shift": false,
            "options": ["temperature": 0, "num_predict": request.maxTokens]
        ], configuration: configuration)
        guard response.remoteHost?.isEmpty != false, response.remoteModel?.isEmpty != false,
              response.model == identity.model + ":local",
              response.done, response.doneReason == "stop",
              response.message.role == "assistant",
              response.message.toolCalls?.isEmpty != false,
              !response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidResponse("The local model returned an incomplete or unsupported response.")
        }
        try Task.checkCancellation()
        return LocalModelOutput(content: response.message.content, identity: identity)
    }

    private func send<Response: Decodable>(
        path: String, body: [String: Any]? = nil, configuration: AIModelConfiguration
    ) async throws -> Response {
        guard let baseURL = URL(string: configuration.endpoint) else {
            throw AIError.invalidConfiguration("The local endpoint is invalid.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api").appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = path == "chat" ? configuration.timeoutSeconds : min(configuration.timeoutSeconds, 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard (request.httpBody?.count ?? 0) <= 256 * 1024 else { throw AIError.inputTooLong }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let transport = Self.transportConfiguration(timeout: request.timeoutInterval, protocolClasses: protocolClasses)
        let session = URLSession(configuration: transport, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw AIError.invalidResponse("The local runtime returned an unexpected response.")
            }
            diagnostic("\(path): HTTP \(http.statusCode)")
            // Never surface arbitrary server error bodies: they may contain source mail or prompts.
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 404 { throw AIError.modelUnavailable }
                if http.statusCode == 408 || http.statusCode == 504 { throw AIError.timedOut }
                if http.statusCode == 400 || http.statusCode == 422 {
                    throw AIError.invalidResponse("The model rejected the structured request. Try another installed model or retry.")
                }
                if (300...399).contains(http.statusCode) {
                    throw AIError.invalidResponse("Redirects from the local runtime are not allowed.")
                }
                throw AIError.runtimeUnavailable
            }
            let maximumResponseSize = 2 * 1024 * 1024
            guard response.expectedContentLength <= maximumResponseSize else {
                throw AIError.invalidResponse("The local runtime response exceeded the size limit.")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseSize else {
                    throw AIError.invalidResponse("The local runtime response exceeded the size limit.")
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw AIError.invalidResponse("The local runtime returned invalid structured data.") }
        } catch {
            let underlying = error as NSError
            diagnostic("\(path): \(underlying.domain) code \(underlying.code)")
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut { throw AIError.timedOut }
            if let aiError = error as? AIError { throw aiError }
            throw AIError.runtimeUnavailable
        }
    }

    private func diagnostic(_ message: String) {
        #if DEBUG
        // Opt-in developer diagnostics contain only endpoint paths and numeric
        // status/error codes, never headers, source text, model output or userInfo.
        if ProcessInfo.processInfo.environment["FLORA_AI_TRANSPORT_DIAGNOSTICS"] == "1" {
            FileHandle.standardError.write(Data("Local AI transport: \(message)\n".utf8))
        }
        #endif
    }

    static func transportConfiguration(timeout: Double, protocolClasses: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        // An empty/default setting can inherit system proxy discovery. Disable each mode explicitly.
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                    "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        return configuration
    }

    private func supportsLocalSelector(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let components = fields.compactMap { Int($0) }
        guard components.count == 3 else { return false }
        return components[0] > 0 || (components[0] == 0 && components[1] >= 34)
    }

    private func validDigest(_ value: String) -> Bool {
        let digest = value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct VersionResponse: Decodable { let version: String }
private struct TagsResponse: Decodable { let models: [InstalledModel] }
private struct ModelDetails: Decodable { let format: String? }
private struct InstalledModel: Decodable {
    let name: String
    let model: String?
    let digest: String
    let size: Int64
    let details: ModelDetails?
    let remoteHost: String?
    let remoteModel: String?
    enum CodingKeys: String, CodingKey {
        case name, model, digest, size, details
        case remoteHost = "remote_host", remoteModel = "remote_model"
    }
}
private struct ShowResponse: Decodable {
    let details: ModelDetails?
    let capabilities: [String]?
    let remoteHost: String?
    let remoteModel: String?
    enum CodingKeys: String, CodingKey {
        case details, capabilities
        case remoteHost = "remote_host", remoteModel = "remote_model"
    }
}
private struct ChatResponse: Decodable {
    let model: String
    let message: ChatMessage
    let done: Bool
    let doneReason: String?
    let remoteHost: String?
    let remoteModel: String?
    enum CodingKeys: String, CodingKey {
        case model, message, done
        case doneReason = "done_reason", remoteHost = "remote_host", remoteModel = "remote_model"
    }
}
private struct ChatMessage: Decodable {
    let role: String
    let content: String
    let toolCalls: [IgnoredToolCall]?
    enum CodingKeys: String, CodingKey { case role, content; case toolCalls = "tool_calls" }
}
private struct IgnoredToolCall: Decodable {}
