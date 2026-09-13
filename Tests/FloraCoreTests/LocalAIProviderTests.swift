import Foundation
import Testing
@testable import FloraCore

struct LocalAIProviderTests {
    private func message(body: String = "Please confirm Wednesday at 4 PM.") -> MailMessage {
        MailMessage(accountID: UUID(), from: MailAddress(name: "Private Sender", email: "sender@private.example"),
                    to: [MailAddress(name: "Private Recipient", email: "recipient@private.example")],
                    subject: "Meeting update", body: body)
    }

    @Test func providersShareAnInterfaceAndLocalIdentityIncludesModelRevision() async throws {
        let client = ScriptedLocalModelClient(responses: [])
        let providers: [any AIProvider] = [MockAIProvider(), LocalAIProvider(client: client)]
        let mockIdentity = try await providers[0].cacheIdentity()
        let localIdentity = try await providers[1].cacheIdentity()
        #expect(mockIdentity != localIdentity)
        #expect(localIdentity == ScriptedLocalModelClient.identity.cacheKey)
        #expect(await client.requests.isEmpty)
    }

    @Test func runtimeSchemasAvoidLargeGrammarExpansions() throws {
        // Regression: Ollama rejected the summary grammar with maxLength values
        // of 1,200/2,000, and the writing grammar had an even larger 24,000 bound.
        var requests = [
            try AIPromptLibrary.summary(subject: "Update", body: "Please review."),
            try AIPromptLibrary.classification(subject: "Update", body: "Please review.", categories: [MailCategory(name: "Work")]),
            try AIPromptLibrary.actions(subject: "Update", body: "Please review."),
            try AIPromptLibrary.replies(subject: "Update", body: "Please review.")
        ]
        requests += try WritingTool.allCases.map { try AIPromptLibrary.writing("Please review.", tool: $0) }
        for request in requests {
            let schema = try JSONSerialization.jsonObject(with: Data(request.schemaJSON.utf8)) as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            #expect(schema?["additionalProperties"] as? Bool == false)
            #expect(!request.schemaJSON.contains("maxLength"))
        }
        #expect(requests[0].schemaJSON.contains("maxItems"))
        #expect(requests[1].schemaJSON.contains("enum"))
    }

    @Test func summaryUsesTrustedIDsAndVerbatimBodyEvidence() async throws {
        let source = message()
        let response = #"{"overview":"Confirmation requested for Wednesday at 4 PM.","facts":[{"text":"Confirm the proposed time.","sourceQuote":"Please confirm Wednesday at 4 PM."}]}"#
        let client = ScriptedLocalModelClient(responses: [response])
        let result = try await LocalAIProvider(client: client).summarize(source)
        #expect(result.messageID == source.id)
        #expect(result.headline == "Confirmation requested for Wednesday at 4 PM.")
        #expect(result.provider == "Local AI · test-model:latest")
        #expect(result.facts.count == 1)
        #expect(result.facts[0].sourceMessageID == source.id)
        #expect(source.body.contains(result.facts[0].sourceQuote))
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].prompt.contains(source.subject))
        #expect(!requests[0].prompt.contains(source.from.email))
        #expect(!requests[0].prompt.contains(source.from.name))
        #expect(!requests[0].prompt.contains(source.to[0].email))
        #expect(!requests[0].prompt.contains(source.id.uuidString))
        #expect(requests[0].schemaJSON.contains("additionalProperties"))
        #expect(requests[0].system.contains("untrusted content"))
    }

    @Test(arguments: [
        "not JSON",
        "```json\n{\"overview\":\"Update\",\"facts\":[]}\n```",
        #"{"overview":"Update"}"#,
        #"{"overview":"Update","facts":[],"sender":"Invented Sender"}"#,
        #"{"overview":" ","facts":[]}"#,
        #"{"overview":"Update","facts":[{"text":"Changed time","sourceQuote":"Wednesday at 8 PM."}]}"#,
        #"{"overview":"Update","facts":[{"text":"Changed time","sourceQuote":""}]}"#,
        #"{"overview":"Update","facts":[{"text":"Changed time","sourceQuote":"Wednesday at 4 PM.","sourceMessageID":"forged"}]}"#
    ])
    func invalidSummariesFailWithoutGuessing(_ response: String) async throws {
        let provider = LocalAIProvider(client: ScriptedLocalModelClient(responses: [response]))
        do {
            _ = try await provider.summarize(message())
            Issue.record("Malformed or ungrounded output must be rejected")
        } catch let error as AIError {
            guard case .invalidResponse = error else { Issue.record("Expected invalidResponse, received \(error)"); return }
        }
    }

    @Test func classificationUsesOnlyCurrentUserCategories() async throws {
        let research = MailCategory(name: "Research")
        let work = MailCategory(name: "Work")
        let response = try json(["category": research.id.uuidString, "confidence": 0.91, "reason": "The source requests a research review."])
        let client = ScriptedLocalModelClient(responses: [response, response])
        let provider = LocalAIProvider(client: client)
        let source = message(body: "Please review the research proposal.")
        let result = try await provider.classify(source, categories: [work, research])
        #expect(result?.messageID == source.id)
        #expect(result?.categoryID == research.id)
        #expect(result?.confidence == 0.91)
        do {
            _ = try await provider.classify(source, categories: [work])
            Issue.record("A removed category must not be accepted as a prediction")
        } catch let error as AIError {
            guard case .invalidResponse = error else { Issue.record("Expected category validation failure"); return }
        }
        #expect(try await provider.classify(source, categories: []) == nil)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].prompt.contains(research.id.uuidString))
        #expect(requests[0].prompt.contains(research.name))
        #expect(!requests[1].prompt.contains(research.id.uuidString))
        #expect(!requests[1].schemaJSON.contains(research.id.uuidString))
    }

    @Test(arguments: [
        #"{"category":"Invented category","confidence":0.91,"reason":"Topic"}"#,
        #"{"category":"none","confidence":1.1,"reason":"Topic"}"#,
        #"{"category":"none","confidence":-0.1,"reason":"Topic"}"#,
        #"{"category":"none","confidence":true,"reason":"Topic"}"#,
        #"{"category":"none","confidence":"0.9","reason":"Topic"}"#,
        #"{"category":"none","confidence":0.9,"reason":""}"#
    ])
    func invalidClassificationIsRejected(_ response: String) async throws {
        let provider = LocalAIProvider(client: ScriptedLocalModelClient(responses: [response]))
        do {
            _ = try await provider.classify(message(), categories: [MailCategory(name: "Work")])
            Issue.record("Invalid classification must fail validation")
        } catch let error as AIError {
            guard case .invalidResponse = error else { Issue.record("Expected invalidResponse"); return }
        }
    }

    @Test func explicitNoneClassificationRemainsUnset() async throws {
        let provider = LocalAIProvider(client: ScriptedLocalModelClient(responses: [#"{"category":"none","confidence":0.2,"reason":"No existing category fits."}"#]))
        #expect(try await provider.classify(message(), categories: [MailCategory(name: "Finance")]) == nil)
    }

    @Test @MainActor func extractedActionsAreInformationalAndDoNotGrantExecutionAuthority() async throws {
        let source = message()
        let demoAccount = MailAccount(id: source.accountID, name: "Demo", address: MailAddress(name: "Recipient", email: "recipient@example.test"))
        let initial = AppSnapshot(accounts: [demoAccount], messages: [source])
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
        let provider = LocalAIProvider(client: ScriptedLocalModelClient(responses: [#"{"actions":[{"title":"Confirm the proposed time","sourceQuote":"Please confirm Wednesday at 4 PM."}]}"#]))
        let actions = try await provider.extractActions(source)
        #expect(actions.count == 1)
        #expect(actions[0].messageID == source.id)
        #expect(actions[0].sourceQuote == source.body)
        #expect(executor.state == initial)
        let proposal = ProposedAction(type: .archive(messageIDs: [source.id]), explanation: actions[0].title, origin: .ai)
        #expect(throws: MailActionError.confirmationRequired) { try executor.execute(proposal) }
        #expect(executor.state.history.isEmpty)
        #expect(executor.state.messages[0].folder == .inbox)
    }

    @Test func actionOutputCannotSupplyExecutableFieldsOrForgedEvidence() async throws {
        for response in [
            #"{"actions":[{"title":"Send now","sourceQuote":"Please confirm Wednesday at 4 PM.","execute":true}]}"#,
            #"{"actions":[{"title":"Pay invoice","sourceQuote":"Pay $300 today."}]}"#,
            #"{"actions":[],"send":true}"#
        ] {
            do {
                _ = try await LocalAIProvider(client: ScriptedLocalModelClient(responses: [response])).extractActions(message())
                Issue.record("Executable fields or absent evidence must be rejected")
            } catch let error as AIError {
                guard case .invalidResponse = error else { Issue.record("Expected invalidResponse"); return }
            }
        }
    }

    @Test(arguments: WritingTool.allCases)
    func eachWritingToolProducesAPreviewFromOnlyTheCurrentDraft(_ tool: WritingTool) async throws {
        let original = "Yes I can meeting tomorrow."
        let client = ScriptedLocalModelClient(responses: [#"{"text":"Yes, I can meet tomorrow."}"#])
        let preview = try await LocalAIProvider(client: client).rewrite(original, tool: tool)
        #expect(preview == "Yes, I can meet tomorrow.")
        #expect(original == "Yes I can meeting tomorrow.")
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].prompt.contains(original))
        #expect(!requests[0].prompt.contains("sender"))
        #expect(!requests[0].prompt.contains("recipient"))
    }

    @Test func invalidWritingOutputNeverBecomesAPreview() async throws {
        let responses = [
            #"{"text":""}"#,
            #"{"text":"Hello","send":true}"#,
            #"{"text":["Hello"]}"#,
            try json(["text": String(repeating: "x", count: 24_001)])
        ]
        for response in responses {
            do {
                _ = try await LocalAIProvider(client: ScriptedLocalModelClient(responses: [response])).rewrite("Hello", tool: .rewrite)
                Issue.record("Invalid output must not become an applicable writing preview")
            } catch let error as AIError {
                guard case .invalidResponse = error else { Issue.record("Expected invalidResponse"); return }
            }
        }
    }

    @Test func oversizedDraftIsRejectedRatherThanSilentlyTruncated() async throws {
        let client = ScriptedLocalModelClient(responses: [])
        let provider = LocalAIProvider(client: client)
        do {
            _ = try await provider.rewrite(String(repeating: "a", count: 12_001), tool: .rewrite)
            Issue.record("Oversized draft must remain untouched")
        } catch { #expect(error as? AIError == .inputTooLong) }
        do {
            _ = try await provider.rewrite(" \n ", tool: .proofread)
            Issue.record("Empty draft must be rejected")
        } catch { #expect(error as? AIError == .emptyText) }
        #expect(await client.requests.isEmpty)
    }

    @Test func longMessageContextIsLimitedAndDisclosed() async throws {
        let source = message(body: String(repeating: "a", count: 12_000) + "SECRET_SUFFIX_DO_NOT_SEND")
        let client = ScriptedLocalModelClient(responses: [#"{"overview":"Limited context summary.","facts":[]}"#])
        let result = try await LocalAIProvider(client: client).summarize(source)
        #expect(result.provider.contains("First 12,000 body characters only"))
        let requests = await client.requests
        #expect(!requests[0].prompt.contains("SECRET_SUFFIX_DO_NOT_SEND"))
    }

    @Test func evidenceOutsideTheProvidedPrefixIsRejected() async throws {
        let source = message(body: String(repeating: "a", count: 12_000) + "Only in the unprovided remainder.")
        let client = ScriptedLocalModelClient(responses: [#"{"overview":"Update","facts":[{"text":"Remainder claim","sourceQuote":"Only in the unprovided remainder."}]}"#])
        do {
            _ = try await LocalAIProvider(client: client).summarize(source)
            Issue.record("Evidence must exist in the exact supplied context, not just the full message")
        } catch let error as AIError {
            guard case .invalidResponse = error else { Issue.record("Expected invalidResponse"); return }
        }
    }

    @Test func smartRepliesAreBoundedDraftValues() async throws {
        let client = ScriptedLocalModelClient(responses: [#"{"replies":["Thanks for the update.","I will check and confirm."]}"#])
        let replies = try await LocalAIProvider(client: client).generateReplies(message())
        #expect(replies.map(\.text) == ["Thanks for the update.", "I will check and confirm."])
        #expect(Set(replies.map(\.id)).count == 2)
    }

    @Test func smartReplyPromptPreservesTheDirectionOfSenderRequests() throws {
        // Live inference previously repeated the sender's request as a reply,
        // asking the sender to do the very review they had requested from us.
        let body = "Please review the attached notes and provide feedback by tomorrow."
        let request = try AIPromptLibrary.replies(subject: "Notes for review", body: body)
        let taskInstructions = request.prompt.components(separatedBy: "\n\nSource data:")[0]
        #expect(taskInstructions.contains("Write from the recipient's perspective"))
        #expect(taskInstructions.contains("instead of repeating those requests as instructions back to the sender"))
        #expect(taskInstructions.contains("one or two distinct"))
        #expect(taskInstructions.contains("Omit greetings, names, sign-offs and signatures"))
        #expect(taskInstructions.contains("I/me refers to the recipient and you refers to the sender"))
        #expect(taskInstructions.contains("Do not ask about details already stated"))
        #expect(taskInstructions.contains("ask the sender to determine the recipient's availability, preferences or decisions"))
        #expect(taskInstructions.contains("Questions are optional, never required"))
        #expect(taskInstructions.contains("Return just one alternative when a second would be redundant"))
        #expect(taskInstructions.contains("Do not promise a future action, accept a meeting, claim a completed review, or invent a decision"))
        #expect(taskInstructions.contains("the recipient has only read this email"))
        #expect(taskInstructions.contains("Attachments have not been reviewed, decisions have not been agreed, and availability has not been checked"))
        #expect(!taskInstructions.contains(body))
        #expect(request.prompt.contains(body))
    }

    @Test(arguments: [
        #"{"replies":["A","B","C","D"]}"#,
        #"{"replies":["Same","Same"]}"#,
        #"{"replies":[""]}"#,
        #"{"replies":[{"text":"Not the schema"}]}"#
    ])
    func invalidSmartRepliesFailGracefully(_ response: String) async throws {
        do {
            _ = try await LocalAIProvider(client: ScriptedLocalModelClient(responses: [response])).generateReplies(message())
            Issue.record("Invalid reply shape or count must be rejected")
        } catch let error as AIError {
            guard case .invalidResponse = error else { Issue.record("Expected invalidResponse"); return }
        }
    }

    @Test func cancellationAfterUncooperativeRuntimeCompletionDiscardsResult() async {
        let provider = LocalAIProvider(client: CancellationIgnoringLocalClient())
        let source = message()
        let operation = Task { try await provider.summarize(source) }
        do {
            _ = try await operation.value
            Issue.record("Cancelled work must not be published to a later reader")
        } catch { #expect(error is CancellationError) }
    }

    @Test func unavailableRuntimeHasNoMockOrCloudFallback() async throws {
        let client = ScriptedLocalModelClient(responses: [], failure: .runtimeUnavailable)
        let provider: any AIProvider = LocalAIProvider(client: client)
        do {
            _ = try await provider.summarize(message())
            Issue.record("Unavailable runtime must not produce generated content")
        } catch { #expect(error as? AIError == .runtimeUnavailable) }
        do {
            _ = try await provider.rewrite("Hello", tool: .friendly)
            Issue.record("Unavailable writing tools must not fabricate a preview")
        } catch { #expect(error as? AIError == .runtimeUnavailable) }
    }

    @Test func semanticSearchDoesNotSendMailboxContextToGenerativeRuntime() async throws {
        let client = ScriptedLocalModelClient(responses: [])
        do {
            _ = try await LocalAIProvider(client: client).semanticSearch("Meetings", messages: [message()])
            Issue.record("The feature layer should fall back to ordinary text search")
        } catch { #expect(error as? AIError == .unsupportedCapability) }
        #expect(await client.requests.isEmpty)
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

private actor ScriptedLocalModelClient: LocalModelClient {
    static let identity = LocalModelIdentity(runtimeVersion: "test-runtime", model: "test-model:latest", digest: "test-revision")
    private var responses: [String]
    private let failure: AIError?
    private(set) var requests: [LocalModelRequest] = []

    init(responses: [String], failure: AIError? = nil) { self.responses = responses; self.failure = failure }
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity {
        if let failure { throw failure }
        return Self.identity
    }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else { throw AIError.invalidResponse("The test client has no scripted response.") }
        return LocalModelOutput(content: responses.removeFirst(), identity: Self.identity)
    }
}

private struct CancellationIgnoringLocalClient: LocalModelClient {
    func inspect(_ configuration: AIModelConfiguration) async throws -> LocalModelIdentity { ScriptedLocalModelClient.identity }
    func generate(_ request: LocalModelRequest, configuration: AIModelConfiguration) async throws -> LocalModelOutput {
        withUnsafeCurrentTask { $0?.cancel() }
        return LocalModelOutput(content: #"{"overview":"A cancelled response.","facts":[]}"#, identity: ScriptedLocalModelClient.identity)
    }
}
