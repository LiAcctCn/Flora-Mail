import Foundation
import CryptoKit

public protocol AICacheStore: Sendable {
    func value(for key: String) async throws -> Data?
    func insert(_ data: Data, for key: String) async throws
    func clear() async throws
}

/// Only validated capability results are stored here, never HTTP requests, credentials or UI state.
public actor JSONAICacheStore: AICacheStore {
    private struct Entry: Codable { var data: Data; var writtenAt: Date }
    private struct File: Codable { var version = 1; var entries: [String: Entry] = [:] }
    private let url: URL
    private let maximumEntries: Int
    private var file: File?
    public init(url: URL, maximumEntries: Int = 256) { self.url = url; self.maximumEntries = max(1, maximumEntries) }
    private func load() throws -> File {
        if let file { return file }
        guard FileManager.default.fileExists(atPath: url.path) else { file = File(); return File() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_000_000 else {
            throw AIError.invalidResponse("The local AI cache exceeds its size limit. Clear the AI cache in Settings.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 16_000_000, let decoded = try? JSONDecoder().decode(File.self, from: data), decoded.version == 1 else {
            throw AIError.invalidResponse("The local AI cache could not be read. Clear the AI cache in Settings to regenerate results.")
        }
        file = decoded
        return decoded
    }
    public func value(for key: String) throws -> Data? { try Task.checkCancellation(); return try load().entries[key]?.data }
    public func insert(_ data: Data, for key: String) throws {
        try Task.checkCancellation()
        guard data.count <= 200_000 else { throw AIError.invalidResponse("This AI result exceeds the cache entry size limit.") }
        var candidate = try load()
        candidate.entries[key] = Entry(data: data, writtenAt: Date())
        while candidate.entries.count > maximumEntries {
            guard let oldest = candidate.entries.min(by: { $0.value.writtenAt < $1.value.writtenAt })?.key else { break }
            candidate.entries.removeValue(forKey: oldest)
        }
        try persist(candidate)
    }
    public func clear() throws { try persist(File()) }
    private func persist(_ candidate: File) throws {
        var candidate = candidate
        var data = try JSONEncoder().encode(candidate)
        while data.count > 16_000_000 {
            guard let oldest = candidate.entries.min(by: { $0.value.writtenAt < $1.value.writtenAt })?.key else { break }
            candidate.entries.removeValue(forKey: oldest)
            data = try JSONEncoder().encode(candidate)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        file = candidate
    }
}

public actor MemoryAICacheStore: AICacheStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func value(for key: String) -> Data? { values[key] }
    public func insert(_ data: Data, for key: String) { values[key] = data }
    public func clear() { values = [:] }
}

/// Decorates any AIProvider. The same cache cannot confuse demo, models, prompts or message versions.
public struct CachedAIProvider: AIProvider {
    private let provider: any AIProvider
    private let store: any AICacheStore
    private let promptVersion: String
    private let namespace: String
    public init(provider: any AIProvider, store: any AICacheStore, promptVersion: String = AIPromptLibrary.version, namespace: String = "") {
        self.provider = provider; self.store = store; self.promptVersion = promptVersion; self.namespace = namespace
    }
    public func cacheIdentity() async throws -> String { try await provider.cacheIdentity() }
    public func summarize(_ message: MailMessage) async throws -> MessageSummary {
        try await cached("summary", input: source(message)) { try await provider.summarize(message) }
    }
    public func classify(_ message: MailMessage, categories: [MailCategory]) async throws -> ClassificationSuggestion? {
        try await cached("classification", input: source(message) + [try encoded(categories)]) {
            try await provider.classify(message, categories: categories)
        }
    }
    public func extractActions(_ message: MailMessage) async throws -> [ActionItem] {
        try await cached("actions", input: source(message)) { try await provider.extractActions(message) }
    }
    public func generateReplies(_ message: MailMessage) async throws -> [SuggestedReply] {
        try await cached("replies", input: source(message)) { try await provider.generateReplies(message) }
    }
    public func rewrite(_ text: String, tool: WritingTool) async throws -> String {
        // Draft text is intentionally not cached on disk: accepting a preview is the save boundary.
        try Task.checkCancellation()
        let result = try await provider.rewrite(text, tool: tool)
        try Task.checkCancellation()
        return result
    }

    public func rewrite(_ text: String, tool: WritingTool, context: MailMessage?) async throws -> String {
        try Task.checkCancellation()
        let result = try await provider.rewrite(text, tool: tool, context: context)
        try Task.checkCancellation()
        return result
    }
    public func semanticSearch(_ query: String, messages: [MailMessage]) async throws -> [UUID] {
        try Task.checkCancellation()
        let result = try await provider.semanticSearch(query, messages: messages)
        try Task.checkCancellation()
        return result
    }
    public func expandSearchQuery(_ query: String) async throws -> SearchQueryExpansion {
        // Retrieval queries and assistant conversations are transient; do not
        // persist a second copy of user questions or selected source excerpts.
        try Task.checkCancellation()
        let result = try await provider.expandSearchQuery(query)
        try Task.checkCancellation()
        return result
    }
    public func answer(_ request: AssistantRequest) async throws -> AssistantAnswer {
        try Task.checkCancellation()
        let result = try await provider.answer(request)
        try Task.checkCancellation()
        return result
    }
    private func source(_ message: MailMessage) -> [String] {
        [message.id.uuidString, message.accountID.uuidString, message.providerID, message.subject, message.body, message.from.name, message.from.email]
    }
    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func cached<T: Codable & Sendable>(_ capability: String, input: [String], generate: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let identity = try await provider.cacheIdentity()
        try Task.checkCancellation()
        let keyData = Data(try encoded([namespace, identity, promptVersion, capability] + input).utf8)
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        if let data = try await store.value(for: key) {
            do {
                let cached = try JSONDecoder().decode(T.self, from: data)
                try Task.checkCancellation()
                return cached
            } catch is DecodingError {
                // An obsolete payload is a cache miss; never interpret partial data as a result.
            }
        }
        let result = try await generate()
        try Task.checkCancellation()
        // A model tag can be replaced during inference. Do not cache under an obsolete digest.
        let currentIdentity = try await provider.cacheIdentity()
        try Task.checkCancellation()
        guard currentIdentity == identity else { throw AIError.invalidResponse("The selected model changed during inference. Retry with the current model.") }
        try await store.insert(JSONEncoder().encode(result), for: key)
        try Task.checkCancellation()
        return result
    }
}
