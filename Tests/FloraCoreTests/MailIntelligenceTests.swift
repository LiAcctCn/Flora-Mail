import Foundation
import Testing
@testable import FloraCore

struct MailIntelligenceTests {
    private let accountID = UUID()
    private func message(subject: String = "Project meeting", body: String = "John requested an appointment tomorrow.",
                         account: UUID? = nil, date: Date = Date()) -> MailMessage {
        MailMessage(accountID: account ?? accountID, from: MailAddress(name: "John Example", email: "john@example.test"),
                    to: [MailAddress(name: "Recipient", email: "recipient@example.test")], subject: subject, body: body, date: date)
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func answerJSON(_ source: MailMessage, quote: String? = nil) throws -> String {
        try json(["claims": [["text": "An appointment was requested.", "citations": [["messageID": source.id.uuidString, "quote": quote ?? source.body]]]]])
    }

    @Test func localExpansionReceivesOnlyTheQueryAndKeepsAccountScope() async throws {
        let source = message(subject: "Project appointment")
        let privateMessage = message(subject: "Project appointment", body: "OTHER_ACCOUNT_SECRET", account: UUID())
        let client = RetrievalClient(responses: [#"{"terms":[{"term":"meeting","alternatives":["appointment"]}]}"#])
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .search(query: "John meeting", messages: [source, privateMessage], accountIDs: [accountID])
        #expect(result.mode == .semanticExpansion)
        #expect(result.messageIDs == [source.id])
        #expect(result.expandedTerms == ["appointment"])
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].prompt.contains("John meeting"))
        for value in [source.body, source.id.uuidString, privateMessage.body, source.from.email, accountID.uuidString] {
            #expect(!requests[0].prompt.contains(value))
        }
    }

    @Test func originalNameAndTopicConstraintsSurviveExpansion() async throws {
        let source = message(subject: "Appointment")
        var unrelated = message(subject: "Appointment", body: "Nora requested an appointment tomorrow.")
        unrelated.from = MailAddress(name: "Nora", email: "nora@example.test")
        let service = MailIntelligenceService(provider: MockAIProvider())
        let result = try await service.search(query: "John meeting", messages: [source, unrelated], accountIDs: [accountID])
        #expect(result.messageIDs == [source.id])
        #expect(result.mode == .demoSemantic)
        let noResult = try await service.search(query: "John invoice", messages: [source, unrelated], accountIDs: [accountID])
        #expect(noResult.messageIDs.isEmpty)
    }

    @Test func assistantPresetsRetrieveRelevantDemoFixturesWithoutRelaxingNameConstraints() async throws {
        let snapshot = DemoFixtures.makeSnapshot(now: Date(timeIntervalSince1970: 1_789_344_000))
        let accountIDs = Set(snapshot.accounts.map(\.id))
        let service = MailIntelligenceService(provider: MockAIProvider())
        let meeting = try #require(snapshot.messages.first { $0.subject == "Project sync moved to tomorrow at 3 PM" })
        let assignment = try #require(snapshot.messages.first { $0.subject == "PHYS 204 · Assignment deadline extended" })

        let replies = try await service.answer(query: "Reply", messages: snapshot.messages, accountIDs: accountIDs)
        #expect(replies.outcome == .answered)
        #expect(replies.search.messageIDs.contains(meeting.id))
        let deadlines = try await service.answer(query: "Assignment deadline", messages: snapshot.messages, accountIDs: accountIDs)
        #expect(deadlines.outcome == .answered)
        #expect(deadlines.search.messageIDs.contains(assignment.id))
        #expect(!deadlines.search.messageIDs.contains(meeting.id))
        let scoped = try await service.search(query: "Assignment deadline", messages: snapshot.messages, accountIDs: [meeting.accountID])
        #expect(!scoped.messageIDs.contains(assignment.id))
        let unrelated = try await service.search(query: "John invoice", messages: snapshot.messages, accountIDs: accountIDs)
        #expect(unrelated.messageIDs.isEmpty)
    }

    @Test func nilProviderUsesOnlyTextAndAssistantKeepsSources() async throws {
        let source = message()
        let service = MailIntelligenceService()
        let search = try await service.search(query: "John meeting", messages: [source], accountIDs: [accountID])
        #expect(search.mode == .text)
        #expect(search.expandedTerms.isEmpty)
        #expect(search.messageIDs == [source.id])
        let result = try await service.answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.outcome == .unavailable)
        #expect(result.answer == nil)
        #expect(result.sources.map(\.messageID) == [source.id])
    }

    @Test func emptyScopeOrStopWordsDoNotDispatchInference() async throws {
        let client = RetrievalClient(responses: [])
        let service = MailIntelligenceService(provider: LocalAIProvider(client: client))
        for query in ["", "show me emails", "   "] {
            let result = try await service.answer(query: query, messages: [message()], accountIDs: [accountID])
            #expect(result.outcome == .noMatches)
        }
        let result = try await service.answer(query: "meeting", messages: [message()], accountIDs: [])
        #expect(result.sources.isEmpty)
        #expect(await client.requests.isEmpty)
    }

    @Test func oversizedQueriesFailBeforeInference() async throws {
        let client = RetrievalClient(responses: [])
        do {
            _ = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
                .search(query: String(repeating: "a", count: 501), messages: [message()], accountIDs: [accountID])
            Issue.record("Oversized query must be rejected")
        } catch let error as AIError {
            #expect(error == .queryTooLong)
        }
        #expect(await client.requests.isEmpty)
    }

    @Test func unavailableRuntimeFallsBackToTextWithoutInventingAnswers() async throws {
        let source = message()
        let client = RetrievalClient(responses: [], failure: .runtimeUnavailable)
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.search.mode == .textFallback)
        #expect(result.search.messageIDs == [source.id])
        #expect(result.answer == nil)
        #expect(result.outcome == .unavailable)
        #expect(result.sources.count == 1)
    }

    @Test(arguments: [
        "not JSON", #"{"terms":[],"execute":"archive"}"#,
        #"{"terms":[{"term":"other","alternatives":["meeting"]}]}"#,
        #"{"terms":[{"term":"meeting","alternatives":[""]}]}"#,
        #"{"terms":[{"term":"meeting","alternatives":[]},{"term":"meeting","alternatives":[]}]}"#
    ])
    func invalidExpansionProducesDisclosedTextFallback(_ content: String) async throws {
        let source = message()
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: RetrievalClient(responses: [content])))
            .search(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.mode == .textFallback)
        #expect(result.messageIDs == [source.id])
        #expect(result.expandedTerms.isEmpty)
    }

    @Test func localAssistantProducesClaimsWithOriginalQuotes() async throws {
        let source = message()
        let client = RetrievalClient(responses: [#"{"terms":[]}"#, try answerJSON(source)])
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.outcome == .answered)
        #expect(result.answer?.provider == "Local AI · fixture-model")
        #expect(result.answer?.claims.first?.citations == [AssistantCitation(messageID: source.id, quote: source.body)])
        #expect(result.sources.first?.matches(source) == true)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[1].prompt.contains(source.body))
        #expect(requests[1].prompt.contains(source.id.uuidString))
        #expect(!requests[1].prompt.contains(source.from.email))
        #expect(!requests[1].prompt.contains(source.to[0].email))
        #expect(!requests[1].prompt.contains(accountID.uuidString))
        #expect(!requests[1].prompt.contains(result.sources[0].sourceFingerprint))
        #expect(requests[1].system.contains("untrusted data"))
        #expect(requests[1].system.contains("Never request tools"))
    }

    @Test func assistantContextIsBoundedAndExcludesOtherAccountsAndUnrelatedMessages() async throws {
        let sources = (0..<9).map { index in
            message(subject: "Project meeting \(index)", body: "Meeting evidence \(index). " + String(repeating: "x", count: 3_000) + "WITHHELD_SUFFIX",
                    date: Date(timeIntervalSince1970: Double(index)))
        }
        let other = message(body: "OTHER_ACCOUNT_SECRET meeting", account: UUID())
        var unrelated = message(subject: "Lunch", body: "UNRELATED_MESSAGE_SECRET")
        unrelated.from = MailAddress(name: "Nora", email: "nora@example.test")
        let client = RetrievalClient(responses: [#"{"terms":[]}"#, #"{"claims":[]}"#])
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .answer(query: "meeting", messages: sources + [other, unrelated], accountIDs: [accountID])
        #expect(result.sources.count == 6)
        #expect(result.sources.allSatisfy { $0.excerpt.count <= 1_500 && $0.accountID == accountID })
        #expect(result.sources.reduce(0) { $0 + $1.excerpt.count } <= 9_000)
        let requests = await client.requests
        #expect(requests.count == 2)
        for secret in ["WITHHELD_SUFFIX", other.body, unrelated.body, sources[0].id.uuidString] {
            #expect(!requests[1].prompt.contains(secret))
        }
    }

    @Test func retrievalChoosesVerbatimWindowAroundLaterEvidence() async throws {
        let source = message(body: String(repeating: "x", count: 4_000) + " Confirm the meeting on Friday. " + String(repeating: "y", count: 3_000))
        let result = try await MailIntelligenceService().answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.sources.count == 1)
        #expect(result.sources[0].excerpt.contains("Confirm the meeting on Friday."))
        #expect(source.body.contains(result.sources[0].excerpt))
    }

    @Test func sourceFingerprintRejectsContentIdentityOrMetadataChanges() async throws {
        let source = message()
        let result = try await MailIntelligenceService().answer(query: "meeting", messages: [source], accountIDs: [accountID])
        let snapshot = try #require(result.sources.first)
        #expect(snapshot.matches(source))
        var changed = source; changed.body += "Changed"
        #expect(!snapshot.matches(changed))
        changed = source; changed.subject += "Changed"
        #expect(!snapshot.matches(changed))
        changed = source; changed.from.name += "Changed"
        #expect(!snapshot.matches(changed))
        changed = source; changed.date += 1
        #expect(!snapshot.matches(changed))
        changed = source; changed.accountID = UUID()
        #expect(!snapshot.matches(changed))
        changed = source; changed.isRead.toggle()
        #expect(snapshot.matches(changed))
    }

    @Test func forgedIDsQuotesAndActionFieldsNeverBecomeAssistantResults() async throws {
        let source = message()
        let responses = [
            try json(["claims": [["text": "Claim", "citations": [["messageID": UUID().uuidString, "quote": source.body]]]]]),
            try answerJSON(source, quote: "This sentence does not exist."),
            try json(["claims": [["text": "Claim", "citations": []]]]),
            try json(["claims": [["text": "Claim", "citations": [["messageID": source.id.uuidString, "quote": source.body]], "execute": true]]]),
            #"{"claims":[],"send":true}"#, "not JSON"
        ]
        for response in responses {
            let client = RetrievalClient(responses: [#"{"terms":[]}"#, response])
            let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
                .answer(query: "meeting", messages: [source], accountIDs: [accountID])
            #expect(result.outcome == .invalidResponse)
            #expect(result.answer == nil)
            #expect(result.sources.map(\.messageID) == [source.id])
        }
    }

    @Test func quotesFromOutsideSuppliedExcerptAreRejected() async throws {
        let source = message(body: "Meeting " + String(repeating: "x", count: 2_000) + "Omitted secret suffix.")
        let client = RetrievalClient(responses: [#"{"terms":[]}"#, try answerJSON(source, quote: "Omitted secret suffix.")])
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.outcome == .invalidResponse)
        #expect(result.answer == nil)
    }

    @Test func noRetrievalMatchesSkipsAnswerInference() async throws {
        let client = RetrievalClient(responses: [#"{"terms":[]}"#])
        let result = try await MailIntelligenceService(provider: LocalAIProvider(client: client))
            .answer(query: "invoice", messages: [message()], accountIDs: [accountID])
        #expect(result.outcome == .noMatches)
        #expect(await client.requests.count == 1)
    }

    @Test func duplicateLocalIDsCannotSelectAnArbitraryAccountSource() async throws {
        let source = message()
        var colliding = source; colliding.accountID = UUID(); colliding.body = "meeting private collision"
        let result = try await MailIntelligenceService().answer(query: "meeting", messages: [source, colliding], accountIDs: [accountID, colliding.accountID])
        #expect(result.outcome == .noMatches)
        #expect(result.sources.isEmpty)
    }

    @Test func serviceRevalidatesThirdPartyProviderCitations() async throws {
        let result = try await MailIntelligenceService(provider: ForgingAssistantProvider())
            .answer(query: "meeting", messages: [message()], accountIDs: [accountID])
        #expect(result.outcome == .invalidResponse)
        #expect(result.answer == nil)
    }

    @Test(arguments: [1, 2])
    func cancelledInferenceCannotPublishSearchFallbackOrAnAnswer(_ cancellationRequest: Int) async throws {
        let source = message()
        let client = RetrievalClient(responses: [#"{"terms":[]}"#, try answerJSON(source)], cancelAt: cancellationRequest)
        let operation = Task {
            try await MailIntelligenceService(provider: LocalAIProvider(client: client))
                .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        }
        do { _ = try await operation.value; Issue.record("Cancelled inference must not publish a result") }
        catch { #expect(error is CancellationError) }
    }

    @Test func cancellationRemainsCancellationWhenRuntimeReportsAnError() async throws {
        let client = RetrievalClient(responses: [], failure: .runtimeUnavailable, cancelAt: 1)
        let source = message()
        let operation = Task {
            try await MailIntelligenceService(provider: LocalAIProvider(client: client))
                .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        }
        do { _ = try await operation.value; Issue.record("Cancellation must not become text fallback") }
        catch { #expect(error is CancellationError) }
    }

    @Test func cachedDecoratorForwardsBothCapabilitiesWithoutPersistingQueriesOrSources() async throws {
        let source = message()
        let client = RetrievalClient(responses: [#"{"terms":[]}"#, try answerJSON(source)])
        let store = RetrievalCacheSpy()
        let provider: any AIProvider = CachedAIProvider(provider: LocalAIProvider(client: client), store: store)
        let result = try await MailIntelligenceService(provider: provider)
            .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.outcome == .answered)
        #expect(await store.writes == 0)
        #expect(await client.requests.count == 2)
    }

    @Test func demoAssistantUsesTheSameProtocolAndDisclosesExtractiveOutput() async throws {
        let source = message()
        let provider: any AIProvider = MockAIProvider()
        let result = try await MailIntelligenceService(provider: provider)
            .answer(query: "meeting", messages: [source], accountIDs: [accountID])
        #expect(result.outcome == .answered)
        #expect(result.answer?.provider == "Demo AI · extractive assistant")
        #expect(result.answer?.claims.first?.text == source.body)
        #expect(result.answer?.claims.first?.citations.first?.quote == source.body)
    }
}

private actor RetrievalClient: LocalModelClient {
    static let identity = LocalModelIdentity(runtimeVersion: "fixture-runtime", model: "fixture-model", digest: "fixture-digest")
    private var responses: [String]
    private let failure: AIError?
    private let cancelAt: Int?
    private(set) var requests: [LocalModelRequest] = []
    init(responses: [String], failure: AIError? = nil, cancelAt: Int? = nil) {
        self.responses = responses; self.failure = failure; self.cancelAt = cancelAt
    }
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { Self.identity }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        requests.append(request)
        if cancelAt == requests.count { withUnsafeCurrentTask { $0?.cancel() } }
        if let failure { throw failure }
        guard !responses.isEmpty else { throw AIError.invalidResponse("No scripted response.") }
        return LocalModelOutput(content: responses.removeFirst(), identity: Self.identity)
    }
}

private actor RetrievalCacheSpy: AICacheStore {
    private(set) var writes = 0
    func value(for key: String) async throws -> Data? { nil }
    func insert(_ data: Data, for key: String) async throws { writes += 1 }
    func clear() async throws {}
}

private struct ForgingAssistantProvider: AIProvider {
    func summarize(_ message: MailMessage) async throws -> MessageSummary { throw AIError.unsupportedCapability }
    func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion? { nil }
    func extractActions(_ message: MailMessage) async throws -> [ActionItem] { [] }
    func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply] { [] }
    func rewrite(_ text: String, tool: WritingTool) async throws -> String { text }
    func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID] { [] }
    func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion {
        SearchQueryExpansion(terms: [], provider: "Fixture provider", mode: .semanticExpansion)
    }
    func answer(_ request: AssistantRequest) async throws -> AssistantAnswer {
        AssistantAnswer(claims: [AssistantClaim(text: "Fabricated", citations: [AssistantCitation(messageID: UUID(), quote: "Wrong")])], provider: "Fixture provider")
    }
}
