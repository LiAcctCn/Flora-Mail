import Foundation
import CryptoKit

public enum MailSearchMode: String, Sendable, Equatable {
    case text, semanticExpansion, demoSemantic, textFallback
}

public struct SearchExpansionTerm: Sendable, Equatable {
    public let term: String
    public let alternatives: [String]
    public init(term: String, alternatives: [String]) { self.term = term; self.alternatives = alternatives }
}

/// Query-only synonyms, not model-selected message IDs or mailbox content.
public struct SearchQueryExpansion: Sendable, Equatable {
    public let terms: [SearchExpansionTerm]
    public let provider: String
    public let mode: MailSearchMode
    public init(terms: [SearchExpansionTerm], provider: String, mode: MailSearchMode) {
        self.terms = terms; self.provider = provider; self.mode = mode
    }
}

public struct MailSearchResult: Sendable, Equatable {
    public let messageIDs: [UUID]
    public let mode: MailSearchMode
    public let expandedTerms: [String]
    public let notice: String?
    public init(messageIDs: [UUID], mode: MailSearchMode, expandedTerms: [String] = [], notice: String? = nil) {
        self.messageIDs = messageIDs; self.mode = mode; self.expandedTerms = expandedTerms; self.notice = notice
    }
}

/// Authoritative metadata and one verbatim, bounded body excerpt. Fingerprints
/// remain on-device and let presentation discard results from stale snapshots.
public struct AssistantSource: Sendable, Equatable, Identifiable {
    public var id: UUID { messageID }
    public let messageID: UUID
    public let accountID: UUID
    public let subject: String
    public let sender: MailAddress
    public let date: Date
    public let excerpt: String
    public let sourceFingerprint: String

    init(message: MailMessage, excerpt: String) {
        messageID = message.id; accountID = message.accountID
        subject = String(message.subject.prefix(500))
        sender = MailAddress(name: String(message.from.name.prefix(120)), email: String(message.from.email.prefix(254)))
        date = message.date; self.excerpt = excerpt
        sourceFingerprint = Self.fingerprint(message)
    }
    public func matches(_ message: MailMessage) -> Bool {
        messageID == message.id && accountID == message.accountID && sourceFingerprint == Self.fingerprint(message)
    }
    private static func fingerprint(_ message: MailMessage) -> String {
        var hash = SHA256()
        for value in [message.id.uuidString, message.accountID.uuidString, message.subject, message.body,
                      message.from.name, message.from.email, String(message.date.timeIntervalSince1970)] {
            let data = Data(value.utf8)
            hash.update(data: Data("\(data.count):".utf8)); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct AssistantRequest: Sendable {
    public let query: String
    public let sources: [AssistantSource]
    public init(query: String, sources: [AssistantSource]) { self.query = query; self.sources = sources }
}

public struct AssistantCitation: Sendable, Equatable, Hashable {
    public let messageID: UUID
    public let quote: String
    public init(messageID: UUID, quote: String) { self.messageID = messageID; self.quote = quote }
}

public struct AssistantClaim: Sendable, Equatable {
    public let text: String
    public let citations: [AssistantCitation]
    public init(text: String, citations: [AssistantCitation]) { self.text = text; self.citations = citations }
}

public struct AssistantAnswer: Sendable, Equatable {
    public let claims: [AssistantClaim]
    public let provider: String
    public init(claims: [AssistantClaim], provider: String) { self.claims = claims; self.provider = provider }
}

public enum MailAssistantOutcome: String, Sendable, Equatable {
    case answered, noMatches, unavailable, invalidResponse
}

public struct MailAssistantResult: Sendable, Equatable {
    public let answer: AssistantAnswer?
    public let sources: [AssistantSource]
    public let search: MailSearchResult
    public let outcome: MailAssistantOutcome
    public let notice: String?
    public init(answer: AssistantAnswer? = nil, sources: [AssistantSource], search: MailSearchResult,
                outcome: MailAssistantOutcome, notice: String? = nil) {
        self.answer = answer; self.sources = sources; self.search = search; self.outcome = outcome; self.notice = notice
    }
}
