import Foundation
import Testing
@testable import FloraCore
@testable import FloraMail

private actor ResearchUnavailableClient: LocalModelClient {
    private(set) var calls = 0
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { calls += 1; throw AIError.runtimeUnavailable }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput { calls += 1; throw AIError.runtimeUnavailable }
}

@MainActor
struct ResearchModePresentationTests {
    @Test func modesPreserveMailAndLevelOneCannotApplyAISuggestions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraResearchModes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        let client = ResearchUnavailableClient()
        let model = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        let source = try #require(model.state.messages.first { $0.categoryID == nil && $0.subject.contains("PHYS") })
        model.updateAIMode(.local); model.setResearchMode(.traditional)
        #expect(!model.aiEnabled && !model.embeddedAIEnabled)
        do { _ = try await model.summary(for: source); Issue.record("Traditional mode dispatched AI") } catch { #expect(error is AppError) }
        #expect(await client.calls == 0)
        model.openMessage(source.id); model.archive(source); model.undo()
        #expect(model.state.messages.first { $0.id == source.id }?.folder == .inbox)
        model.setResearchMode(.chatFirst)
        #expect(model.aiEnabled && !model.embeddedAIEnabled)
        model.setResearchMode(.hybrid); model.updateAIMode(.mock); model.setAutomationLevel(.information)
        let suggestion = try #require(try await model.classification(for: source))
        #expect(!model.canAcceptAISuggestions)
        #expect(!model.acceptClassification(suggestion))
        #expect(model.state.messages.first { $0.id == source.id }?.categoryID == nil)
        model.setAutomationLevel(.suggestion)
        #expect(model.canAcceptAISuggestions && model.embeddedAIEnabled)
        model.setAutomationLevel(.manual)
        #expect(!model.aiEnabled)
        #expect(model.dailyBriefing.needsAttention.allSatisfy { $0.signals.allSatisfy { $0.provenance == .mailState } })
        let reopened = AppModel(storageURL: url, localClient: client, credentials: MemoryCredentialStore())
        #expect(reopened.state.preferences.automationLevel == .manual)
        #expect(reopened.state.preferences.researchMode == .hybrid)
        #expect(!reopened.research.isEnabled)
        #expect(reopened.state.messages.count == model.state.messages.count)
    }

    @Test func contentFreeRecordingStopsEvenWhenPreferenceSaveFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMetricsOptOut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.json")
        let model = AppModel(storageURL: url, credentials: MemoryCredentialStore())
        #expect(!model.research.isEnabled)
        model.setResearchMetricsEnabled(true)
        #expect(model.research.isEnabled)
        model.research.startTask(.composeAndRewrite)
        let privateText = "PRIVATE_RESEARCH_SENTINEL_NEVER_RECORD"
        model.searchText = privateText
        model.report(NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: privateText]))
        let accountID = try #require(model.state.accounts.first?.id)
        #expect(model.saveDraft(Draft(to: "fictional@example.test", subject: privateText, body: privateText, accountID: accountID)))
        let data = try model.research.exportData()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(privateText) && !json.contains("fictional@example.test") && !json.contains(accountID.uuidString))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        model.setResearchMetricsEnabled(false)
        #expect(!model.research.isEnabled)
        #expect(model.researchOptOutSavePending)
        let stoppedCount = model.research.eventCount
        model.recordResearch(.compose); model.report(NSError(domain: "Fixture", code: 2))
        #expect(model.research.eventCount == stoppedCount)
        #expect(model.research.activeTask == nil)
        try FileManager.default.removeItem(at: url)
        try JSONMailRepository(url: url).save(model.state)
        model.setResearchMode(.chatFirst)
        #expect(!model.research.isEnabled) // Changing modes cannot undo this session's opt-out.
        #expect(model.research.eventCount == stoppedCount)
        model.setResearchMetricsEnabled(false)
        #expect(!model.state.preferences.researchMetricsEnabled)
        #expect(!model.researchOptOutSavePending)
        #expect(model.research.eventCount == stoppedCount)
    }

    @Test func explicitRecordingRetryPreservesMetricsAfterAStorageFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMetricsRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("fixture.json"), credentials: MemoryCredentialStore())
        model.setResearchMetricsEnabled(true)
        model.recordResearch(.navigation)
        let saved = try model.research.exportData()
        let before = try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: saved)
        let metricsURL = directory.appendingPathComponent("research-metrics.json")
        try FileManager.default.removeItem(at: metricsURL)
        try FileManager.default.createDirectory(at: metricsURL, withIntermediateDirectories: false)
        model.recordResearch(.search)
        #expect(!model.research.isEnabled)
        #expect(model.research.errorMessage != nil)
        try FileManager.default.removeItem(at: metricsURL)
        try saved.write(to: metricsURL)
        // The Off toggle and Retry Recording button both call this explicit path.
        model.setResearchMetricsEnabled(true)
        #expect(model.research.isEnabled)
        #expect(model.research.errorMessage == nil)
        let resumed = try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: model.research.exportData())
        #expect(Array(resumed.events.prefix(before.events.count)) == before.events)
        #expect(resumed.events.count == before.events.count + 1)
    }

    @Test func recoveryMarkersCannotCarryActivityAcrossConsentModesOrClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraRecoveryMetrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("fixture.json"), credentials: MemoryCredentialStore())
        let accountID = try #require(model.state.accounts.first?.id)
        func saveMail() throws {
            #expect(model.saveDraft(Draft(to: "fixture@example.test", subject: "Fictional draft", body: "Fixture body", accountID: accountID)))
        }
        func metrics() throws -> ResearchMetricsSnapshot {
            try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: model.research.exportData())
        }
        let failure = NSError(domain: "Fictional research fixture", code: 1)
        model.report(failure) // Before consent: no bookkeeping may carry forward.
        model.setResearchMetricsEnabled(true)
        try saveMail()
        #expect(try metrics().count(.error) == 0)
        #expect(try metrics().count(.errorRecovery) == 0)

        model.report(failure)
        model.setResearchMode(.chatFirst)
        try saveMail()
        #expect(try metrics().count(.error) == 1)
        #expect(try metrics().count(.errorRecovery) == 0)

        model.report(failure)
        model.research.clear()
        try saveMail()
        #expect(try metrics().count(.error) == 0)
        #expect(try metrics().count(.errorRecovery) == 0)

        model.report(failure)
        model.setResearchMetricsEnabled(false)
        model.setResearchMetricsEnabled(true)
        try saveMail()
        #expect(try metrics().count(.errorRecovery) == 0)

        model.report(failure)
        try saveMail()
        #expect(try metrics().count(.errorRecovery) == 1)
    }

}
