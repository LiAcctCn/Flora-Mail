import Foundation

/// Runs only when the user chooses Run Now. There is deliberately no scheduler,
/// model-driven rule creation, or send/delete action in this coordinator.
@MainActor
public final class AutomationCoordinator {
    private let executor: ActionExecutor
    private let now: () -> Date
    public init(executor: ActionExecutor, now: @escaping () -> Date = Date.init) { self.executor = executor; self.now = now }

    public func preview(rule: AutomationRule) throws -> AutomationPreview {
        try AutomationPolicy.validateScope(rule, state: executor.state)
        guard let accountID = rule.accountID else { throw AutomationError.invalidScope }
        let matches = AutomationPolicy.matchingMessages(rule, state: executor.state, now: now())
        return AutomationPreview(id: UUID(), rule: rule, accountID: accountID, messageIDs: Array(matches.prefix(rule.maxMessages)).map(\.id), totalMatchingCount: matches.count,
                                 explanation: "\(rule.action.title) up to \(rule.maxMessages) cached Inbox messages from \(rule.senderEmail) older than \(rule.olderThanDays) days in this account.",
                                 sourceFingerprint: try AutomationPolicy.previewFingerprint(rule, messages: matches))
    }
    @discardableResult
    public func authorizeDelegation(preview: AutomationPreview, expiresAt: Date, confirmed: Bool = false) throws -> AutomationGrant {
        guard confirmed else { throw MailActionError.confirmationRequired }
        return try executor.createAutomationDelegation(preview: preview, expiresAt: expiresAt)
    }
    public func revokeDelegation(id: UUID) throws { try executor.revokeAutomationDelegation(id: id) }

    @discardableResult
    public func run(preview: AutomationPreview, grantID: UUID? = nil, dispatch: @MainActor (AuthorizedAutomationDispatch) async throws -> AutomationDispatchReceipt) async throws -> AutomationRunRecord {
        try Task.checkCancellation()
        let run = try executor.beginAutomationRun(preview: preview, grantID: grantID)
        do {
            for messageID in run.messageIDs {
                try Task.checkCancellation()
                // Revalidate saved rule, grant, level and current message before
                // every dispatch. Newly arrived matching mail is never substituted.
                let capability = try executor.prepareAutomationDispatch(runID: run.id, messageID: messageID)
                let receipt = try await dispatch(capability)
                try executor.completeAutomationDispatch(capability, receipt: receipt)
            }
            return try executor.finishAutomationRun(run.id)
        } catch {
            // Keep partial completion and any remote unknown outcome visible.
            // A one-run grant remains consumed even when cancelled or interrupted.
            do { try executor.failAutomationRun(run.id, error: error) }
            catch { throw AutomationError.persistenceFailed }
            throw error
        }
    }
}
