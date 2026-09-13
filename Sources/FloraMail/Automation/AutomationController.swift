import Foundation
import Observation
import FloraCore

/// Explicit GUI entry points only. Construction, opening Settings, and receiving
/// mail never start a run. Core owns scope, grants, durable journals and dispatch
/// capabilities; this layer owns previews, cancellation and presentation state.
@MainActor @Observable
final class AutomationController {
    private let executor: ActionExecutor
    private let accounts: AccountController
    private let coordinator: AutomationCoordinator
    private let storageAvailable: Bool
    private var task: Task<AutomationRunRecord, any Error>?
    private var activeRunID: UUID?
    private var stateRevision: UInt = 0

    private(set) var preview: AutomationPreview?
    private(set) var matches: [MailMessage] = []
    private(set) var activeGrant: AutomationGrant?
    private(set) var lastRun: AutomationRunRecord?
    private(set) var isRunning = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    var onChange: (@MainActor () -> Void)?

    init(executor: ActionExecutor, accountController: AccountController, storageAvailable: Bool = true) {
        self.executor = executor; accounts = accountController
        coordinator = AutomationCoordinator(executor: executor)
        self.storageAvailable = storageAvailable
    }

    var rules: [AutomationRule] { _ = stateRevision; return executor.state.rules }
    var grants: [AutomationGrant] { _ = stateRevision; return executor.state.automationGrants }
    var history: [AutomationRunRecord] { _ = stateRevision; return executor.state.automationRuns.reversed() }

    /// The displayed messages are captured with the preview, never silently
    /// replaced by newer matches. The core revalidates this snapshot at Run Now.
    func preview(rule: AutomationRule) {
        guard !isRunning else { report(AutomationError.alreadyRunning); return }
        clearPreview(); errorMessage = nil; statusMessage = nil
        do {
            let proposal = try coordinator.preview(rule: rule)
            let values = proposal.messageIDs.compactMap { id in
                executor.state.messages.first { $0.id == id && $0.accountID == proposal.accountID }
            }
            guard values.count == proposal.messageIDs.count else { throw AutomationError.stalePreview }
            preview = proposal; matches = values
            statusMessage = "Review \(values.count) matching message\(values.count == 1 ? "" : "s") before running."
        } catch { report(error) }
    }

    func saveRule(_ rule: AutomationRule, confirmed: Bool) {
        guard !isRunning else { report(AutomationError.alreadyRunning); return }
        do {
            try requireStorage()
            try executor.saveAutomationRule(rule, confirmed: confirmed)
            clearPreview(); errorMessage = nil
            statusMessage = rule.enabled ? "Rule saved. Use Preview and Run Now to apply it." : "Disabled rule saved."
            changed()
        } catch { report(error) }
    }

    /// A grant authorizes the exact preview for one run; it does not start it.
    func authorizeDelegation(expiresAt: Date, confirmed: Bool) {
        guard !isRunning else { report(AutomationError.alreadyRunning); return }
        do {
            try requireStorage()
            guard let preview else { throw AutomationError.stalePreview }
            activeGrant = try coordinator.authorizeDelegation(preview: preview, expiresAt: expiresAt, confirmed: confirmed)
            errorMessage = nil; statusMessage = "One run authorized for the reviewed messages. Choose Run Now before it expires."
            changed()
        } catch { report(error) }
    }

    /// Awaitable by the GUI, with a separately cancellable child task. The busy
    /// state lasts until any in-flight provider acknowledgement is resolved.
    func runPreview() async {
        guard !isRunning else { report(AutomationError.alreadyRunning); return }
        do { try requireStorage(); try Task.checkCancellation() }
        catch { report(error); return }
        guard let preview else { report(AutomationError.stalePreview); return }
        let grantID = activeGrant?.id
        isRunning = true; errorMessage = nil; lastRun = nil; activeRunID = nil
        statusMessage = "Running the reviewed rule…"
        let operation = Task { @MainActor [self, coordinator, accounts, executor] in
            try Task.checkCancellation()
            return try await coordinator.run(preview: preview, grantID: grantID) { dispatch in
                self.activeRunID = dispatch.runID
                try Task.checkCancellation()
                guard let account = executor.state.accounts.first(where: { $0.id == dispatch.accountID }) else { throw AutomationError.invalidScope }
                if account.isRemote { return try await accounts.executeAutomation(dispatch) }
                let record = try executor.executeAutomation(dispatch)
                return AutomationDispatchReceipt(actionID: record.id, isRemote: false)
            }
        }
        task = operation
        defer {
            task = nil; isRunning = false; activeRunID = nil
            clearPreview(); changed()
        }
        do {
            let record = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            lastRun = record
            statusMessage = Self.description(for: record)
            errorMessage = record.errorMessage
        } catch {
            report(error)
            if let id = activeRunID, let record = executor.state.automationRuns.first(where: { $0.id == id }) {
                lastRun = record
                if record.status != .running { statusMessage = Self.description(for: record) }
                if let guidance = record.errorMessage { errorMessage = guidance }
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        statusMessage = "Stopping before the next message. Waiting for any current action to finish."
    }

    /// Switching Demo / real mail must never leave the previous mode's batch
    /// looking runnable. The task keeps its captured scope and durable history,
    /// while cancellation prevents subsequent dispatches after any current ack.
    func invalidateScope() {
        cancel()
        clearPreview()
        errorMessage = nil
        if !isRunning { statusMessage = nil }
    }

    /// Revocation remains available during a run. Core checks it again before
    /// dispatching another message; it cannot undo an already submitted action.
    func revokeRule(id: UUID) {
        do {
            try requireStorage(); try executor.revokeAutomationRule(id: id)
            if preview?.rule.id == id, !isRunning { clearPreview() }
            errorMessage = nil
            statusMessage = "Rule revoked. An action already submitted may still finish; review its history."
            changed()
        } catch { report(error) }
    }

    func revokeDelegation(id: UUID) {
        do {
            try requireStorage(); try coordinator.revokeDelegation(id: id)
            if activeGrant?.id == id { activeGrant = nil }
            errorMessage = nil
            statusMessage = "Delegation revoked. No further messages are authorized by this grant."
            changed()
        } catch { report(error) }
    }

    func deleteRule(id: UUID) {
        do {
            try requireStorage(); try executor.deleteAutomationRule(id: id)
            if preview?.rule.id == id, !isRunning { clearPreview() }
            errorMessage = nil; statusMessage = "Rule removed. Its activity history is retained."
            changed()
        } catch { report(error) }
    }

    func dismissPreview() {
        guard !isRunning else { return }
        clearPreview(); statusMessage = nil; errorMessage = nil
    }

    /// Called by AppModel when permission, account or local state changes. This
    /// refreshes observable lists without regenerating or running the preview.
    func refresh() {
        stateRevision &+= 1
        if let id = activeGrant?.id { activeGrant = executor.state.automationGrants.first { $0.id == id } }
    }

    static func description(for record: AutomationRunRecord) -> String {
        let progress = "\(record.completedMessageIDs.count) of \(record.messageIDs.count) messages completed"
        switch record.status {
        case .running: return "Running “\(record.ruleName)”: \(progress)."
        case .completed: return "“\(record.ruleName)” finished: \(progress)."
        case .failed: return "“\(record.ruleName)” stopped: \(progress). Review the error before trying again."
        case .cancelled: return "“\(record.ruleName)” cancelled: \(progress). Completed changes remain in history."
        case .outcomeUnknown: return "“\(record.ruleName)” needs review: \(progress). Check the account before retrying any uncertain action."
        }
    }

    private func clearPreview() { preview = nil; matches = []; activeGrant = nil }
    private func changed() { refresh(); onChange?() }
    private func requireStorage() throws { guard storageAvailable else { throw AutomationError.persistenceFailed } }
    private func report(_ error: any Error) {
        statusMessage = nil
        if error is CancellationError { errorMessage = nil; statusMessage = "Run cancelled. Review activity for any completed changes." }
        else if error is AutomationError || error is MailActionError || error is RemoteActionError || error is AccountActionError || error is AccountConnectionError { errorMessage = error.localizedDescription }
        else { errorMessage = "Automation could not be saved or completed. Review activity and restore local storage access before trying again." }
    }
}
