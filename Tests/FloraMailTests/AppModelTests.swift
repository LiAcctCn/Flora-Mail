import Foundation
import Testing
@testable import FloraCore
@testable import FloraMail

@MainActor
struct AppModelTests {
    @Test func unsavedDraftBaselineComesFromPersistenceRatherThanReopenedText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        #expect(!model.draftHasUnsavedChanges(Draft()))
        let saved = try #require(model.state.drafts.first)
        #expect(!model.draftHasUnsavedChanges(saved))
        var edited = saved
        edited.body += "\nKeep these unsaved edits."
        #expect(model.draftHasUnsavedChanges(edited))
        let source = try #require(model.state.messages.first)
        model.compose(replyTo: source, suggestedText: "Thanks for the update.")
        let smartReply = try #require(model.composingDraft)
        #expect(model.draftHasUnsavedChanges(smartReply))
        model.composingDraft = nil
        model.compose(replyTo: source, forward: true)
        let forward = try #require(model.composingDraft)
        #expect(model.draftHasUnsavedChanges(forward))
    }

    @Test(arguments: [false, true])
    func cancelledTerminationRestoresEditsAcrossEitherDismissalOrdering(alreadyDismissed: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        let saved = try #require(model.state.drafts.first)
        var edited = saved
        edited.body += "\nThese words were never saved."
        model.editDraft(saved)
        model.updateEditorDraft(edited, isDirty: true)
        if alreadyDismissed {
            model.composingDraft = nil
            model.clearEditorDraft(id: saved.id)
        }
        model.restoreEditorAfterCancelledTermination(edited)
        model.compose()
        model.editDraft(Draft(subject: "Must not replace pending recovery"))
        #expect(model.composingDraft == nil)
        if !alreadyDismissed { model.clearEditorDraft(id: saved.id) }
        await nextMainQueueTurn()
        #expect(model.composingDraft == edited)
        #expect(model.editorDraft == edited)
        #expect(model.editorIsDirty)
        #expect(model.draftHasUnsavedChanges(edited))
        #expect(model.state.drafts.first { $0.id == saved.id } == saved)
        // The restored appearance consumes recovery; a later normal dismissal
        // must not automatically reopen the composer again.
        model.updateEditorDraft(edited, isDirty: model.draftHasUnsavedChanges(edited))
        model.composingDraft = nil
        model.clearEditorDraft(id: saved.id)
        await nextMainQueueTurn()
        #expect(model.composingDraft == nil)
        #expect(model.editorDraft == nil)
    }

    @Test func failedSaveRestoresUnsavedTextAndKeepsRecoveryErrorInComposer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("mail.json")
        let model = AppModel(storageURL: storeURL, localClient: GatedLocalClient())
        let draft = Draft(to: "alex@example.test", subject: "Unsaved message", body: "Preserve this text on failure.")
        // Make the test repository unwritable without changing permissions or
        // any user data: atomic file replacement cannot replace a directory.
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: false)
        #expect(!model.saveDraft(draft))
        let failure = try #require(model.errorMessage)
        model.errorMessage = nil
        model.restoreEditorAfterCancelledTermination(draft, recoveryError: failure)
        await nextMainQueueTurn()
        #expect(model.composingDraft == draft)
        #expect(model.editorIsDirty)
        #expect(model.draftHasUnsavedChanges(draft))
        #expect(!model.state.drafts.contains { $0.id == draft.id })
        #expect(model.editorRecoveryError == failure)
        #expect(model.errorMessage == nil)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func informationalStatusDoesNotOfferUndoForAnUnrelatedMailAction() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        let source = try #require(model.state.messages.first { $0.folder == .inbox })
        model.archive(source)
        #expect(model.statusOffersUndo)
        #expect(model.saveLocalConfiguration(AIModelConfiguration(model: "test-model:small")))
        #expect(!model.statusOffersUndo)
        #expect(model.canUndo) // Activity and the mail Undo command still work.
        model.undo()
        #expect(model.state.messages.first { $0.id == source.id }?.folder == .inbox)
        #expect(!model.statusOffersUndo)
    }

    @Test func acceptedClassificationAndConfigurationSurviveRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("mail.json")
        let model = AppModel(storageURL: storeURL, localClient: GatedLocalClient())
        let source = try #require(model.state.messages.first { $0.subject == "PHYS 204 · Assignment deadline extended" })
        let prediction = try #require(try await model.classification(for: source))
        #expect(model.acceptClassification(prediction))
        let customCategory = MailCategory(name: "Personal Projects")
        #expect(model.perform(ProposedAction(type: .createCategory(customCategory), explanation: "Created a user category.")))
        model.toggleRead(source)
        model.archive(source)
        let configuration = AIModelConfiguration(endpoint: "http://127.0.0.1:11435", model: "test-model:small", timeoutSeconds: 45)
        #expect(model.saveLocalConfiguration(configuration))
        model.updateAIMode(.local)

        let reopened = AppModel(storageURL: storeURL, localClient: GatedLocalClient())
        let persisted = try #require(reopened.state.messages.first { $0.id == source.id })
        #expect(persisted.categoryID == prediction.categoryID)
        #expect(persisted.isRead)
        #expect(persisted.folder == .archive)
        #expect(reopened.state.categories.contains(customCategory))
        #expect(reopened.state.preferences.aiMode == .local)
        #expect(reopened.state.preferences.localAI == configuration)
        let durableHistory = model.state.history.map { entry in
            var entry = entry
            entry.canUndo = false
            return entry
        }
        #expect(reopened.state.history == durableHistory)
        #expect(!reopened.state.history.isEmpty)
        #expect(reopened.storageWarning == nil)
        // Navigation and the inverse stack are deliberately session state.
        #expect(reopened.destination == .today)
        #expect(reopened.selectedMessageID == nil)
        #expect(!reopened.canUndo)
    }

    @Test func changingAIModePreservesSavedLocalConfiguration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        let configuration = AIModelConfiguration(endpoint: "http://127.0.0.1:11436", model: "test-model:custom", timeoutSeconds: 95)
        #expect(model.saveLocalConfiguration(configuration))
        for mode in [AIMode.local, .off, .mock, .local] {
            model.updateAIMode(mode)
            #expect(model.state.preferences.aiMode == mode)
            #expect(model.state.preferences.localAI == configuration)
        }
    }

    @Test func invalidLocalConfigurationDoesNotChangeStateOrStorage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("mail.json")
        let model = AppModel(storageURL: storeURL, localClient: GatedLocalClient())
        let before = model.state
        let persistedBefore = try Data(contentsOf: storeURL)
        let requestIdentity = model.aiRequestIdentity
        #expect(!model.saveLocalConfiguration(AIModelConfiguration(endpoint: "https://external.example", model: "cloud-model")))
        #expect(model.state == before)
        #expect(try Data(contentsOf: storeURL) == persistedBefore)
        #expect(model.aiRequestIdentity == requestIdentity)
        #expect(model.errorMessage?.contains("configuration is invalid") == true)
    }

    @Test func cancelledSummaryDoesNotPublishOrCacheIntoAnotherSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GatedLocalClient()
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: client)
        model.updateAIMode(.local)
        let source = try #require(model.state.messages.first { $0.folder == .inbox })
        let next = try #require(model.state.messages.first { $0.folder == .inbox && $0.id != source.id })
        model.openMessage(source.id)
        let pending = Task { try await model.summary(for: source) }
        await client.waitUntilGenerationStarted()
        model.openMessage(next.id)
        pending.cancel()
        await client.releaseGeneration()
        do {
            _ = try await pending.value
            Issue.record("A summary completed after its reader request was cancelled")
        } catch { #expect(error is CancellationError) }

        #expect(model.selectedMessageID == next.id)
        #expect(model.state.summaries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ai-cache.json").path))
        let nextSummary = try await model.summary(for: next)
        #expect(nextSummary.messageID == next.id)
        #expect(model.state.summaries.map(\.messageID) == [next.id])
        #expect(await client.generationCount == 2)
    }

    @Test func localOffLocalRoundTripRejectsAnOlderResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GatedLocalClient()
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: client)
        model.updateAIMode(.local)
        let source = try #require(model.state.messages.first)
        let originalRequestIdentity = model.aiRequestIdentity
        let pending = Task { try await model.summary(for: source) }
        await client.waitUntilGenerationStarted()
        model.updateAIMode(.off)
        model.updateAIMode(.local)
        #expect(model.aiRequestIdentity != originalRequestIdentity)
        await client.releaseGeneration()
        do {
            _ = try await pending.value
            Issue.record("Matching the mode name again must not revive an obsolete request")
        } catch { #expect(error is CancellationError) }
        #expect(model.state.summaries.isEmpty)
        #expect(model.localConnectionState == "Not tested")
        #expect(model.errorMessage == nil)
    }

    @Test func cancelledProviderFailureCannotOverwriteNewerConnectionStatus() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GatedLocalClient(generationFailure: .invalidResponse("Late failure from a cancelled request."))
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: client)
        model.updateAIMode(.local)
        let source = try #require(model.state.messages.first)
        let pending = Task { try await model.summary(for: source) }
        await client.waitUntilGenerationStarted()
        pending.cancel()
        await model.testLocalConnection()
        #expect(model.localConnectionState == "Connected")
        let connectionMessage = model.localConnectionMessage
        await client.releaseGeneration()
        do {
            _ = try await pending.value
            Issue.record("A cancelled provider failure must be treated as cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(model.localConnectionState == "Connected")
        #expect(model.localConnectionMessage == connectionMessage)
        #expect(model.state.summaries.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func savedConfigurationChangeRejectsAnOlderResponse() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = GatedLocalClient()
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: client)
        model.updateAIMode(.local)
        let source = try #require(model.state.messages.first)
        let pending = Task { try await model.summary(for: source) }
        await client.waitUntilGenerationStarted()
        #expect(model.saveLocalConfiguration(AIModelConfiguration(model: "replacement-model:small")))
        await client.releaseGeneration()
        do {
            _ = try await pending.value
            Issue.record("A response from the previous model configuration must not be published")
        } catch { #expect(error is CancellationError) }
        #expect(model.state.summaries.isEmpty)
        #expect(model.state.preferences.localAI.model == "replacement-model:small")
        #expect(model.localConnectionState == "Not tested")
    }

    @Test func filteringAndCategoryRemovalReconcileSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        let inboxMessage = try #require(model.state.messages.first { $0.folder == .inbox })
        model.openMessage(inboxMessage.id)
        model.searchText = "text-that-is-absent-from-every-demo-message-492804"
        model.reconcileSelection()
        #expect(model.visibleMessages.isEmpty)
        #expect(model.selectedMessageID == nil)

        let category = try #require(model.state.categories.first)
        #expect(model.perform(ProposedAction(type: .classify(messageID: inboxMessage.id, categoryID: category.id), explanation: "Set category manually.")))
        model.navigate(.category(category.id))
        model.openMessage(inboxMessage.id)
        #expect(model.destination == .category(category.id))
        #expect(model.selectedMessageID == inboxMessage.id)
        #expect(model.perform(ProposedAction(type: .deleteCategory(id: category.id), explanation: "Removed category.")))
        #expect(model.destination == .folder(.inbox))
        #expect(model.selectedMessageID == nil)
        #expect(model.searchText.isEmpty)
        #expect(!model.state.categories.contains { $0.id == category.id })
    }

    @Test func unavailableLocalAILeavesTextSearchAndMailActionsUsable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: UnavailableLocalClient())
        model.updateAIMode(.local)
        let source = try #require(model.state.messages.first { $0.subject == "PHYS 204 · Assignment deadline extended" })
        model.openMessage(source.id)
        do {
            _ = try await model.summary(for: source)
            Issue.record("Unavailable Local AI must not return mock content")
        } catch { #expect(error as? AIError == .runtimeUnavailable) }
        #expect(model.localConnectionState == "Unavailable")
        #expect(model.state.summaries.isEmpty)
        #expect(model.selectedMessage?.body == source.body)

        model.searchText = "PHYS 204"
        #expect(model.visibleMessages.contains { $0.id == source.id })
        let fallback = try await model.assistantSearch("PHYS 204")
        #expect(fallback.notice.contains("text matches"))
        #expect(fallback.messages.contains { $0.id == source.id })
        model.archive(source)
        #expect(model.state.messages.first { $0.id == source.id }?.folder == .archive)
        model.undo()
        #expect(model.state.messages.first { $0.id == source.id }?.folder == .inbox)
        model.compose(replyTo: source)
        #expect(model.composingDraft?.replyToMessageID == source.id)
    }

    @Test func composerCommandsAndLifecycleCannotReplaceAnotherOpenDraft() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(storageURL: directory.appendingPathComponent("mail.json"), localClient: GatedLocalClient())
        model.compose()
        let original = try #require(model.composingDraft)
        var edited = original
        edited.body = "Keep these unsaved words."
        model.updateEditorDraft(edited, isDirty: true)
        let other = Draft(to: "other@example.test", subject: "Different draft", body: "Different words")
        model.editDraft(other)
        let replySource = try #require(model.state.messages.first)
        model.compose(replyTo: replySource, suggestedText: "Another reply")
        #expect(model.composingDraft?.id == original.id)
        #expect(model.editorDraft == edited)
        #expect(model.editorIsDirty)
        model.clearEditorDraft(id: other.id)
        #expect(model.editorDraft == edited)
        model.clearEditorDraft(id: original.id)
        #expect(model.editorDraft == nil)
        #expect(!model.editorIsDirty)
        model.composingDraft = nil
        model.editDraft(other)
        #expect(model.composingDraft == other)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraMail-AppModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct UnavailableLocalClient: LocalModelClient {
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { throw AIError.runtimeUnavailable }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput { throw AIError.runtimeUnavailable }
}

/// The test controls completion explicitly. This client deliberately ignores
/// cancellation while generating, so the provider/app boundary must discard it.
private actor GatedLocalClient: LocalModelClient {
    private let generationFailure: AIError?
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var generationCount = 0

    init(generationFailure: AIError? = nil) { self.generationFailure = generationFailure }

    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity {
        identity(configuration)
    }

    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        generationCount += 1
        started = true
        let waitingForStart = startWaiters
        startWaiters.removeAll()
        waitingForStart.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { generationWaiters.append($0) }
        }
        if let generationFailure { throw generationFailure }
        return LocalModelOutput(content: #"{"overview":"A local summary for the selected source.","facts":[]}"#, identity: identity(configuration))
    }

    func waitUntilGenerationStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseGeneration() {
        released = true
        let waitingForRelease = generationWaiters
        generationWaiters.removeAll()
        waitingForRelease.forEach { $0.resume() }
    }

    private func identity(_ configuration: AIModelConfiguration) -> LocalModelIdentity {
        LocalModelIdentity(runtimeVersion: "0.34.0", model: configuration.model, digest: String(repeating: "a", count: 64))
    }
}
