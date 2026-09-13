import Foundation

/// Real local inference through a replaceable transport. This type has no mail
/// executor, repository or external-service capabilities and has no fallback.
public struct LocalAIProvider: AIProvider {
    public let configuration: AIModelConfiguration
    private let client: any LocalModelClient

    public init(configuration: AIModelConfiguration = AIModelConfiguration(), client: any LocalModelClient = OllamaLocalModelClient()) {
        self.configuration = configuration
        self.client = client
    }

    public func cacheIdentity() async throws -> String {
        try Task.checkCancellation()
        let identity = try await client.inspect(configuration)
        try Task.checkCancellation()
        return identity.cacheKey
    }

    public func summarize(_ message: MailMessage) async throws -> MessageSummary {
        let body = context(for: message)
        let output = try await generate(AIPromptLibrary.summary(subject: message.subject, body: body))
        return try AIResponseParser.summary(output.content, messageID: message.id, sourceBody: body,
                                            provider: label(output.identity, truncated: body.count < message.body.count))
    }

    public func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion? {
        try Task.checkCancellation()
        guard !categories.isEmpty else { return nil }
        let body = context(for: message)
        let output = try await generate(AIPromptLibrary.classification(subject: message.subject, body: body, categories: categories))
        return try AIResponseParser.classification(output.content, messageID: message.id, categories: categories,
                                                   provider: label(output.identity, truncated: body.count < message.body.count))
    }

    public func extractActions(_ message: MailMessage) async throws -> [ActionItem] {
        let body = context(for: message)
        let output = try await generate(AIPromptLibrary.actions(subject: message.subject, body: body))
        return try AIResponseParser.actions(output.content, messageID: message.id, sourceBody: body)
    }

    public func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply] {
        let output = try await generate(AIPromptLibrary.replies(subject: message.subject, body: context(for: message)))
        return try AIResponseParser.replies(output.content)
    }

    public func rewrite(_ text: String, tool: WritingTool) async throws -> String {
        try await rewrite(text, tool: tool, context: nil)
    }

    public func rewrite(_ text: String, tool: WritingTool, context: MailMessage?) async throws -> String {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyText }
        guard text.count <= AIPromptLibrary.messageCharacterLimit else { throw AIError.inputTooLong }
        let output = try await generate(AIPromptLibrary.writing(text, tool: tool, context: context))
        return try AIResponseParser.writing(output.content)
    }

    public func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID] {
        let result = try await MailIntelligenceService(provider: self).search(
            query: query, messages: messages, accountIDs: Set(messages.map(\.accountID)))
        return result.messageIDs
    }

    public func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion {
        let query = try MailIntelligenceService.validatedQuery(query)
        let output = try await generate(AIRetrievalPromptLibrary.expansion(query))
        return try AIResponseParser.expansion(output.content, query: query,
                                               provider: label(output.identity, truncated: false))
    }

    public func answer(_ request: AssistantRequest) async throws -> AssistantAnswer {
        try MailIntelligenceService.validate(request)
        let output = try await generate(AIRetrievalPromptLibrary.answer(request))
        return try AIResponseParser.answer(output.content, request: request,
                                          provider: label(output.identity, truncated: false))
    }

    private func context(for message: MailMessage) -> String {
        String(message.body.prefix(AIPromptLibrary.messageCharacterLimit))
    }

    private func generate(_ request: LocalModelRequest) async throws -> LocalModelOutput {
        try Task.checkCancellation()
        let output = try await client.generate(request, configuration: configuration)
        // Defend against clients that complete after a cancellation request.
        try Task.checkCancellation()
        return output
    }

    private func label(_ identity: LocalModelIdentity, truncated: Bool) -> String {
        "Local AI · \(identity.model)" + (truncated ? " · First 12,000 body characters only" : "")
    }
}
