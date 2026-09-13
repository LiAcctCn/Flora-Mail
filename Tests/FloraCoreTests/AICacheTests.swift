import Foundation
import Testing
@testable import FloraCore

private actor CountingProvider: AIProvider {
    private var identity = "test-model-v1"
    private var counts: [String: Int] = [:]
    var unavailable = false
    var changeDuringGeneration = false
    var slow = false
    func cacheIdentity() throws -> String { if unavailable { throw AIError.runtimeUnavailable }; return identity }
    func setIdentity(_ value: String) { identity = value }
    func setUnavailable() { unavailable = true }
    func changeOnNextSummary() { changeDuringGeneration = true }
    func makeSlow() { slow = true }
    func count(_ capability: String) -> Int { counts[capability, default: 0] }
    func summarize(_ message: MailMessage) async throws -> MessageSummary {
        counts["summary", default: 0] += 1
        if slow { try? await Task.sleep(for: .milliseconds(200)) }
        if changeDuringGeneration { identity = "test-model-v2"; changeDuringGeneration = false }
        return MessageSummary(messageID: message.id, headline: message.body, facts: [])
    }
    func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion? {
        counts["classification", default: 0] += 1
        return try await MockAIProvider().classify(message, categories: categories)
    }
    func extractActions(_ message: MailMessage) async throws -> [ActionItem] {
        counts["actions", default: 0] += 1
        return try await MockAIProvider().extractActions(message)
    }
    func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply] {
        counts["replies", default: 0] += 1
        return try await MockAIProvider().generateReplies(message)
    }
    func rewrite(_ text: String, tool: WritingTool) async throws -> String {
        counts["rewrite", default: 0] += 1
        return try await MockAIProvider().rewrite(text, tool: tool)
    }
    func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID] { [] }
}

struct AICacheTests {
    private func message() -> MailMessage {
        MailMessage(accountID: UUID(), from: MailAddress(name: "Professor Lin", email: "lin@example.test"), to: [], subject: "School assignment", body: "Please submit your assignment by Friday.")
    }
    @Test func repeatedRequestUsesCacheButContentChangesInvalidateIt() async throws {
        let base = CountingProvider(), store = MemoryAICacheStore()
        let provider = CachedAIProvider(provider: base, store: store)
        var source = message()
        let first = try await provider.summarize(source)
        #expect(try await provider.summarize(source) == first)
        source.isRead = true; source.folder = .archive
        _ = try await provider.summarize(source)
        #expect(await base.count("summary") == 1)
        source.body = "The assignment now closes on Monday."
        #expect(try await provider.summarize(source).headline == source.body)
        #expect(await base.count("summary") == 2)
    }
    @Test func modelPromptAndEndpointNamespaceInvalidateCache() async throws {
        let base = CountingProvider(), store = MemoryAICacheStore(), source = message()
        let initial = CachedAIProvider(provider: base, store: store, promptVersion: "v1", namespace: "server1")
        _ = try await initial.summarize(source)
        await base.setIdentity("model-revision-2")
        _ = try await initial.summarize(source)
        _ = try await CachedAIProvider(provider: base, store: store, promptVersion: "v2", namespace: "server1").summarize(source)
        _ = try await CachedAIProvider(provider: base, store: store, promptVersion: "v2", namespace: "server2").summarize(source)
        #expect(await base.count("summary") == 4)
    }
    @Test func categoriesAndNegativePredictionsAreCachedCorrectly() async throws {
        let base = CountingProvider(), providerStore = MemoryAICacheStore(), source = message()
        let provider = CachedAIProvider(provider: base, store: providerStore)
        let school = MailCategory(name: "School")
        #expect(try await provider.classify(source, categories: [school])?.categoryID == school.id)
        _ = try await provider.classify(source, categories: [school])
        #expect(await base.count("classification") == 1)
        #expect(try await provider.classify(source, categories: []) == nil)
        #expect(try await provider.classify(source, categories: []) == nil)
        #expect(await base.count("classification") == 2)
        let renamed = MailCategory(id: school.id, name: "Finance")
        #expect(try await provider.classify(source, categories: [renamed]) == nil)
        #expect(await base.count("classification") == 3)
    }
    @Test func differentCapabilitiesDoNotCollideAndDraftTextIsNotCached() async throws {
        let base = CountingProvider(), source = message()
        let provider = CachedAIProvider(provider: base, store: MemoryAICacheStore())
        for _ in 0..<2 {
            _ = try await provider.summarize(source)
            _ = try await provider.extractActions(source)
            _ = try await provider.generateReplies(source)
            _ = try await provider.rewrite("Yes I can meeting tomorrow.", tool: .proofread)
        }
        #expect(await base.count("summary") == 1)
        #expect(await base.count("actions") == 1)
        #expect(await base.count("replies") == 1)
        #expect(await base.count("rewrite") == 2)
    }
    @Test func cacheSurvivesRepositoryRecreationAndClear() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ai-cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = CountingProvider(), source = message()
        _ = try await CachedAIProvider(provider: base, store: JSONAICacheStore(url: url)).summarize(source)
        let reloadedStore = JSONAICacheStore(url: url)
        let reloaded = CachedAIProvider(provider: base, store: reloadedStore)
        _ = try await reloaded.summarize(source)
        #expect(await base.count("summary") == 1)
        try await reloadedStore.clear()
        _ = try await reloaded.summarize(source)
        #expect(await base.count("summary") == 2)
    }
    @Test func unavailableRuntimeNeverMasqueradesAsLiveCachedInference() async throws {
        let base = CountingProvider(), source = message()
        let provider = CachedAIProvider(provider: base, store: MemoryAICacheStore())
        _ = try await provider.summarize(source)
        await base.setUnavailable()
        await #expect(throws: AIError.runtimeUnavailable) { try await provider.summarize(source) }
    }
    @Test func cancelledRequestCannotPopulateCacheEvenIfProviderIgnoresCancellation() async throws {
        let base = CountingProvider(), source = message()
        await base.makeSlow()
        let provider = CachedAIProvider(provider: base, store: MemoryAICacheStore())
        let task = Task { try await provider.summarize(source) }
        while await base.count("summary") == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        _ = try await provider.summarize(source)
        #expect(await base.count("summary") == 2)
    }
    @Test func replacedModelDuringGenerationIsNotCachedUnderOldIdentity() async throws {
        let base = CountingProvider(), source = message()
        await base.changeOnNextSummary()
        let provider = CachedAIProvider(provider: base, store: MemoryAICacheStore())
        do { _ = try await provider.summarize(source); Issue.record("Model changed during generation") }
        catch { #expect(error is AIError) }
        _ = try await provider.summarize(source)
        #expect(await base.count("summary") == 2)
    }
    @Test func existingPreferencesDecodeWithoutErasingPriorData() throws {
        let legacy = Data(#"{"aiMode":"Off"}"#.utf8)
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: legacy)
        #expect(preferences.aiMode == .off)
        #expect(preferences.localAI == AIModelConfiguration())
        #expect(try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }
    @Test @MainActor func independentCapabilityPersistencePreservesPredictions() throws {
        let source = message(), school = MailCategory(name: "School")
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: AppSnapshot(messages: [source], categories: [school]))
        let prediction = ClassificationSuggestion(messageID: source.id, categoryID: school.id, explanation: "Assignment")
        try executor.cacheClassification(prediction, messageID: source.id)
        #expect(executor.state.summaries.isEmpty)
        try executor.cacheSummary(MessageSummary(messageID: source.id, headline: "Deadline", facts: []))
        #expect(executor.state.classifications == [prediction])
        _ = try executor.acceptClassification(prediction)
        try executor.clearAIResults()
        #expect(executor.state.messages.first?.categoryID == school.id)
    }
}
