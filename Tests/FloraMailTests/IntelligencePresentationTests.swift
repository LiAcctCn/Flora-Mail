import Foundation
import Testing
@testable import FloraCore
@testable import FloraMail

private actor NoInferenceClient: LocalModelClient {
    private(set) var calls = 0
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity {
        calls += 1; throw AIError.runtimeUnavailable
    }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        calls += 1; throw AIError.runtimeUnavailable
    }
}

@MainActor
struct IntelligencePresentationTests {
    @Test func learnedSuggestionsAreOptInPersistentAndStillRequireAcceptance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraLearningPresentation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        let account = MailAccount(name: "Fixture", address: MailAddress(name: "Reader", email: "reader@example.test"))
        let category = MailCategory(name: "Research")
        let messages = (0..<3).map { index in
            MailMessage(providerID: "fixture-\(index)", accountID: account.id, threadID: UUID(),
                        from: MailAddress(name: "Researcher", email: "research@example.test"), to: [account.address],
                        subject: "Study \(index)", body: "Please review this fictional study.")
        }
        try JSONMailRepository(url: url).save(AppSnapshot(accounts: [account], messages: messages, categories: [category]))
        let client = NoInferenceClient()
        let model = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        for message in messages.prefix(2) {
            #expect(model.perform(ProposedAction(type: .classify(messageID: message.id, categoryID: category.id), explanation: "Fixture user correction")))
        }
        #expect(model.learnedCategory(for: messages[2]) == nil)
        model.setCategoryLearning(true); model.updateAIMode(.local)
        let learned = try #require(model.learnedCategory(for: messages[2]))
        #expect(learned.supportCount == 2)
        let suggestion = try #require(try await model.classification(for: messages[2]))
        #expect(model.state.messages.first { $0.id == messages[2].id }?.categoryID == nil)
        #expect(await client.calls == 0)
        #expect(model.acceptClassification(suggestion))
        let reopened = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        #expect(reopened.state.preferences.learnCategoryPreferences)
        #expect(reopened.state.messages.first { $0.id == messages[2].id }?.categoryID == category.id)
        reopened.setCategoryLearning(false)
        #expect(reopened.learnedCategory(for: messages[2]) == nil)
    }

    @Test func assistantAndBriefingRespectDemoAndAccountScopeWhenAIIsOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraIntelligenceScope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        let demo = MailAccount(name: "Demo", address: MailAddress(name: "Demo", email: "demo@example.test"))
        let real = MailAccount(name: "Fictional remote", address: MailAddress(name: "Reader", email: "reader@example.test"), provider: "Gmail", providerType: .gmail)
        let messages = [demo, real].map { account in
            MailMessage(providerID: "same-provider-id", accountID: account.id, threadID: UUID(),
                        from: MailAddress(name: "Source", email: "source@example.test"), to: [account.address],
                        subject: "Project review", body: "Please reply about the project review.", isFlagged: true)
        }
        try JSONMailRepository(url: url).save(AppSnapshot(accounts: [demo, real], messages: messages))
        let client = NoInferenceClient()
        let model = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        model.updateAIMode(.off)
        let demoResult = try await model.assistantAnswer("Project review")
        #expect(demoResult.answer == nil)
        #expect(demoResult.sources.map(\.accountID) == [demo.id])
        #expect(model.dailyBriefing.needsAttention.map(\.accountID) == [demo.id])
        model.setDemoMode(false); model.navigate(.account(real.id))
        let realResult = try await model.assistantAnswer("Project review")
        #expect(realResult.sources.map(\.accountID) == [real.id])
        #expect(model.dailyBriefing.needsAttention.map(\.accountID) == [real.id])
        #expect(await client.calls == 0)
        #expect(model.state.remoteActionHistory.isEmpty)
    }
}
