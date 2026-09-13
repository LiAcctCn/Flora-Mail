import Foundation

/// AI returns information and drafts only. Mail mutations belong to ActionExecutor.
public protocol AIProvider: Sendable {
    /// Identity includes the concrete model revision when one is available.
    func cacheIdentity() async throws -> String
    func summarize(_ message: MailMessage) async throws -> MessageSummary
    func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion?
    func extractActions(_ message: MailMessage) async throws -> [ActionItem]
    func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply]
    func rewrite(_ text: String, tool: WritingTool) async throws -> String
    func rewrite(_ text: String, tool: WritingTool, context: MailMessage?) async throws -> String
    func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID]
    func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion
    func answer(_ request: AssistantRequest) async throws -> AssistantAnswer
}

public extension AIProvider {
    func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion {
        try Task.checkCancellation()
        throw AIError.unsupportedCapability
    }
    func answer(_ request: AssistantRequest) async throws -> AssistantAnswer {
        try Task.checkCancellation()
        throw AIError.unsupportedCapability
    }
    func rewrite(_ text: String, tool: WritingTool, context: MailMessage?) async throws -> String {
        try await rewrite(text, tool: tool)
    }
    func cacheIdentity() async throws -> String {
        try Task.checkCancellation()
        return String(reflecting: Self.self)
    }
}

public enum AIError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case runtimeUnavailable
    case modelUnavailable
    case unsupportedRuntime
    case unsupportedCapability
    case inputTooLong
    case queryTooLong
    case emptyText
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            "Local AI configuration is invalid: \(reason)"
        case .invalidResponse(let reason):
            "The local model returned an invalid response: \(reason) Your original content is unchanged."
        case .runtimeUnavailable:
            "Local AI is unavailable. Start the configured local runtime and test the connection in Settings. Mail remains usable. No mail was sent to an external service."
        case .modelUnavailable:
            "The selected local model is unavailable. Choose an installed model in Settings. Mail remains usable. No mail was sent to an external service."
        case .unsupportedRuntime:
            "Use Ollama 0.34 or later for enforced local-only model requests, then test the connection in Settings."
        case .unsupportedCapability:
            "This AI capability is not supported by the selected local model or provider. Normal mail controls remain available."
        case .inputTooLong:
            "This content exceeds the Local AI input limit. Writing tools accept drafts of at most 12,000 characters. Your original content is unchanged."
        case .queryTooLong:
            "Search and assistant queries must be at most 500 characters. Shorten the question and try again."
        case .emptyText:
            "Add some text before using a writing tool."
        case .timedOut:
            "The local model took too long. Your original message is still available."
        }
    }
}
