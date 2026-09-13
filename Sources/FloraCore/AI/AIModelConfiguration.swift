import Foundation

public enum LocalRuntime: String, Codable, CaseIterable, Sendable {
    case ollama = "Ollama"
}

/// Settings describe a service already installed by the user. Flora never downloads models,
/// starts a runtime, authenticates to a cloud service, or changes the runtime's settings.
public struct AIModelConfiguration: Codable, Equatable, Sendable {
    public var runtime: LocalRuntime
    public var endpoint: String
    public var model: String
    public var timeoutSeconds: Double

    public init(
        runtime: LocalRuntime = .ollama,
        endpoint: String = "http://127.0.0.1:11434",
        model: String = "gemma3:4b",
        timeoutSeconds: Double = 60
    ) {
        self.runtime = runtime
        self.endpoint = endpoint
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    public func validated() throws -> AIModelConfiguration {
        guard timeoutSeconds.isFinite, (5...180).contains(timeoutSeconds) else {
            throw AIError.invalidConfiguration("Use a timeout between 5 and 180 seconds.")
        }
        let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawEndpoint.utf8.count <= 200,
              var components = URLComponents(string: rawEndpoint),
              components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              let host = components.host?.lowercased(),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host),
              !rawEndpoint.contains("%"),
              components.port == nil || (1...65535).contains(components.port ?? 0)
        else {
            throw AIError.invalidConfiguration("Use an HTTP endpoint on 127.0.0.1, localhost, or [::1], with an optional port and no other URL components.")
        }
        components.scheme = "http"
        components.host = host == "localhost" ? "127.0.0.1" : host
        components.path = ""
        guard let canonicalEndpoint = components.url?.absoluteString else {
            throw AIError.invalidConfiguration("The local endpoint is invalid.")
        }

        var canonicalModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a user's explicit local suffix; the transport always adds exactly one.
        if canonicalModel.lowercased().hasSuffix(":local") {
            canonicalModel = String(canonicalModel.dropLast(6))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:/")
        guard !canonicalModel.isEmpty, canonicalModel.utf8.count <= 200,
              canonicalModel.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !canonicalModel.hasPrefix("/"), !canonicalModel.hasSuffix("/"),
              !canonicalModel.contains("//"), !canonicalModel.contains(".."),
              !canonicalModel.contains("://"),
              !canonicalModel.lowercased().hasSuffix(":local"),
              !canonicalModel.lowercased().hasSuffix(":cloud"),
              !canonicalModel.lowercased().hasSuffix("-cloud")
        else {
            throw AIError.invalidConfiguration("Choose an installed local model name. Cloud models are not supported.")
        }
        return AIModelConfiguration(runtime: runtime, endpoint: canonicalEndpoint, model: canonicalModel, timeoutSeconds: timeoutSeconds)
    }
}

public struct LocalModelIdentity: Codable, Equatable, Sendable {
    public let runtimeVersion: String
    public let model: String
    public let digest: String

    public init(runtimeVersion: String, model: String, digest: String) {
        self.runtimeVersion = runtimeVersion
        self.model = model
        self.digest = digest
    }

    public var cacheKey: String { "ollama|\(runtimeVersion)|\(model)|\(digest)" }
}

public struct LocalModelRequest: Sendable {
    public let system: String
    public let prompt: String
    public let schemaJSON: String
    public let maxTokens: Int

    public init(system: String, prompt: String, schemaJSON: String, maxTokens: Int) {
        self.system = system
        self.prompt = prompt
        self.schemaJSON = schemaJSON
        self.maxTokens = maxTokens
    }
}

public struct LocalModelOutput: Sendable {
    public let content: String
    public let identity: LocalModelIdentity

    public init(content: String, identity: LocalModelIdentity) {
        self.content = content
        self.identity = identity
    }
}
