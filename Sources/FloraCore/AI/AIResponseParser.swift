import Foundation
import CoreFoundation

/// A strict boundary between model-generated JSON and trusted domain values.
/// A quote is verified against exactly the context supplied to inference; this
/// validates provenance, but does not establish semantic truth of a paraphrase.
enum AIResponseParser {
    static func summary(_ content: String, messageID: UUID, sourceBody: String, provider: String) throws -> MessageSummary {
        let root = try object(content, keys: ["overview", "facts"])
        let overview = try text(root["overview"], name: "overview", max: 1_200)
        let values = try list(root["facts"], name: "facts", max: 5)
        let facts = try values.map { value -> ExtractedFact in
            let object = try fields(value, keys: ["text", "sourceQuote"])
            return ExtractedFact(text: try text(object["text"], name: "fact", max: 1_000), sourceMessageID: messageID,
                                 sourceQuote: try quote(object["sourceQuote"], in: sourceBody))
        }
        return MessageSummary(messageID: messageID, headline: overview, facts: facts, provider: provider)
    }

    static func classification(_ content: String, messageID: UUID, categories: [MailCategory], provider: String) throws -> ClassificationSuggestion? {
        let root = try object(content, keys: ["category", "confidence", "reason"])
        let name = try text(root["category"], name: "category", max: 100)
        let reason = try text(root["reason"], name: "reason", max: 1_000)
        guard let number = root["confidence"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              (0...1).contains(number.doubleValue) else { throw invalid("Confidence must be a number between 0 and 1.") }
        if name == "none" { return nil }
        guard let id = UUID(uuidString: name), categories.contains(where: { $0.id == id }) else {
            throw invalid("The predicted category is not in your available categories.")
        }
        return ClassificationSuggestion(messageID: messageID, categoryID: id,
                                        explanation: "\(provider) · \(reason)", confidence: number.doubleValue)
    }

    static func actions(_ content: String, messageID: UUID, sourceBody: String) throws -> [ActionItem] {
        let root = try object(content, keys: ["actions"])
        return try list(root["actions"], name: "actions", max: 3).map { value in
            let object = try fields(value, keys: ["title", "sourceQuote"])
            return ActionItem(messageID: messageID, title: try text(object["title"], name: "action title", max: 500),
                              sourceQuote: try quote(object["sourceQuote"], in: sourceBody))
        }
    }

    static func replies(_ content: String) throws -> [SuggestedReply] {
        let root = try object(content, keys: ["replies"])
        let values = try list(root["replies"], name: "replies", max: 3).map { try text($0, name: "reply", max: 1_500) }
        guard Set(values).count == values.count else { throw invalid("Reply suggestions must be distinct.") }
        return values.map { SuggestedReply(text: $0) }
    }

    static func writing(_ content: String) throws -> String {
        try text(object(content, keys: ["text"])["text"], name: "revised draft", max: 24_000)
    }

    static func expansion(_ content: String, query: String, provider: String) throws -> SearchQueryExpansion {
        let root = try object(content, keys: ["terms"])
        let terms = try list(root["terms"], name: "search terms", max: 24).map { value in
            let group = try fields(value, keys: ["term", "alternatives"])
            return SearchExpansionTerm(term: try text(group["term"], name: "query term", max: 80),
                                       alternatives: try list(group["alternatives"], name: "alternatives", max: 5).map {
                try text($0, name: "alternative", max: 80)
            })
        }
        let result = SearchQueryExpansion(terms: terms, provider: provider, mode: .semanticExpansion)
        try MailIntelligenceService.validate(result, query: query)
        return result
    }

    static func answer(_ content: String, request: AssistantRequest, provider: String) throws -> AssistantAnswer {
        let root = try object(content, keys: ["claims"])
        let claims = try list(root["claims"], name: "claims", max: 6).map { value in
            let claim = try fields(value, keys: ["text", "citations"])
            let citations = try list(claim["citations"], name: "citations", max: 3).map { value in
                let citation = try fields(value, keys: ["messageID", "quote"])
                guard let id = UUID(uuidString: try text(citation["messageID"], name: "message ID", max: 36)) else {
                    throw invalid("An assistant citation has an invalid message ID.")
                }
                return AssistantCitation(messageID: id, quote: try text(citation["quote"], name: "quote", max: 600))
            }
            return AssistantClaim(text: try text(claim["text"], name: "claim", max: 1_500), citations: citations)
        }
        let result = AssistantAnswer(claims: claims, provider: provider)
        try MailIntelligenceService.validate(result, request: request)
        return result
    }

    private static func object(_ content: String, keys: Set<String>) throws -> [String: Any] {
        guard content.utf8.count <= 150_000 else { throw invalid("The response exceeds the allowed size.") }
        let data = Data(content.utf8)
        do { return try fields(JSONSerialization.jsonObject(with: data), keys: keys) }
        catch let error as AIError { throw error }
        catch { throw invalid("Expected a complete JSON object matching this task's schema.") }
    }

    private static func fields(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else {
            throw invalid("The response contains missing or unexpected fields.")
        }
        return object
    }

    private static func list(_ value: Any?, name: String, max: Int) throws -> [Any] {
        guard let values = value as? [Any], values.count <= max else { throw invalid("Invalid \(name) list.") }
        return values
    }

    private static func text(_ value: Any?, name: String, max: Int) throws -> String {
        guard let text = value as? String, text.count <= max, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalid("Invalid \(name) text.")
        }
        return text
    }

    private static func quote(_ value: Any?, in source: String) throws -> String {
        let quote = try text(value, name: "source quote", max: 2_000)
        guard source.contains(quote) else { throw invalid("A cited quote is absent from the provided message content.") }
        return quote
    }

    private static func invalid(_ reason: String) -> AIError { .invalidResponse(reason) }
}
