import Foundation
import XCTest
@testable import FloraCore

@MainActor
private final class AutomationSafetyRepository: MailRepository {
    var snapshot: AppSnapshot?
    var failWrites = false
    func load() throws -> AppSnapshot? { snapshot }
    func save(_ snapshot: AppSnapshot) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        self.snapshot = snapshot
    }
}

@MainActor
private final class AutomationSafetyWriter: RemoteMailWriter {
    let accountID: UUID
    var calls = 0
    var response: (AuthorizedRemoteAction) throws -> RemoteActionReceipt
    init(accountID: UUID, response: @escaping (AuthorizedRemoteAction) throws -> RemoteActionReceipt) {
        self.accountID = accountID; self.response = response
    }
    func execute(_ request: AuthorizedRemoteAction) async throws -> RemoteActionReceipt {
        calls += 1; return try response(request)
    }
}

@MainActor
final class AutomationSafetyTests: XCTestCase {
    private struct Fixture {
        let repository: AutomationSafetyRepository
        let executor: ActionExecutor
        let coordinator: AutomationCoordinator
        let rule: AutomationRule
    }
    private func fixture(level: AutomationLevel = .rules, count: Int = 2, remote: Bool = false, now: @escaping () -> Date = Date.init) throws -> Fixture {
        let account = MailAccount(name: "Fictional scoped account", address: MailAddress(name: "Reader", email: "reader@example.test"), providerType: remote ? .gmail : .demo,
                                  credentialReference: remote ? MailCredentialReference(id: "fictional-keychain-reference") : nil,
                                  oauthAccessLevel: .readWrite, writePermission: .userAuthorized, writeAuthorizedAt: .distantPast)
        let messages = (0..<count).map { index in
            MailMessage(providerID: "fixture-\(index)", accountID: account.id, from: MailAddress(name: "Newsletter", email: "news@example.test"), to: [account.address],
                        subject: "Update \(index)", body: "Fictional message for bounded scope testing.", date: now().addingTimeInterval(-Double(40 + index) * 86_400))
        }
        let state = AppSnapshot(accounts: [account], messages: messages, categories: [MailCategory(name: "Research")], preferences: UserPreferences(automationLevel: level))
        let repository = AutomationSafetyRepository()
        let executor = ActionExecutor(repository: repository, initialState: state, now: now)
        let rule = try executor.saveAutomationRule(AutomationRule(name: "Read older newsletters", senderEmail: "news@example.test", olderThanDays: 30, enabled: true,
                                                                  accountID: account.id, action: .markRead, maxMessages: 10, expiresAt: now().addingTimeInterval(86_400)), confirmed: true)
        return Fixture(repository: repository, executor: executor, coordinator: AutomationCoordinator(executor: executor, now: now), rule: rule)
    }
    private func demoReceipt(_ capability: AuthorizedAutomationDispatch, executor: ActionExecutor) throws -> AutomationDispatchReceipt {
        AutomationDispatchReceipt(actionID: try executor.executeAutomation(capability).id, isRemote: false)
    }
    private func expectFailure(_ expected: AutomationError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Unauthorized run succeeded", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutomationError, expected, file: file, line: line) }
    }

    func testInformationLevelsNeverAuthorizeRulesAndManualControlsStillWork() async throws {
        XCTAssertEqual(AutomationLevel.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(AutomationAction.allCases), Set([.archive, .markRead]))
        for level in [AutomationLevel.manual, .information, .suggestion] {
            let f = try fixture()
            try f.executor.updatePreferences(UserPreferences(automationLevel: level))
            XCTAssertThrowsError(try f.executor.saveAutomationRule(f.rule, confirmed: true)) { XCTAssertEqual($0 as? AutomationError, .levelNotAllowed) }
            let preview = try f.coordinator.preview(rule: f.rule)
            await expectFailure(.levelNotAllowed) {
                try await f.coordinator.run(preview: preview) { _ in XCTFail("Low-level dispatch"); throw AutomationError.invalidScope }
            }
            try f.executor.execute(ProposedAction(type: .archive(messageIDs: [preview.messageIDs[0]]), explanation: "Manual archive"))
            XCTAssertEqual(f.executor.state.messages.first { $0.id == preview.messageIDs[0] }?.folder, .archive)
            XCTAssertTrue(f.executor.state.automationRuns.isEmpty)
        }
    }

    func testManualInformationAndTraditionalModesRejectEvenConfirmedAIMutations() throws {
        for preferences in [UserPreferences(automationLevel: .manual), UserPreferences(automationLevel: .information), UserPreferences(researchMode: .traditional)] {
            let f = try fixture()
            try f.executor.updatePreferences(preferences)
            let action = ProposedAction(type: .classify(messageID: f.executor.state.messages[0].id, categoryID: f.executor.state.categories[0].id), explanation: "AI suggestion", origin: .ai)
            XCTAssertThrowsError(try f.executor.execute(action, confirmed: true)) { XCTAssertEqual($0 as? MailActionError, .assistanceDisabled) }
            var manual = action; manual.origin = .user
            try f.executor.execute(manual)
            XCTAssertNotNil(f.executor.state.messages[0].categoryID)
        }
    }

    func testScopeRejectsMissingAccountWildcardDisplayNameAndUnboundedLimits() throws {
        let f = try fixture()
        for violation in ["account", "wildcard", "display-name", "age", "limit"] {
            var rule = f.rule
            switch violation {
            case "account": rule.accountID = UUID()
            case "wildcard": rule.senderEmail = "*@example.test"
            case "display-name": rule.senderEmail = "Newsletter <news@example.test>"
            case "age": rule.olderThanDays = 0
            default: rule.maxMessages = 51
            }
            XCTAssertThrowsError(try f.coordinator.preview(rule: rule), violation)
        }
    }

    func testMatchingIsAccountSenderInboxAgeAndBoundedOldestFirst() throws {
        let f = try fixture(count: 4), now = Date()
        var snapshot = f.executor.state
        var wrongAccount = snapshot.messages[0]; wrongAccount.id = UUID(); wrongAccount.accountID = UUID()
        var wrongSender = snapshot.messages[0]; wrongSender.id = UUID(); wrongSender.from.email = "other@example.test"
        var recent = snapshot.messages[0]; recent.id = UUID(); recent.date = now
        var sent = snapshot.messages[0]; sent.id = UUID(); sent.folder = .sent
        var read = snapshot.messages[0]; read.id = UUID(); read.isRead = true
        snapshot.messages += [wrongAccount, wrongSender, recent, sent, read]
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: snapshot)
        let coordinator = AutomationCoordinator(executor: executor)
        var rule = f.rule; rule.maxMessages = 2
        let preview = try coordinator.preview(rule: rule)
        XCTAssertEqual(preview.totalMatchingCount, 4)
        XCTAssertEqual(preview.messageIDs, snapshot.messages.prefix(4).sorted { $0.date < $1.date }.prefix(2).map(\.id))
    }

    func testReusableRuleRequiresCurrentAuthorizationAndRecordsRealDemoUndo() async throws {
        let f = try fixture()
        let preview = try f.coordinator.preview(rule: f.rule)
        let record = try await f.coordinator.run(preview: preview) { try self.demoReceipt($0, executor: f.executor) }
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.completedMessageIDs, preview.messageIDs)
        XCTAssertEqual(f.executor.state.history.count, 2)
        XCTAssertTrue(f.executor.state.history.allSatisfy { $0.proposal.origin == .automation && $0.canUndo })
        XCTAssertTrue(f.executor.canUndo)
        try f.executor.undo()
        XCTAssertEqual(f.executor.state.messages.filter(\.isRead).count, 1)
        XCTAssertTrue(f.executor.state.history.last?.undone == true)
        // Reusable scope can be deliberately run again after a fresh preview.
        try await f.coordinator.run(preview: f.coordinator.preview(rule: f.rule)) { try self.demoReceipt($0, executor: f.executor) }
        XCTAssertEqual(f.executor.state.automationRuns.count, 2)
    }

    func testDelegationRequiresEnabledAuthorizedUnexpiredRuleAndBoundedExpiry() throws {
        let time = Date()
        for condition in ["disabled", "unauthorized", "future-authorization", "expired", "missing-expiry"] {
            let f = try fixture(level: .delegated, now: { time })
            var snapshot = f.executor.state
            switch condition {
            case "disabled": snapshot.rules[0].enabled = false
            case "unauthorized": snapshot.rules[0].authorizedAt = nil
            case "future-authorization": snapshot.rules[0].authorizedAt = time.addingTimeInterval(60)
            case "expired": snapshot.rules[0].expiresAt = time.addingTimeInterval(-1)
            default: snapshot.rules[0].expiresAt = nil
            }
            let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: snapshot, now: { time })
            let coordinator = AutomationCoordinator(executor: executor, now: { time })
            let preview = try coordinator.preview(rule: executor.state.rules[0])
            XCTAssertThrowsError(try coordinator.authorizeDelegation(preview: preview, expiresAt: time.addingTimeInterval(30), confirmed: true), condition)
            XCTAssertTrue(executor.state.automationGrants.isEmpty)
        }
        let f = try fixture(level: .delegated, now: { time })
        let preview = try f.coordinator.preview(rule: f.rule)
        XCTAssertThrowsError(try f.coordinator.authorizeDelegation(preview: preview, expiresAt: time.addingTimeInterval(60))) { XCTAssertEqual($0 as? MailActionError, .confirmationRequired) }
        XCTAssertThrowsError(try f.coordinator.authorizeDelegation(preview: preview, expiresAt: time.addingTimeInterval(3_601), confirmed: true))
        var shorter = f.rule; shorter.expiresAt = time.addingTimeInterval(30)
        shorter = try f.executor.saveAutomationRule(shorter, confirmed: true)
        XCTAssertThrowsError(try f.coordinator.authorizeDelegation(preview: f.coordinator.preview(rule: shorter), expiresAt: time.addingTimeInterval(31), confirmed: true))
        let valid = try f.coordinator.authorizeDelegation(preview: f.coordinator.preview(rule: shorter), expiresAt: time.addingTimeInterval(30), confirmed: true)
        XCTAssertFalse(valid.isConsumed)
    }

    func testDelegationCannotExceedTenOrRegainReusableAuthorityByLoweringLevel() async throws {
        let f = try fixture(level: .delegated, count: 11)
        var rule = f.rule; rule.maxMessages = 11
        rule = try f.executor.saveAutomationRule(rule, confirmed: true)
        XCTAssertTrue(rule.delegationOnly)
        XCTAssertThrowsError(try f.coordinator.authorizeDelegation(preview: f.coordinator.preview(rule: rule), expiresAt: Date().addingTimeInterval(60), confirmed: true))
        try f.executor.updatePreferences(UserPreferences(automationLevel: .rules))
        await expectFailure(.ruleUnavailable) {
            try await f.coordinator.run(preview: f.coordinator.preview(rule: rule)) { _ in XCTFail("Delegated rule became reusable"); throw AutomationError.invalidScope }
        }
    }

    func testOneRunGrantIsDurableBeforeDispatchAndNeverRefundedAfterFailureOrRestart() async throws {
        let f = try fixture(level: .delegated)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        await expectFailure(.invalidScope) {
            try await f.coordinator.run(preview: preview, grantID: grant.id) { cap in
                XCTAssertTrue(f.repository.snapshot?.automationGrants.first?.isConsumed == true)
                XCTAssertEqual(f.repository.snapshot?.automationGrants.first?.consumedByRunID, cap.runID)
                XCTAssertEqual(f.repository.snapshot?.automationRuns.last?.activeDispatchID, cap.id)
                throw AutomationError.invalidScope
            }
        }
        XCTAssertEqual(f.executor.state.automationRuns.last?.status, .failed)
        let stored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(XCTUnwrap(f.repository.snapshot)))
        let restarted = ActionExecutor(repository: f.repository, initialState: stored)
        let coordinator = AutomationCoordinator(executor: restarted)
        await expectFailure(.delegationConsumed) {
            try await coordinator.run(preview: preview, grantID: grant.id) { _ in XCTFail("Consumed grant replayed"); throw AutomationError.invalidScope }
        }
        XCTAssertTrue(restarted.state.messages.allSatisfy { !$0.isRead })
    }

    func testGrantCannotBeCreatedAfterRevocationOrUsedWithAChangedReviewedMessage() async throws {
        let f = try fixture(level: .delegated)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        var changed = f.executor.state; changed.messages[0].body = "Different content under the same source ID"
        let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: changed)
        let coordinator = AutomationCoordinator(executor: executor)
        await expectFailure(.stalePreview) {
            try await coordinator.run(preview: coordinator.preview(rule: f.rule), grantID: grant.id) { _ in XCTFail("Old grant adopted new content"); throw AutomationError.invalidScope }
        }
        try f.executor.revokeAutomationRule(id: f.rule.id)
        XCTAssertTrue(f.executor.state.automationGrants[0].isRevoked)
        let revoked = try f.coordinator.preview(rule: f.executor.state.rules[0])
        XCTAssertThrowsError(try f.coordinator.authorizeDelegation(preview: revoked, expiresAt: Date().addingTimeInterval(60), confirmed: true))
        await expectFailure(.ruleUnavailable) {
            try await f.coordinator.run(preview: revoked, grantID: grant.id) { _ in XCTFail("Revoked scope ran"); throw AutomationError.invalidScope }
        }
    }

    func testExpiryAndFutureAuthorizationCannotBeBypassedByExistingGrant() async throws {
        var current = Date()
        let f = try fixture(level: .delegated, now: { current })
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: current.addingTimeInterval(10), confirmed: true)
        current = current.addingTimeInterval(11)
        await expectFailure(.expired) {
            try await f.coordinator.run(preview: preview, grantID: grant.id) { _ in XCTFail("Expired grant ran"); throw AutomationError.invalidScope }
        }
        XCTAssertFalse(f.executor.state.automationGrants[0].isConsumed)
    }

    func testChangedSourceOrCandidateSetInvalidatesPreviewBeforeDispatch() async throws {
        let f = try fixture()
        let preview = try f.coordinator.preview(rule: f.rule)
        for kind in ["body", "subject", "provider-label", "new-match"] {
            var changed = f.executor.state
            switch kind {
            case "body": changed.messages[0].body += " New content"
            case "subject": changed.messages[0].subject = "Changed subject"
            case "provider-label": changed.messages[0].providerFolderIDs = ["different-label"]
            default: var extra = changed.messages[0]; extra.id = UUID(); extra.providerID = "new-message"; changed.messages.append(extra)
            }
            let executor = ActionExecutor(repository: MemoryMailRepository(), initialState: changed)
            let coordinator = AutomationCoordinator(executor: executor)
            await expectFailure(.stalePreview) {
                try await coordinator.run(preview: preview) { _ in XCTFail("Stale \(kind) preview dispatched"); throw AutomationError.invalidScope }
            }
            XCTAssertTrue(executor.state.automationRuns.isEmpty)
        }
    }

    func testRuleRevocationLevelChangeAndSourceChangeStopNextDispatchAfterAcknowledgement() async throws {
        for change in ["revoke", "level", "source"] {
            let f = try fixture()
            let preview = try f.coordinator.preview(rule: f.rule)
            var calls = 0
            do {
                try await f.coordinator.run(preview: preview) { cap in
                    calls += 1
                    let receipt = try self.demoReceipt(cap, executor: f.executor)
                    if change == "revoke" { try f.executor.revokeAutomationRule(id: f.rule.id) }
                    else if change == "level" { try f.executor.updatePreferences(UserPreferences(automationLevel: .manual)) }
                    else { try f.executor.execute(ProposedAction(type: .flag(messageIDs: [preview.messageIDs[1]], isFlagged: true), explanation: "Changed second message after preview")) }
                    return receipt
                }
                XCTFail("Changed scope should stop before second message")
            } catch { XCTAssertTrue(error is AutomationError) }
            XCTAssertEqual(calls, 1, change)
            XCTAssertEqual(f.executor.state.automationRuns.last?.completedMessageIDs, [preview.messageIDs[0]])
            XCTAssertEqual(f.executor.state.automationRuns.last?.status, .failed)
            XCTAssertFalse(try XCTUnwrap(f.executor.state.messages.first { $0.id == preview.messageIDs[1] }).isRead)
        }
    }

    func testCapabilityCannotBeReplayedOrSubstitutedForAnotherMessageOrAction() async throws {
        let f = try fixture()
        try await f.coordinator.run(preview: f.coordinator.preview(rule: f.rule)) { cap in
            let forged = AuthorizedAutomationDispatch(id: cap.id, runID: cap.runID, ruleID: cap.ruleID, grantID: cap.grantID, accountID: cap.accountID,
                                                       messageID: cap.messageID, action: .archive, explanation: "Forged action")
            XCTAssertThrowsError(try f.executor.executeAutomation(forged))
            let other = AuthorizedAutomationDispatch(id: cap.id, runID: cap.runID, ruleID: cap.ruleID, grantID: cap.grantID, accountID: cap.accountID,
                                                      messageID: UUID(), action: cap.action, explanation: "Forged target")
            XCTAssertThrowsError(try f.executor.executeAutomation(other))
            let receipt = try self.demoReceipt(cap, executor: f.executor)
            XCTAssertThrowsError(try f.executor.executeAutomation(cap))
            return receipt
        }
        XCTAssertEqual(f.executor.state.history.count, 2)
    }

    func testFabricatedReceiptCannotClaimCompletionAndIsRecordedAsUncertain() async throws {
        let f = try fixture()
        await expectFailure(.invalidReceipt) {
            try await f.coordinator.run(preview: f.coordinator.preview(rule: f.rule)) { _ in AutomationDispatchReceipt(actionID: UUID(), isRemote: false) }
        }
        XCTAssertEqual(f.executor.state.automationRuns.last?.status, .outcomeUnknown)
        XCTAssertTrue(f.executor.state.messages.allSatisfy { !$0.isRead })
        XCTAssertTrue(f.executor.state.history.isEmpty)
    }

    func testPersistenceFailureCannotDispatchOrConsumeGrantInMemory() async throws {
        let f = try fixture(level: .delegated)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        f.repository.failWrites = true
        await expectFailure(.persistenceFailed) {
            try await f.coordinator.run(preview: preview, grantID: grant.id) { _ in XCTFail("Dispatched without durable grant consumption"); throw AutomationError.invalidScope }
        }
        XCTAssertFalse(f.executor.state.automationGrants[0].isConsumed)
        XCTAssertTrue(f.executor.state.automationRuns.isEmpty)
    }

    func testInterruptedRunDoesNotResumeOrRefundConsumedGrant() throws {
        let f = try fixture(level: .delegated)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        let run = try f.executor.beginAutomationRun(preview: preview, grantID: grant.id)
        _ = try f.executor.prepareAutomationDispatch(runID: run.id, messageID: preview.messageIDs[0])
        let persisted = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(XCTUnwrap(f.repository.snapshot)))
        let restarted = ActionExecutor(repository: f.repository, initialState: persisted)
        XCTAssertEqual(restarted.state.automationRuns[0].status, .outcomeUnknown)
        XCTAssertTrue(restarted.state.automationGrants[0].isConsumed)
        XCTAssertTrue(restarted.state.history.isEmpty)
        XCTAssertTrue(restarted.state.messages.allSatisfy { !$0.isRead })
    }

    func testRemoteAutomationUsesDurableWriterGatewayAndNeverFakeCacheUndo() async throws {
        let f = try fixture(remote: true)
        let remote = RemoteActionCoordinator(executor: f.executor)
        let writer = AutomationSafetyWriter(accountID: f.executor.state.accounts[0].id) { request in
            XCTAssertEqual(f.repository.snapshot?.remoteActionHistory.last?.status, .prepared)
            XCTAssertNotNil(f.repository.snapshot?.automationRuns.last?.activeDispatchID)
            XCTAssertEqual(request.messages.count, 1)
            var message = request.messages[0]; message.isRead = true
            return RemoteActionReceipt(messages: [message])
        }
        try await f.coordinator.run(preview: f.coordinator.preview(rule: f.rule)) { cap in
            XCTAssertThrowsError(try f.executor.executeAutomation(cap)) { XCTAssertEqual($0 as? MailActionError, .readOnlyAccount) }
            let record = try await remote.executeAutomation(cap, writer: writer)
            return AutomationDispatchReceipt(actionID: record.id, isRemote: true)
        }
        XCTAssertEqual(writer.calls, 2)
        XCTAssertTrue(f.executor.state.remoteActionHistory.allSatisfy { $0.status == .completed && $0.proposal.origin == .automation })
        XCTAssertTrue(f.executor.state.history.isEmpty)
        XCTAssertFalse(f.executor.canUndo)
        let undo = try remote.proposeUndo(recordID: XCTUnwrap(f.executor.state.remoteActionHistory.first?.id))
        do { _ = try await remote.execute(undo, writer: writer); XCTFail("Remote inverse skipped review") }
        catch { XCTAssertEqual(error as? RemoteActionError, .confirmationRequired) }
    }

    func testRemoteUnknownOutcomeStopsBatchAndGrantRemainsConsumed() async throws {
        let f = try fixture(level: .delegated, remote: true)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        let remote = RemoteActionCoordinator(executor: f.executor)
        let writer = AutomationSafetyWriter(accountID: preview.accountID) { _ in throw RemoteActionError.outcomeUnknown }
        do {
            try await f.coordinator.run(preview: preview, grantID: grant.id) { cap in
                let result = try await remote.executeAutomation(cap, writer: writer)
                return AutomationDispatchReceipt(actionID: result.id, isRemote: true)
            }
            XCTFail("Unknown remote result reported success")
        } catch { XCTAssertEqual(error as? RemoteActionError, .outcomeUnknown) }
        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(f.executor.state.automationRuns.last?.status, .outcomeUnknown)
        XCTAssertEqual(f.executor.state.remoteActionHistory.last?.status, .outcomeUnknown)
        XCTAssertTrue(f.executor.state.automationGrants[0].isConsumed)
        XCTAssertTrue(f.executor.state.messages.allSatisfy { !$0.isRead })
    }

    func testSchemaOneMigrationIsDurableAndLegacyRulesNeverGainAccountScope() throws {
        let f = try fixture(level: .delegated)
        let preview = try f.coordinator.preview(rule: f.rule)
        let grant = try f.coordinator.authorizeDelegation(preview: preview, expiresAt: Date().addingTimeInterval(600), confirmed: true)
        _ = try f.executor.beginAutomationRun(preview: preview, grantID: grant.id)
        var old = try XCTUnwrap(f.repository.snapshot); old.schemaVersion = 1
        old.rules.append(AutomationRule(name: "Legacy unscoped rule", senderEmail: "news@example.test", olderThanDays: 30, enabled: true, authorizedAt: .distantPast))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraSchemaSafety-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mail.json")
        try JSONEncoder().encode(old).write(to: url)
        let repository = JSONMailRepository(url: url), loaded = try XCTUnwrap(repository.load())
        XCTAssertEqual(loaded.schemaVersion, 2)
        XCTAssertTrue(loaded.automationGrants[0].isConsumed)
        XCTAssertEqual(loaded.automationRuns, old.automationRuns)
        XCTAssertFalse(try XCTUnwrap(loaded.rules.last).enabled)
        XCTAssertNil(loaded.rules.last?.authorizedAt)
        let encoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(encoded.schemaVersion, 2, "Old binaries must reject the upgraded journal on disk")
        XCTAssertThrowsError(try repository.save(old)) { XCTAssertEqual($0 as? RepositoryError, .unsupportedSchema(1)) }
        var future = loaded; future.schemaVersion = 999
        let untouched = try JSONEncoder().encode(future); try untouched.write(to: url)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual($0 as? RepositoryError, .unsupportedSchema(999)) }
        XCTAssertEqual(try Data(contentsOf: url), untouched)
    }
}
