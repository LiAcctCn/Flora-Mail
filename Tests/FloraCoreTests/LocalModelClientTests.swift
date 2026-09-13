import Foundation
import Testing
@testable import FloraCore

@Suite(.serialized)
struct LocalModelClientTests {
    private let digest = String(repeating: "a", count: 64)

    private var request: LocalModelRequest {
        LocalModelRequest(system: "Return JSON only.", prompt: "Please confirm tomorrow's meeting.",
                          schemaJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
                          maxTokens: 256)
    }

    private func client(overrides: [String: StubResponse] = [:]) -> OllamaLocalModelClient {
        var responses: [String: StubResponse] = [
            "/api/version": .json(#"{"version":"0.34.0"}"#),
            "/api/tags": .json("""
                {"models":[{"name":"gemma3:4b","model":"gemma3:4b","digest":"\(digest)","size":12345,"details":{"format":"gguf"}}]}
                """),
            "/api/show": .json(#"{"details":{"format":"gguf"},"capabilities":["completion"]}"#),
            "/api/chat": .json(#"{"model":"gemma3:4b:local","message":{"role":"assistant","content":"{\"text\":\"Confirm availability.\"}"},"done":true,"done_reason":"stop"}"#)
        ]
        responses.merge(overrides) { _, new in new }
        LocalStubProtocol.state.reset(responses)
        return OllamaLocalModelClient(protocolClasses: [LocalStubProtocol.self])
    }

    @Test func configurationRestrictsNetworkingToCanonicalLoopback() throws {
        let configuration = try AIModelConfiguration(endpoint: " HTTP://localhost:11434/ ", model: "gemma3:4b:local").validated()
        #expect(configuration.endpoint == "http://127.0.0.1:11434")
        #expect(configuration.model == "gemma3:4b")
        #expect(try AIModelConfiguration(endpoint: "http://[::1]:11434").validated().endpoint == "http://[::1]:11434")
        for endpoint in ["https://ollama.com", "http://192.168.1.2:11434", "http://127.0.0.1.evil.test", "http://user@127.0.0.1",
                         "http://127.0.0.1/api", "http://127.0.0.1?url=remote", "http://127.0.0.1#fragment", "http://127%2E0%2E0%2E1",
                         "http://2130706433:11434", "http://127.0.0.1:0", "http://[::ffff:127.0.0.1]:11434"] {
            #expect(throws: AIError.self) { try AIModelConfiguration(endpoint: endpoint).validated() }
        }
        for model in ["", " ", "gemma3:cloud", "gemma3:4b-cloud", "gemma3:4b:cloud:local", "gemma3:local:local",
                      "https://example.test/model", "gemma3:4b\ncloud", String(repeating: "a", count: 201)] {
            #expect(throws: AIError.self) { try AIModelConfiguration(model: model).validated() }
        }
        for timeout in [Double.nan, .infinity, 0, 4, 181] {
            #expect(throws: AIError.self) { try AIModelConfiguration(timeoutSeconds: timeout).validated() }
        }
        let encoded = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(AIModelConfiguration.self, from: encoded) == configuration)
    }

    @Test func transportDoesNotUseSystemProxiesOrPersistentWebState() {
        let configuration = OllamaLocalModelClient.transportConfiguration(timeout: 60)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(!configuration.waitsForConnectivity)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForResource == 60)
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            #expect(configuration.connectionProxyDictionary?[key] as? Int == 0)
        }
    }

    @Test func generationVerifiesLocalModelBeforeSendingOnlyTaskContent() async throws {
        let client = client()
        let output = try await client.generate(request, configuration: AIModelConfiguration())
        #expect(output.content == #"{"text":"Confirm availability."}"#)
        #expect(output.identity == LocalModelIdentity(runtimeVersion: "0.34.0", model: "gemma3:4b", digest: digest))
        #expect(output.identity.cacheKey.contains(digest))
        let requests = LocalStubProtocol.state.requests
        #expect(requests.map { $0.url.path } == ["/api/version", "/api/tags", "/api/show", "/api/chat"])
        #expect(requests.allSatisfy { $0.url.host == "127.0.0.1" && $0.cookie == nil && $0.authorization == nil })
        #expect(requests.prefix(2).allSatisfy { $0.body == nil && $0.method == "GET" })
        let showBody = try #require(requests[2].body)
        let show = try #require(JSONSerialization.jsonObject(with: showBody) as? [String: String])
        #expect(show == ["model": "gemma3:4b:local"])
        let chatBody = try #require(requests[3].body)
        let chat = try #require(JSONSerialization.jsonObject(with: chatBody) as? [String: Any])
        #expect(chat["model"] as? String == "gemma3:4b:local")
        #expect(chat["stream"] as? Bool == false)
        #expect(chat["think"] as? Bool == false)
        #expect(chat["truncate"] as? Bool == false)
        #expect(chat["shift"] as? Bool == false)
        #expect(chat["format"] is [String: Any])
        #expect(chat["tools"] == nil)
        let messages = try #require(chat["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": request.system], ["role": "user", "content": request.prompt]])
        #expect((chat["options"] as? [String: Int])?["num_predict"] == 256)
    }

    @Test func cloudAliasesAreRejectedBeforeAnyMailIsSent() async throws {
        let remoteTags = """
            {"models":[{"name":"gemma3:4b","digest":"\(digest)","size":12345,"details":{"format":"gguf"},"remote_host":"https://ollama.com","remote_model":"larger-model"}]}
            """
        for override in [["/api/tags": StubResponse.json(remoteTags)],
                         ["/api/show": .json(#"{"details":{"format":"gguf"},"capabilities":["completion"],"remote_host":"https://ollama.com"}"#)]] {
            let client = client(overrides: override)
            await #expect(throws: AIError.self) { try await client.generate(request, configuration: AIModelConfiguration()) }
            #expect(!LocalStubProtocol.state.requests.contains { $0.url.path == "/api/chat" })
        }
        let client = client()
        await #expect(throws: AIError.self) { try await client.generate(request, configuration: AIModelConfiguration(model: "any-model:cloud")) }
        #expect(LocalStubProtocol.state.requests.isEmpty)
    }

    @Test func unavailableOrUnsupportedModelsNeverTriggerGeneration() async throws {
        let scenarios: [([String: StubResponse], AIError)] = [
            (["/api/version": .json(#"{"version":"0.33.0"}"#)], .unsupportedRuntime),
            (["/api/version": .json(#"{"version":"garbage"}"#)], .unsupportedRuntime),
            (["/api/tags": .json(#"{"models":[]}"#)], .modelUnavailable),
            (["/api/show": .json(#"{"details":{"format":"gguf"},"capabilities":["embedding"]}"#)], .unsupportedCapability),
            (["/api/show": StubResponse(status: 404, body: Data("private server error".utf8))], .modelUnavailable)
        ]
        for (overrides, expected) in scenarios {
            let client = client(overrides: overrides)
            await #expect(throws: expected) { try await client.generate(request, configuration: AIModelConfiguration()) }
            #expect(!LocalStubProtocol.state.requests.contains { $0.url.path == "/api/chat" })
        }
    }

    @Test func modelNeedsDigestAndLocalFormatMetadata() async {
        for json in [#"{"models":[{"name":"gemma3:4b","digest":"","size":12345,"details":{"format":"gguf"}}]}"#,
                     #"{"models":[{"name":"gemma3:4b","digest":"not-a-digest","size":12345,"details":{"format":"gguf"}}]}"#,
                     "{\"models\":[{\"name\":\"gemma3:4b\",\"digest\":\"\(digest)\",\"size\":12345}]}"] {
            let client = client(overrides: ["/api/tags": .json(json)])
            await #expect(throws: AIError.self) { try await client.generate(request, configuration: AIModelConfiguration()) }
            #expect(!LocalStubProtocol.state.requests.contains { $0.url.path == "/api/chat" })
        }
    }

    @Test func malformedIncompleteAndUnexpectedOutputFailsGracefully() async {
        for json in ["not json", #"{"message":null}"#,
                     #"{"model":"gemma3:4b:local","message":{"role":"assistant","content":"{}"},"done":false,"done_reason":"stop"}"#,
                     #"{"model":"gemma3:4b:local","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"length"}"#,
                     #"{"model":"different","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"stop"}"#,
                     #"{"model":"gemma3:4b:local","message":{"role":"assistant","content":"{}","tool_calls":[{}]},"done":true,"done_reason":"stop"}"#,
                     #"{"model":"gemma3:4b:local","message":{"role":"assistant","content":"{}"},"done":true,"done_reason":"stop","remote_host":"https://ollama.com"}"#] {
            let client = client(overrides: ["/api/chat": .json(json)])
            await #expect(throws: AIError.self) { try await client.generate(request, configuration: AIModelConfiguration()) }
        }
    }

    @Test func transportErrorsAreTypedAndDoNotExposeSourceContent() async {
        let rejectedRequest = AIError.invalidResponse("The model rejected the structured request. Try another installed model or retry.")
        for (response, expected) in [(StubResponse(error: .cannotConnectToHost), AIError.runtimeUnavailable),
                                     (StubResponse(error: .timedOut), AIError.timedOut),
                                     (StubResponse(status: 400, body: Data("SECRET MAIL CONTENT".utf8)), rejectedRequest),
                                     (StubResponse(status: 422, body: Data("SECRET MAIL CONTENT".utf8)), rejectedRequest),
                                     (StubResponse(status: 503, body: Data("SECRET MAIL CONTENT".utf8)), AIError.runtimeUnavailable)] {
            let client = client(overrides: ["/api/chat": response])
            do {
                _ = try await client.generate(request, configuration: AIModelConfiguration())
                Issue.record("Transport failure should not produce an AI result")
            } catch {
                #expect(error as? AIError == expected)
                #expect(!error.localizedDescription.contains("SECRET MAIL CONTENT"))
            }
        }
    }

    @Test func redirectsAreNotFollowed() async {
        let client = client(overrides: ["/api/chat": StubResponse(status: 307, headers: ["Location": "https://example.test/leak"], redirect: true)])
        await #expect(throws: AIError.self) { try await client.generate(request, configuration: AIModelConfiguration()) }
        #expect(LocalStubProtocol.state.requests.allSatisfy { $0.url.host == "127.0.0.1" })
    }

    @Test func inputAndOutputBoundsFailWithoutTruncatingOrGuessing() async {
        let client = client()
        let oversized = LocalModelRequest(system: "", prompt: String(repeating: "x", count: 96 * 1024 + 1), schemaJSON: request.schemaJSON, maxTokens: 100)
        await #expect(throws: AIError.inputTooLong) { try await client.generate(oversized, configuration: AIModelConfiguration()) }
        #expect(LocalStubProtocol.state.requests.isEmpty)
        let invalidSchema = LocalModelRequest(system: "", prompt: "mail", schemaJSON: "arbitrary prose", maxTokens: 100)
        await #expect(throws: AIError.self) { try await client.generate(invalidSchema, configuration: AIModelConfiguration()) }
        #expect(LocalStubProtocol.state.requests.isEmpty)
        let boundedClient = self.client(overrides: ["/api/chat": StubResponse(body: Data(repeating: 65, count: 2 * 1024 * 1024 + 1))])
        await #expect(throws: AIError.self) { try await boundedClient.generate(request, configuration: AIModelConfiguration()) }
    }

    @Test func cancellationStopsAnInFlightGeneration() async throws {
        let client = client(overrides: ["/api/chat": StubResponse(pending: true)])
        let request = request
        let operation = Task { try await client.generate(request, configuration: AIModelConfiguration()) }
        for _ in 0..<200 {
            if LocalStubProtocol.state.requests.contains(where: { $0.url.path == "/api/chat" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(LocalStubProtocol.state.requests.contains { $0.url.path == "/api/chat" })
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
}

private struct StubResponse: Sendable {
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]
    var error: URLError.Code?
    var pending = false
    var redirect = false
    static func json(_ value: String) -> Self { Self(body: Data(value.utf8), headers: ["Content-Type": "application/json"]) }
}

private struct RecordedRequest: Sendable {
    let url: URL
    let method: String?
    let body: Data?
    let cookie: String?
    let authorization: String?
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: StubResponse] = [:]
    private var recorded: [RecordedRequest] = []
    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func reset(_ responses: [String: StubResponse]) {
        lock.withLock { self.responses = responses; recorded = [] }
    }

    func record(_ request: URLRequest) -> StubResponse {
        lock.withLock {
            guard let url = request.url else { return StubResponse(error: .badURL) }
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                body = data
            }
            recorded.append(RecordedRequest(url: url, method: request.httpMethod, body: body,
                                            cookie: request.value(forHTTPHeaderField: "Cookie"),
                                            authorization: request.value(forHTTPHeaderField: "Authorization")))
            return responses[url.path] ?? StubResponse(error: .unsupportedURL)
        }
    }
}

private final class LocalStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.record(request)
        if stub.pending { return }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if stub.redirect, let location = stub.headers["Location"], let redirectURL = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
