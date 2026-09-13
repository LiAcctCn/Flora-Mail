import Foundation

/// Deterministic, on-device heuristics for demonstrating interactions without a model.
/// This is a mock, not a language model or an embedding-based search engine.
public struct MockAIProvider: AIProvider {
    public init() {}

    public func summarize(_ message: MailMessage) async throws -> MessageSummary {
        try Task.checkCancellation()
        let sentences = Self.sourceSentences(message.body)
        let ranked = sentences.enumerated().sorted { lhs, rhs in
            let left = Self.importance(lhs.element)
            let right = Self.importance(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        let selected = ranked.prefix(3).sorted { $0.offset < $1.offset }.map(\.element)
        let facts = selected.map {
            ExtractedFact(text: $0, sourceMessageID: message.id, sourceQuote: $0)
        }
        try Task.checkCancellation()
        return MessageSummary(messageID: message.id, headline: message.subject, facts: facts, provider: "Mock AI · extractive demo")
    }

    public func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion? {
        try Task.checkCancellation()
        let words = Self.words(message.subject + " " + message.body + " " + message.from.name + " " + message.from.email)
        let candidates = categories.compactMap { category -> (MailCategory, [String], Int)? in
            let keywords = Self.categoryKeywords[category.name.lowercased()] ?? Array(Self.words(category.name))
            let matched = keywords.filter { words.contains($0) }
            guard !matched.isEmpty else { return nil }
            // Subject matches help distinguish a research proposal from generic project mail.
            let subjectWords = Self.words(message.subject)
            let score = matched.count + matched.filter { subjectWords.contains($0) }.count * 2
            return (category, matched, score)
        }
        let best = candidates.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0.name < rhs.0.name : lhs.2 > rhs.2
        }.first
        try Task.checkCancellation()
        guard let (category, matched, score) = best else { return nil }
        let evidence = matched.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
        return ClassificationSuggestion(
            messageID: message.id,
            categoryID: category.id,
            explanation: "Mock AI matched \(evidence) with your \(category.name) category. Accepting saves a local category only; no server label is changed.",
            confidence: min(0.9, 0.55 + Double(score) * 0.05)
        )
    }

    public func extractActions(_ message: MailMessage) async throws -> [ActionItem] {
        try Task.checkCancellation()
        let sentences = Self.sourceSentences(message.body)
        let actions = sentences.filter(Self.isRequest).prefix(3).map {
            ActionItem(messageID: message.id, title: $0, sourceQuote: $0)
        }
        try Task.checkCancellation()
        return actions
    }

    public func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply] {
        try Task.checkCancellation()
        let text = (message.subject + " " + message.body).lowercased()
        let responses: [String]
        if text.contains("meeting") || text.contains("availability") {
            responses = [
                "Thanks for the update. I’m available at the proposed time.",
                "Thanks for checking. Could we find another time?",
                "I’ll check my calendar and confirm my availability."
            ]
        } else if text.contains("review") || text.contains("feedback") {
            responses = [
                "Thanks for sharing this. I’ll review it and send my feedback.",
                "I’ve received this. Could you clarify which areas need the most attention?"
            ]
        } else {
            responses = ["Thanks for the update.", "Thanks for letting me know. I’ll review the details and get back to you."]
        }
        try Task.checkCancellation()
        return responses.map { SuggestedReply(text: $0) }
    }

    public func rewrite(_ text: String, tool: WritingTool) async throws -> String {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyText }
        var revised = Self.proofread(text)
        switch tool {
        case .proofread, .rewrite:
            break
        case .professional:
            revised = Self.replace(revised, pattern: "(?m)^Hi\\b", replacement: "Hello")
            revised = Self.replace(revised, pattern: "(?i)\\bthanks\\b", replacement: "Thank you")
            revised = Self.replace(revised, pattern: "(?i)\\bI'm\\b", replacement: "I am")
            revised = Self.replace(revised, pattern: "(?i)\\bI'll\\b", replacement: "I will")
            revised = Self.replace(revised, pattern: "(?i)\\bcan't\\b", replacement: "cannot")
        case .friendly:
            revised = Self.replace(revised, pattern: "(?m)^(Dear|Hello)\\b", replacement: "Hi")
            revised = Self.replace(revised, pattern: "(?i)\\bThank you\\b", replacement: "Thanks")
            revised = Self.replace(revised, pattern: "\\bI am\\b", replacement: "I’m")
            revised = Self.replace(revised, pattern: "\\bI will\\b", replacement: "I’ll")
        case .concise:
            revised = Self.replace(revised, pattern: "(?i)\\bI (just )?wanted to (let you know that|say that|mention that)\\s*", replacement: "")
            revised = Self.replace(revised, pattern: "(?i)\\b(in order to)\\b", replacement: "to")
            revised = Self.replace(revised, pattern: "(?i)\\bat this point in time\\b", replacement: "now")
            revised = Self.replace(revised, pattern: "(?i)\\b(very|really|basically|actually) +", replacement: "")
        }
        try Task.checkCancellation()
        return revised.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID] {
        try Task.checkCancellation()
        let queryWords = Self.words(query).subtracting(Self.searchStopWords)
        guard !queryWords.isEmpty else { return [] }
        // Small, disclosed synonym groups emulate retrieval; they do not generate answers.
        let queryGroups = queryWords.map { word -> Set<String> in
            Self.synonymGroups.first { $0.contains(word) } ?? [word]
        }
        var matches: [(MailMessage, Int)] = []
        for message in messages {
            try Task.checkCancellation()
            let content = Self.words(message.subject + " " + message.body + " " + message.from.name + " " + message.from.email)
            let matchingGroups = queryGroups.filter { !$0.isDisjoint(with: content) }.count
            // Require every meaningful query term so unrelated messages do not appear as evidence.
            if matchingGroups == queryGroups.count { matches.append((message, matchingGroups)) }
        }
        try Task.checkCancellation()
        return matches.sorted { $0.0.date > $1.0.date }.map { $0.0.id }
    }

    public func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion {
        try Task.checkCancellation()
        _ = try MailIntelligenceService.validatedQuery(query)
        let groups = MailIntelligenceService.queryTerms(query).prefix(24).compactMap { term -> SearchExpansionTerm? in
            guard let group = Self.synonymGroups.first(where: { $0.contains(term) }) else { return nil }
            return SearchExpansionTerm(term: term, alternatives: Array(group.subtracting([term])).sorted())
        }
        return SearchQueryExpansion(terms: groups, provider: "Demo AI · fixed synonyms", mode: .demoSemantic)
    }

    public func answer(_ request: AssistantRequest) async throws -> AssistantAnswer {
        try Task.checkCancellation()
        try MailIntelligenceService.validate(request)
        let claims = request.sources.prefix(3).map { source in
            let quote = String(source.excerpt.prefix(600))
            return AssistantClaim(text: quote, citations: [AssistantCitation(messageID: source.messageID, quote: quote)])
        }
        try Task.checkCancellation()
        return AssistantAnswer(claims: claims, provider: "Demo AI · extractive assistant")
    }

    private static func proofread(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrections = [
            ("(?i)\\bcan meeting\\b", "can meet"),
            ("(?i)\\bcan attending\\b", "can attend"),
            ("(?i)\\bi am agree\\b", "I agree"),
            ("(?i)\\brecieve\\b", "receive"),
            ("(?i)\\bteh\\b", "the"),
            ("(?i)\\btomm?orow\\b", "tomorrow"),
            ("\\bi\\b", "I"),
            ("(?i)\\bYes I\\b", "Yes, I"),
            ("[ \\t]{2,}", " ")
        ]
        for (pattern, replacement) in corrections {
            result = replace(result, pattern: pattern, replacement: replacement)
        }
        if let last = result.last, last.isLetter || last.isNumber { result += "." }
        return result
    }

    private static func replace(_ text: String, pattern: String, replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func sourceSentences(_ body: String) -> [String] {
        var sentences: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:") { break }
            if trimmed.isEmpty || trimmed.hasPrefix(">") { continue }
            let lower = trimmed.lowercased()
            if ["hi ", "hello ", "dear "].contains(where: lower.hasPrefix) && trimmed.hasSuffix(",") { continue }
            if ["best,", "thanks,", "regards,", "best regards,", "cheers,"].contains(lower) { break }
            trimmed.enumerateSubstrings(in: trimmed.startIndex..<trimmed.endIndex, options: .bySentences) { sentence, _, _, _ in
                if let sentence {
                    let exact = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !exact.isEmpty { sentences.append(exact) }
                }
            }
        }
        return sentences
    }

    private static func importance(_ text: String) -> Int {
        let lower = text.lowercased()
        let keywords = ["deadline", "moved", "changed", "please", "confirm", "required", "due", "cancelled", "refund", "arrives"]
        return keywords.filter { lower.contains($0) }.count * 3 + (isRequest(text) ? 4 : 0)
    }

    private static func isRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("no action") || lower.contains("no reply") || lower.contains("do not reply") { return false }
        return ["please ", "can you ", "could you ", "please confirm", "action required", "reply by", "submit "].contains { lower.contains($0) }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static let categoryKeywords: [String: [String]] = [
        "school": ["assignment", "professor", "lecture", "course", "physics", "homework", "class", "campus", "seminar"],
        "work": ["project", "client", "design", "sprint", "launch", "team", "review", "roadmap"],
        "research": ["research", "experiment", "manuscript", "paper", "participants", "study", "proposal"],
        "finance": ["invoice", "payment", "statement", "bank", "receipt", "billing", "balance"],
        "shopping": ["order", "shipped", "delivery", "package", "purchase", "store"],
        "travel": ["flight", "hotel", "reservation", "itinerary", "boarding", "train", "booking"],
        "promotion": ["sale", "discount", "offer", "newsletter", "unsubscribe"],
        "other": []
    ]
    private static let searchStopWords: Set<String> = ["a", "an", "the", "what", "which", "who", "show", "find", "me", "my", "mail", "email", "emails", "message", "messages", "about", "from", "to", "of", "for", "and", "is", "are", "did", "say", "said", "with"]
    private static let synonymGroups: [Set<String>] = [
        ["meeting", "meet", "meetings", "appointment", "availability"],
        ["deadline", "deadlines", "due", "submission", "submit"],
        ["reply", "replies", "respond", "response", "confirm"],
        ["change", "changed", "moved", "update", "updated"],
        ["purchase", "order", "shopping"],
        ["travel", "flight", "hotel", "train"],
        ["finance", "payment", "invoice", "bank"]
    ]
}
