import Foundation
import FloraCore

/// Opt-in, real-runtime verification. It uses fictional fixtures and never opens the app's mail store.
@main
struct LocalAICheck {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    private static func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    @MainActor
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ ["--replies-only", "--synchronized-fixture", "--intelligence-only"].contains($0) }),
              arguments.filter({ !$0.hasPrefix("--") }).count <= 1 else {
            throw AIError.invalidConfiguration("Usage: FloraLocalAICheck [model] [--replies-only | --intelligence-only] [--synchronized-fixture]")
        }
        let repliesOnly = arguments.contains("--replies-only")
        let synchronizedFixture = arguments.contains("--synchronized-fixture")
        let configuration = AIModelConfiguration(model: arguments.first { !$0.hasPrefix("--") } ?? "gemma3:4b")
        let client = OllamaLocalModelClient()
        emit("Checking local runtime…")
        let identity = try await client.inspect(configuration)
        emit("Runtime: Ollama \(identity.runtimeVersion); model: \(identity.model); digest: \(identity.digest)")
        let provider = CachedAIProvider(provider: LocalAIProvider(configuration: configuration, client: client), store: MemoryAICacheStore())
        let state = try await verificationState(synchronizedFixture: synchronizedFixture)
        if arguments.contains("--intelligence-only") {
            guard let meeting = state.messages.first(where: { $0.subject == "Project sync moved to tomorrow at 3 PM" }) else {
                throw AIError.invalidResponse("The fictional meeting fixture is missing.")
            }
            let service = MailIntelligenceService(provider: provider)
            let result = try await service.answer(query: "Project meeting", messages: state.messages, accountIDs: [meeting.accountID])
            guard result.search.mode == .semanticExpansion, result.search.messageIDs.contains(meeting.id),
                  result.outcome == .answered, let answer = result.answer,
                  result.sources.allSatisfy({ source in source.accountID == meeting.accountID && state.messages.contains(where: { source.matches($0) }) }) else {
                throw AIError.invalidResponse(result.notice ?? "Local retrieval or source-linked answer did not complete.")
            }
            emit("Search: actual local query expansion; \(result.search.messageIDs.count) scoped matches")
            for claim in answer.claims {
                emit("Claim: \(claim.text)")
                for citation in claim.citations { emit("Source quote: \(citation.quote)") }
            }
            emit("PASS: local query expansion, scoped retrieval and validated source-linked answer. Fictional fixtures only; no mailbox or calendar actions executed.")
            return
        }
        if repliesOnly {
            guard let maya = state.messages.first(where: { $0.subject == "Flora project · Design review ready for feedback" }) else {
                throw AIError.invalidResponse("The Maya smart-reply verification fixture is missing.")
            }
            emit("Smart-reply prompt: \(AIPromptLibrary.version); fictional source: \(maya.subject)")
            let replies = try await provider.generateReplies(maya)
            for (index, reply) in replies.enumerated() { emit("Option \(index + 1): \(reply.text)") }
            emit("Completed \(replies.count) structured replies. Review perspective and factual claims manually; schema validation does not guarantee their accuracy. \(synchronizedFixture ? "Only a temporary fictional fixture store was synchronized and reloaded; no live account authentication occurred." : "No mail store was opened or mutated.")")
            return
        }
        guard let meeting = state.messages.first(where: { $0.subject == "Project sync moved to tomorrow at 3 PM" }),
              let assignment = state.messages.first(where: { $0.subject == "PHYS 204 · Assignment deadline extended" }) else {
            throw AIError.invalidResponse("Required verification fixtures are missing.")
        }
        let summary = try await provider.summarize(meeting)
        emit("Summary [\(summary.provider)]: \(summary.headline)")
        for fact in summary.facts { emit("  Fact: \(fact.text)\n  Source: \(fact.sourceQuote)") }
        let cachedStart = Date()
        let cached = try await provider.summarize(meeting)
        guard cached == summary else { throw AIError.invalidResponse("The repeated summary did not reuse its cached result.") }
        emit("Cached summary identical; read and model preflight: \(String(format: "%.3f", Date().timeIntervalSince(cachedStart)))s")
        if let category = try await provider.classify(assignment, categories: state.categories) {
            guard state.categories.contains(where: { $0.id == category.categoryID }) else { throw AIError.invalidResponse("Category outside user structure.") }
            emit("Classification: \(state.categories.first { $0.id == category.categoryID }?.name ?? "Unknown") · confidence \(category.confidence)")
        } else { emit("Classification: no category confidently selected") }
        let actions = try await provider.extractActions(meeting)
        emit("Extracted actions: \(actions.count)")
        for action in actions { emit("  \(action.title) · source: \(action.sourceQuote)") }
        let replies = try await provider.generateReplies(meeting)
        for reply in replies { emit("Smart reply: \(reply.text)") }
        for tool in WritingTool.allCases {
            let text = try await provider.rewrite("Hi John,\n\nYes I can meeting tomorrow. Thanks for the update.", tool: tool, context: meeting)
            emit("\(tool.rawValue): \(text)")
        }
        emit("PASS: five local capabilities, all writing tools with selected-message context, strict response validation and cache reuse. No external mail mutations executed.")
        if synchronizedFixture { emit("Scope: fictional read-only provider → temporary JSON repository → reload → real Local AI. Real Gmail, Microsoft and iCloud authentication are not tested by this check.") }
    }
    @MainActor
    private static func verificationState(synchronizedFixture: Bool) async throws -> AppSnapshot {
        let fixtures = DemoFixtures.makeSnapshot()
        guard synchronizedFixture else { return fixtures }
        emit("Source: FICTIONAL synchronized provider fixture. No live Gmail connection, account credentials or user mail are used.")
        let accountID = UUID()
        let account = MailAccount(id: accountID, name: "Fictional synchronized fixture",
                                  address: MailAddress(name: "Fixture Reader", email: "fixture-reader@example.test"),
                                  provider: "Fictional Gmail-type fixture", providerType: .gmail,
                                  providerAccountID: "fictional-local-ai-verification", status: .connected)
        let subjects = Set(["Project sync moved to tomorrow at 3 PM", "PHYS 204 · Assignment deadline extended", "Flora project · Design review ready for feedback"])
        let messages = fixtures.messages.filter { subjects.contains($0.subject) }.map { source in
            var message = source
            message.accountID = accountID
            message.providerID = "fictional-synchronized-" + source.providerID
            message.id = StableMailIdentity.message(accountID: accountID, providerID: message.providerID)
            message.providerThreadID = "fictional-thread-" + source.threadID.uuidString
            message.threadID = StableMailIdentity.thread(accountID: accountID, providerID: message.providerThreadID ?? message.providerID)
            message.providerFolderIDs = ["INBOX"]
            message.attachments = source.attachments.map { original in
                var attachment = original
                attachment.id = StableMailIdentity.attachment(accountID: accountID, providerID: message.providerID + ":" + original.id.uuidString)
                attachment.providerID = "fictional-attachment-" + original.id.uuidString
                return attachment
            }
            return message
        }
        guard messages.count == subjects.count else { throw AIError.invalidResponse("Required synchronized fixtures are missing.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Flora-LocalAI-Fictional-Sync-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("fixture-mail.json")
        defer {
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { emit("Temporary fictional fixture storage could not be removed: \(directory.path)") }
        }
        let repository = JSONMailRepository(url: file)
        let initial = AppSnapshot(accounts: [account], categories: fixtures.categories)
        try repository.save(initial)
        let executor = ActionExecutor(repository: repository, initialState: initial)
        let fixtureProvider = FictionalSynchronizedMailProvider(account: account, messages: messages)
        let result = try await MailSyncCoordinator(executor: executor).sync(provider: fixtureProvider, settings: MailSyncSettings(recentDays: 30, maximumMessages: 10, pageSize: 2))
        guard result.receivedMessages == messages.count, result.pages == 2, !result.hasMore,
              let reloaded = try JSONMailRepository(url: file).load(), reloaded.messages.count == messages.count,
              reloaded.messages.allSatisfy({ $0.accountID == accountID }),
              reloaded.accounts.first?.syncState.checkpoint?.initialComplete == true,
              reloaded.accounts.first?.syncState.lastSuccessfulSync != nil else {
            throw AIError.invalidResponse("The fictional provider sync did not persist and reload the expected account-scoped messages.")
        }
        emit("Synchronized \(result.receivedMessages) fictional messages in \(result.pages) pages; reloaded account-isolated messages and checkpoint from temporary JSON storage.")
        return reloaded
    }

}


/// Deliberately fictional provider exercising the real sync/repository boundary.
/// It has no network client, OAuth implementation or credential dependency.
@MainActor
private final class FictionalSynchronizedMailProvider: ReadOnlyMailProvider {
    let name = "Fictional synchronized verification fixture"
    let account: MailAccount
    let messages: [MailMessage]
    var accountID: UUID { account.id }
    init(account: MailAccount, messages: [MailMessage]) { self.account = account; self.messages = messages }
    func fetchAccounts() async throws -> [MailAccount] { [account] }
    func fetchRemoteFolders() async throws -> [MailFolderDescriptor] {
        [MailFolderDescriptor(id: "INBOX", accountID: account.id, name: "Fictional Inbox", role: .inbox)]
    }
    func fetchPage(_ request: MailSyncRequest) async throws -> MailSyncPage {
        try Task.checkCancellation()
        if let checkpoint = request.checkpoint, checkpoint.initialComplete {
            return MailSyncPage(messages: [], checkpoint: checkpoint)
        }
        let offset = request.checkpoint?.continuationToken.flatMap(Int.init) ?? 0
        guard offset >= 0, offset <= messages.count else { throw MailSyncError.invalidCheckpoint }
        let page = Array(messages.dropFirst(offset).prefix(request.limit)); let next = offset + page.count
        let hasMore = next < messages.count
        return MailSyncPage(messages: page, checkpoint: SyncCheckpoint(opaqueState: "fictional-provider-v1", continuationToken: hasMore ? String(next) : nil, initialComplete: !hasMore), hasMore: hasMore)
    }
    func downloadAttachment(message: MailMessage, attachment: MailAttachment) async throws -> Data {
        throw MailSyncError.unsupportedContent
    }
}
