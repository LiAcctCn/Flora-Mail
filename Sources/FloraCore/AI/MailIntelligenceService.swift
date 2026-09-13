import Foundation

/// Retrieval and generated reading assistance only. There is deliberately no
/// repository, credential, writer, executor or automation dependency here.
public struct MailIntelligenceService: Sendable {
    public static let queryCharacterLimit = 500
    public static let maximumSources = 6
    public static let excerptCharacterLimit = 1_500
    private let provider: (any AIProvider)?

    public init(provider: (any AIProvider)? = nil) { self.provider = provider }

    public func search(query: String, messages: [MailMessage], accountIDs: Set<UUID>) async throws -> MailSearchResult {
        try Task.checkCancellation()
        let query = try Self.validatedQuery(query)
        let scoped = Self.scopedMessages(messages, accountIDs: accountIDs)
        let terms = Self.queryTerms(query)
        guard !terms.isEmpty, !scoped.isEmpty else { return MailSearchResult(messageIDs: [], mode: .text) }
        guard let provider else { return try Self.textSearch(query: query, messages: scoped, accountIDs: accountIDs) }
        do {
            let expansion = try await provider.expandSearchQuery(query)
            try Task.checkCancellation()
            try Self.validate(expansion, query: query)
            let ids = try Self.rank(scoped, query: query, expansion: expansion)
            try Task.checkCancellation()
            return MailSearchResult(messageIDs: ids, mode: expansion.mode,
                                    expandedTerms: expansion.terms.flatMap(\.alternatives),
                                    notice: "\(expansion.provider) expanded the query. Matches are ranked locally against cached mail.")
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            let fallback = try Self.textSearch(query: query, messages: scoped, accountIDs: accountIDs)
            return MailSearchResult(messageIDs: fallback.messageIDs, mode: .textFallback,
                                    notice: "AI query expansion is unavailable. Showing text matches from cached mail.")
        }
    }

    /// Traditional mode uses the same local matching engine without dispatching AI.
    public static func textSearch(query: String, messages: [MailMessage], accountIDs: Set<UUID>) throws -> MailSearchResult {
        try Task.checkCancellation()
        let query = try validatedQuery(query)
        let ids = try rank(scopedMessages(messages, accountIDs: accountIDs), query: query, expansion: nil)
        return MailSearchResult(messageIDs: ids, mode: .text)
    }

    public func answer(query: String, messages: [MailMessage], accountIDs: Set<UUID>) async throws -> MailAssistantResult {
        let search = try await search(query: query, messages: messages, accountIDs: accountIDs)
        try Task.checkCancellation()
        let scoped = Self.scopedMessages(messages, accountIDs: accountIDs)
        let lookup = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        let terms = Self.queryTerms(query) + search.expandedTerms
        let sources = search.messageIDs.prefix(Self.maximumSources).compactMap { id -> AssistantSource? in
            guard let message = lookup[id], !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AssistantSource(message: message, excerpt: Self.excerpt(message.body, terms: terms))
        }
        guard !sources.isEmpty else {
            return MailAssistantResult(sources: [], search: search, outcome: .noMatches,
                                       notice: "No matching cached message content was found in the selected account scope.")
        }
        guard let provider else {
            return MailAssistantResult(sources: sources, search: search, outcome: .unavailable,
                                       notice: "AI is disabled. You can open these matching messages using normal mail controls.")
        }
        let request = AssistantRequest(query: try Self.validatedQuery(query), sources: sources)
        do {
            let answer = try await provider.answer(request)
            try Task.checkCancellation()
            try Self.validate(answer, request: request)
            guard !answer.claims.isEmpty else {
                return MailAssistantResult(sources: sources, search: search, outcome: .noMatches,
                                           notice: "The retrieved excerpts do not provide enough evidence to answer. Open the sources to review the full messages.")
            }
            return MailAssistantResult(answer: answer, sources: sources, search: search, outcome: .answered,
                                       notice: "Generated from up to six relevant excerpts of cached mail. Quotes are checked against those excerpts; compare each claim with its source.")
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            let invalid: Bool
            if let aiError = error as? AIError, case .invalidResponse = aiError { invalid = true } else { invalid = false }
            return MailAssistantResult(sources: sources, search: search, outcome: invalid ? .invalidResponse : .unavailable,
                                       notice: invalid ? "The AI answer could not be verified against the supplied sources. Open the matching messages to review them." : "The AI assistant is unavailable. Matching cached messages remain accessible.")
        }
    }

    static func validatedQuery(_ query: String) throws -> String {
        guard query.count <= queryCharacterLimit else {
            throw AIError.queryTooLong
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ expansion: SearchQueryExpansion, query: String) throws {
        let allowed = Set(queryTerms(query))
        guard [.semanticExpansion, .demoSemantic].contains(expansion.mode), expansion.terms.count <= 24,
              expansion.provider.count <= 200, !expansion.provider.isEmpty,
              Set(expansion.terms.map(\.term)).count == expansion.terms.count else {
            throw AIError.invalidResponse("Invalid search expansion.")
        }
        for group in expansion.terms {
            guard allowed.contains(group.term), group.alternatives.count <= 5,
                  Set(group.alternatives).count == group.alternatives.count,
                  group.alternatives.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 80 }) else {
                throw AIError.invalidResponse("Search expansion must preserve the original query terms.")
            }
        }
    }

    static func validate(_ request: AssistantRequest) throws {
        _ = try validatedQuery(request.query)
        guard !request.query.isEmpty, !request.sources.isEmpty, request.sources.count <= maximumSources,
              Set(request.sources.map(\.messageID)).count == request.sources.count,
              request.sources.allSatisfy({ !$0.excerpt.isEmpty && $0.excerpt.count <= excerptCharacterLimit }) else {
            throw AIError.invalidResponse("Invalid or oversized assistant context.")
        }
    }

    /// Structural grounding is a provenance check, not proof that a paraphrase
    /// logically follows from its quote. UI always exposes the original evidence.
    static func validate(_ answer: AssistantAnswer, request: AssistantRequest) throws {
        try validate(request)
        guard answer.claims.count <= 6, !answer.provider.isEmpty, answer.provider.count <= 200 else {
            throw AIError.invalidResponse("Invalid assistant answer.")
        }
        let lookup = Dictionary(uniqueKeysWithValues: request.sources.map { ($0.messageID, $0.excerpt) })
        for claim in answer.claims {
            guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, claim.text.count <= 1_500,
                  !claim.citations.isEmpty, claim.citations.count <= 3, Set(claim.citations).count == claim.citations.count else {
                throw AIError.invalidResponse("Every assistant claim needs bounded source evidence.")
            }
            for citation in claim.citations {
                guard !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, citation.quote.count <= 600,
                      lookup[citation.messageID]?.contains(citation.quote) == true else {
                    throw AIError.invalidResponse("An assistant citation does not match the supplied message excerpt.")
                }
            }
        }
    }

    static func queryTerms(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).filter { !stopWords.contains($0) && seen.insert($0).inserted }
    }

    private static func scopedMessages(_ messages: [MailMessage], accountIDs: Set<UUID>) -> [MailMessage] {
        // A malformed snapshot with colliding IDs must never choose an arbitrary
        // account's content as the source of a citation.
        let scoped = messages.filter { accountIDs.contains($0.accountID) }
        let counts = Dictionary(scoped.map { ($0.id, 1) }, uniquingKeysWith: +)
        return scoped.filter { counts[$0.id] == 1 }
    }

    private static func rank(_ messages: [MailMessage], query: String, expansion: SearchQueryExpansion?) throws -> [UUID] {
        let terms = queryTerms(query)
        guard !terms.isEmpty else { return [] }
        let alternatives = Dictionary(uniqueKeysWithValues: (expansion?.terms ?? []).map { ($0.term, $0.alternatives) })
        let groups = terms.map { [$0] + (alternatives[$0] ?? []) }
        var matches: [(MailMessage, Int)] = []
        for message in messages {
            try Task.checkCancellation()
            let title = normalized(String(message.subject.prefix(2_000)) + " " + String(message.from.name.prefix(500)) + " " + String(message.from.email.prefix(500)))
            let body = normalized(message.body)
            var score = 0
            var matched = true
            for (index, group) in groups.enumerated() {
                let titleMatches = group.contains { contains($0, in: title) }
                let bodyMatches = group.contains { contains($0, in: body) }
                guard titleMatches || bodyMatches else { matched = false; break }
                score += titleMatches ? 5 : 1
                if contains(terms[index], in: title) { score += 3 }
                else if contains(terms[index], in: body) { score += 1 }
            }
            if matched { matches.append((message, score)) }
        }
        try Task.checkCancellation()
        return matches.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.date != $1.0.date { return $0.0.date > $1.0.date }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map { $0.0.id }
    }

    private static func excerpt(_ body: String, terms: [String]) -> String {
        guard body.count > excerptCharacterLimit else { return body }
        // Prefer an evidence window near a query hit, rather than always sending
        // a greeting. This still sends at most one original excerpt per message.
        let hits = terms.compactMap { body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }
        guard let first = hits.min() else { return String(body.prefix(excerptCharacterLimit)) }
        let start = body.index(first, offsetBy: -200, limitedBy: body.startIndex) ?? body.startIndex
        return String(body[start...].prefix(excerptCharacterLimit))
    }

    private static func words(_ string: String) -> [String] {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func normalized(_ text: String) -> String { " " + words(text).joined(separator: " ") + " " }
    private static func contains(_ term: String, in normalizedText: String) -> Bool {
        let needle = normalized(term)
        return needle != "  " && normalizedText.contains(needle)
    }
    private static let stopWords: Set<String> = [
        "a", "an", "the", "what", "which", "who", "show", "find", "me", "my", "mail", "email", "emails", "message", "messages",
        "about", "from", "to", "of", "for", "and", "is", "are", "did", "say", "said", "with", "can", "you", "please", "tell",
        "need", "needs", "needing"
    ]
}
