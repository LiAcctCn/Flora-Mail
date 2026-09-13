import Foundation
import Testing
@testable import FloraCore

struct AIProviderTests {
    private func message(subject: String = "Research proposal", body: String = "Please review the research proposal before Friday.") -> MailMessage {
        MailMessage(accountID: UUID(), from: MailAddress(name: "Nora Patel", email: "nora@example.test"), to: [], subject: subject, body: body)
    }

    @Test func classificationUsesOnlyExistingCategories() async throws {
        let provider = MockAIProvider()
        let research = MailCategory(name: "Research")
        let other = MailCategory(name: "Other")
        let categories = [research, other]
        let suggestion = try await provider.classify(message(), categories: categories)
        #expect(suggestion?.categoryID == research.id)
        #expect(suggestion?.explanation.contains("Mock AI") == true)
        // Deleting a category cannot cause the provider to recreate it or return its old ID.
        let afterDeletion = try await provider.classify(message(), categories: [other])
        #expect(afterDeletion == nil)
        #expect(try await provider.classify(message(), categories: []) == nil)
        #expect(categories == [research, other])
    }

    @Test func customCategoryCanBeSuggestedByItsName() async throws {
        let custom = MailCategory(name: "Photography")
        let suggestion = try await MockAIProvider().classify(
            message(subject: "Photography workshop", body: "The photography workshop starts next week."),
            categories: [custom]
        )
        #expect(suggestion?.categoryID == custom.id)
    }

    @Test func summaryAndActionsContainVerbatimEvidence() async throws {
        let original = message(subject: "Meeting update", body: """
        Hi Alex,

        Our meeting has moved to 3:00 PM tomorrow.
        Please confirm your availability.
        We will meet in Room 214 for 30 minutes.

        Best,
        Nora

        --- Previous message ---
        Our meeting is at 2:00 PM.
        """)
        let provider = MockAIProvider()
        let summary = try await provider.summarize(original)
        let actions = try await provider.extractActions(original)
        #expect(summary.messageID == original.id)
        #expect(summary.provider.contains("Mock AI"))
        #expect(!summary.facts.isEmpty)
        #expect(summary.facts.allSatisfy { original.body.contains($0.sourceQuote) && $0.sourceMessageID == original.id && $0.text == $0.sourceQuote })
        #expect(!summary.facts.contains { $0.text.contains("2:00 PM") })
        #expect(actions.count == 1)
        #expect(actions.first?.sourceQuote == "Please confirm your availability.")
        #expect(actions.allSatisfy { original.body.contains($0.sourceQuote) && $0.messageID == original.id })
    }

    @Test func informationalMailDoesNotInventAnAction() async throws {
        let informational = message(subject: "Receipt", body: "Your payment was received. No action is required. Please do not reply to this automated message.")
        let actions = try await MockAIProvider().extractActions(informational)
        #expect(actions.isEmpty)
    }

    @Test func writingToolsProvideUsablePreviewWithoutMutatingOriginal() async throws {
        let provider = MockAIProvider()
        let original = "Hi John,\n\nYes I can meeting tomorrow. Thanks for the update."
        let proofread = try await provider.rewrite(original, tool: .proofread)
        #expect(proofread == "Hi John,\n\nYes, I can meet tomorrow. Thanks for the update.")
        #expect(original.contains("can meeting"))
        let professional = try await provider.rewrite(original, tool: .professional)
        #expect(professional.hasPrefix("Hello John,"))
        #expect(professional.contains("Thank you for the update."))
        let concise = try await provider.rewrite("I wanted to let you know that I can meet tomorrow in order to review the very detailed plan.", tool: .concise)
        #expect(concise == "I can meet tomorrow to review the detailed plan.")
    }

    @Test func emptyWritingInputHasClearFailure() async throws {
        do {
            _ = try await MockAIProvider().rewrite(" \n ", tool: .proofread)
            Issue.record("Empty text should not produce a fabricated reply")
        } catch {
            #expect(error as? AIError == .emptyText)
        }
    }

    @Test func localProviderDoesNotSilentlyUseMockOrCloud() async throws {
        let provider: any AIProvider = LocalAIProvider(client: UnavailableTestLocalModelClient())
        do {
            _ = try await provider.summarize(message())
            Issue.record("Local AI must report an unavailable runtime")
        } catch {
            #expect(error as? AIError == .modelUnavailable)
            #expect(error.localizedDescription.contains("No mail was sent"))
        }
        do {
            _ = try await provider.rewrite("Hello Alex", tool: .professional)
            Issue.record("Local writing must not silently fall back")
        } catch {
            #expect(error as? AIError == .modelUnavailable)
        }
    }

    @Test func mockProviderHonorsCancellation() async {
        let original = message()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MockAIProvider().summarize(original)
        }
        do {
            _ = try await operation.value
            Issue.record("A cancelled summary request must stop")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func localProviderHonorsCancellationBeforeUnavailableState() async {
        let original = message()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalAIProvider(client: UnavailableTestLocalModelClient()).summarize(original)
        }
        do {
            _ = try await operation.value
            Issue.record("A cancelled local request must stop")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func semanticDemoSearchExpandsTermsButRequiresEvidence() async throws {
        let meeting = message(subject: "Project appointment", body: "John requested an appointment tomorrow.")
        let unrelated = message(subject: "Lunch tomorrow", body: "Nora will bring lunch tomorrow.")
        let provider = MockAIProvider()
        let matches = try await provider.semanticSearch("John meeting", messages: [meeting, unrelated])
        #expect(matches == [meeting.id])
        #expect(try await provider.semanticSearch("John invoice", messages: [meeting, unrelated]).isEmpty)
        #expect(try await provider.semanticSearch("show me emails", messages: [meeting, unrelated]).isEmpty)
    }

    @Test func fixturesCoverTheVerticalSliceAndHaveConsistentRelationships() {
        let now = Date(timeIntervalSince1970: 1_789_257_600)
        let snapshot = DemoFixtures.makeSnapshot(now: now)
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.messages.count == 16)
        #expect(snapshot.accounts.allSatisfy { $0.provider == "Demo" })
        let accountIDs = Set(snapshot.accounts.map(\.id))
        let categoryIDs = Set(snapshot.categories.map(\.id))
        #expect(snapshot.messages.allSatisfy { accountIDs.contains($0.accountID) })
        #expect(snapshot.messages.allSatisfy { $0.categoryID == nil || categoryIDs.contains($0.categoryID ?? UUID()) })
        #expect(snapshot.messages.allSatisfy { $0.date <= now })
        #expect(Set(snapshot.messages.map(\.folder)) == [.inbox, .archive, .sent, .trash])
        #expect(snapshot.drafts.count == 1)
        #expect(snapshot.drafts.first?.body.contains("can meeting") == true)
        #expect(snapshot.messages.contains { $0.id == snapshot.drafts.first?.replyToMessageID })
        #expect(snapshot.messages.filter { $0.isFlagged && $0.folder == .inbox }.count == 3)
        #expect(snapshot.categories.map(\.name) == ["School", "Work", "Finance", "Shopping", "Travel", "Research", "Other"])
    }
}

private struct UnavailableTestLocalModelClient: LocalModelClient {
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { throw AIError.modelUnavailable }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput { throw AIError.modelUnavailable }
}
