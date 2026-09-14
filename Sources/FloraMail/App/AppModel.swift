import SwiftUI
import Observation
import FloraCore

enum MailDestination: Hashable {
    case today, important, localDrafts, folder(MailFolder), category(UUID), account(UUID)
    case providerFolder(accountID: UUID, folderID: String)
}

/// Closing the editor is distinct from merely losing its view during Quit.
enum EditorCloseDecision: Sendable { case save, discard, sent }

@MainActor @Observable
final class AppModel {
    private(set) var state: AppSnapshot
    var destination: MailDestination = .today
    var selectedMessageID: UUID? {
        didSet { if selectedMessageID != nil && selectedMessageID != oldValue { research.record(.messageOpened) } }
    }
    var searchText = ""
    var semanticResults: [UUID]?
    private(set) var searchResultLabel = "Text matches"
    var searchNotice: String?
    var searching = false
    var composingDraft: Draft?
    private(set) var editorDraft: Draft?
    private(set) var editorIsDirty = false
    private(set) var editorRecoveryError: String?
    private(set) var recoverableDraft: Draft?
    private let recoveryStore: DraftRecoveryStore
    private let persistentStorageAvailable: Bool
    private var recoveryTask: Task<Void, Never>?
    private var editorIsPresented = false
    private var pendingEditorRestoration: Draft?
    private var editorRestorationID = UUID()
    private var committedEditorCloseID: UUID?
    var errorMessage: String?
    var storageWarning: String?
    var statusMessage: String? {
        didSet { statusOffersUndo = false }
    }
    private(set) var statusOffersUndo = false
    var pendingRemoteAction: RemoteMailProposal?
    var showingAccountConnection = false
    var showingHistory = false
    var showingCategories = false
    var showingAssistant = false
    var showingAutomation = false
    var attentionItems: [ActionItem] = []
    private(set) var briefingProviderLabel: String?
    var briefingError: String?
    var briefingProgress: String?
    var checkingLocalConnection = false
    var localConnectionState = "Not tested"
    var localConnectionMessage: String?
    var localModelIdentity: LocalModelIdentity?
    private var aiRevision = UUID()
    private var connectionTask: Task<Void, Never>?
    private var connectionRevision = UUID()
    private var briefingTask: Task<Void, Never>?
    private var briefingRevision = UUID()
    private let executor: ActionExecutor
    let accountController: AccountController
    let personalContext = PersonalContextController()
    let research: ResearchController
    let automationController: AutomationController
    private var recoveringFromError: UUID?
    private(set) var researchOptOutSavePending = false
    private var mockAI: any AIProvider = MockAIProvider()
    private var localAI: any AIProvider = LocalAIProvider()
    private var cacheStore: any AICacheStore = MemoryAICacheStore()
    private let localClient: any LocalModelClient
    private var searchTask: Task<Void, Never>?
    private(set) var storageURL: URL

    init(storageURL: URL? = nil, localClient: any LocalModelClient = OllamaLocalModelClient(), credentials: any CredentialStore = KeychainCredentialStore(), remoteProviderFactory: (@MainActor (MailAccount) throws -> any ReadOnlyMailProvider)? = nil) {
        self.localClient = localClient
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let resolvedURL = storageURL ?? support.appendingPathComponent("FloraMail/demo-store.json")
        self.storageURL = resolvedURL
        recoveryStore = DraftRecoveryStore(url: resolvedURL.deletingLastPathComponent().appendingPathComponent("composer-recovery.json"))
        let repository = JSONMailRepository(url: resolvedURL)
        var storageFailed = false
        do {
            let existing = try repository.load()
            let initial = existing ?? DemoFixtures.makeSnapshot()
            if existing == nil { try repository.save(initial) }
            state = initial
            executor = ActionExecutor(repository: repository, initialState: initial)
        } catch {
            storageFailed = true
            let initial = DemoFixtures.makeSnapshot()
            state = initial
            executor = ActionExecutor(repository: MemoryMailRepository(), initialState: initial)
            storageWarning = "Local storage could not be opened. This session uses temporary demo data; the original file is preserved. \(error.localizedDescription)"
        }
        persistentStorageAvailable = !storageFailed
        accountController = AccountController(executor: executor, storageURL: resolvedURL, storageAvailable: !storageFailed,
                                              credentials: credentials, providerOverride: remoteProviderFactory)
        automationController = AutomationController(executor: executor, accountController: accountController, storageAvailable: !storageFailed)
        research = ResearchController(repository: storageFailed ? MemoryResearchMetricsRepository() : JSONResearchMetricsRepository(url: resolvedURL.deletingLastPathComponent().appendingPathComponent("research-metrics.json")))
        research.configure(mode: state.preferences.researchMode, enabled: !storageFailed && state.preferences.researchMetricsEnabled)
        state = executor.state
        if !storageFailed {
            cacheStore = JSONAICacheStore(url: resolvedURL.deletingLastPathComponent().appendingPathComponent("ai-cache.json"))
        }
        configureProviders()
        if !storageFailed {
            do {
                // Keep even legacy/unavailable-account recovery visible. Ignoring
                // it here would let a new editor hide an existing unsaved draft.
                recoverableDraft = try recoveryStore.load()
            } catch { editorRecoveryError = "The unsaved-draft recovery file could not be read. Existing saved drafts are preserved." }
        }
        accountController.onChange = { [weak self] in self?.refresh() }
        automationController.onChange = { [weak self] in self?.refresh() }
        accountController.onConnected = { [weak self] id in
            self?.setDemoMode(false)
            self?.navigate(.account(id))
        }
    }

    var aiRequestIdentity: String { "\(state.preferences.aiMode.rawValue)-\(state.preferences.automationLevel)-\(state.preferences.researchMode)-\(aiRevision)-\(state.preferences.showDemoAccounts)-\(accountScopeID?.uuidString ?? "all")" }
    var aiEnabled: Bool { state.preferences.aiMode != .off && state.preferences.automationLevel != .manual && state.preferences.researchMode != .traditional }
    var embeddedAIEnabled: Bool { aiEnabled && state.preferences.researchMode == .hybrid }
    var canAcceptAISuggestions: Bool { aiEnabled && state.preferences.automationLevel != .information }
    var aiDisabledExplanation: String {
        if state.preferences.researchMode == .traditional { return "Traditional GUI mode keeps AI assistance hidden. Change the interaction mode in Settings to use AI." }
        if state.preferences.automationLevel == .manual { return "Level 0 keeps assistance off. Normal mail controls remain available." }
        return "AI is off. Choose Demo AI or Local AI in Settings to enable assistance."
    }
    var canUndo: Bool { executor.canUndo }
    var canCompose: Bool { !displayedAccounts.isEmpty && recoverableDraft == nil }
    var canMutateSelection: Bool { selectedMessage.map { !isReadOnly($0) } ?? false }
    var selectedMessage: MailMessage? { state.messages.first { $0.id == selectedMessageID } }
    var aiLabel: String { state.preferences.aiMode.rawValue }
    var accountScopeID: UUID? {
        switch destination { case .account(let id), .providerFolder(let id, _): id; default: nil }
    }
    var displayedAccounts: [MailAccount] { state.accounts.filter { ($0.providerType == .demo) == state.preferences.showDemoAccounts } }
    var scopedMessages: [MailMessage] {
        let accounts = Set(displayedAccounts.map(\.id))
        return state.messages.filter { accounts.contains($0.accountID) && (accountScopeID == nil || $0.accountID == accountScopeID) }
    }
    var visibleDrafts: [Draft] {
        state.drafts.filter { draft in
            let id = draft.accountID ?? draft.replyToMessageID.flatMap { sourceID in state.messages.first { $0.id == sourceID }?.accountID }
            let isDemo = id.flatMap { accountID in state.accounts.first { $0.id == accountID } }?.providerType == .demo || id == nil
            return isDemo == state.preferences.showDemoAccounts
        }
    }
    func isReadOnly(_ message: MailMessage) -> Bool {
        guard let account = state.accounts.first(where: { $0.id == message.accountID }) else { return true }
        return account.isReadOnly || (account.isRemote && (account.credentialReference == nil || account.status == .disconnected || account.status == .reauthenticationRequired || accountController.writingAccounts.contains(account.id) || accountController.isSyncing(account.id) || accountController.connecting))
    }
    func canSendDemo(_ draft: Draft) -> Bool {
        if let accountID = draft.accountID, state.accounts.first(where: { $0.id == accountID })?.providerType != .demo { return false }
        if let id = draft.replyToMessageID {
            guard let source = state.messages.first(where: { $0.id == id }), state.accounts.first(where: { $0.id == source.accountID })?.providerType == .demo else { return false }
        }
        return draft.accountID != nil || state.preferences.showDemoAccounts
    }
    func setDemoMode(_ enabled: Bool) {
        do {
            let changedScope = state.preferences.showDemoAccounts != enabled
            var preferences = state.preferences; preferences.showDemoAccounts = enabled
            try executor.updatePreferences(preferences)
            if changedScope { automationController.invalidateScope() }
            refresh(); resetAIRequests(); navigate(.today)
        } catch { report(error) }
    }
    func saveSyncSettings(_ settings: MailSyncSettings) {
        do {
            var preferences = state.preferences; preferences.mailSyncSettings = settings
            try executor.updatePreferences(preferences); refresh(); statusMessage = "Sync limits saved. They apply to future sync requests."
        } catch { report(error) }
    }
    var title: String {
        switch destination {
        case .today: "Today"
        case .localDrafts: "Local Drafts"
        case .important: "Important"
        case .folder(let folder): folder.title
        case .category(let id): state.categories.first { $0.id == id }?.name ?? "Category"
        case .account(let id): state.accounts.first { $0.id == id }?.address.email ?? "Account"
        case .providerFolder(let accountID, let folderID): state.remoteFolders.first { $0.accountID == accountID && $0.id == folderID }?.name ?? "Folder"
        }
    }
    var visibleMessages: [MailMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopedMessages.filter { message in
            let inScope: Bool
            switch destination {
            case .today: inScope = message.folder == .inbox
            case .localDrafts: inScope = false
            case .important: inScope = (message.isFlagged || message.isImportant) && message.folder != .trash
            case .folder(let folder): inScope = message.folder == folder
            case .category(let id): inScope = message.categoryID == id && message.folder != .trash
            case .account(let id): inScope = message.accountID == id
            case .providerFolder(let id, let folderID): inScope = message.accountID == id && message.providerFolderIDs.contains(folderID)
            }
            guard inScope else { return false }
            if let semanticResults { return semanticResults.contains(message.id) }
            return query.isEmpty || [message.subject, message.body, message.from.name, message.from.email].contains { $0.localizedStandardContains(query) }
        }.sorted { $0.date > $1.date }
    }

    private var ai: any AIProvider { state.preferences.aiMode == .local ? localAI : mockAI }
    private func requireAI() throws {
        if !aiEnabled { throw AppError.aiDisabled }
    }
    private func refresh() {
        state = executor.state
        automationController.refresh()
        if case .category(let id) = destination, !state.categories.contains(where: { $0.id == id }) {
            navigate(.folder(.inbox))
        }
        reconcileSelection()
    }
    func reconcileSelection() {
        if let selectedMessageID, !visibleMessages.contains(where: { $0.id == selectedMessageID }) { self.selectedMessageID = nil }
    }
    func draftHasUnsavedChanges(_ draft: Draft) -> Bool {
        guard let saved = state.drafts.first(where: { $0.id == draft.id }) else {
            return !draft.to.isEmpty || !draft.cc.isEmpty || !draft.bcc.isEmpty || !draft.attachments.isEmpty || !draft.subject.isEmpty || !draft.body.isEmpty || draft.replyToMessageID != nil
        }
        return draft.to != saved.to || draft.cc != saved.cc || draft.bcc != saved.bcc || draft.attachments != saved.attachments || draft.accountID != saved.accountID || draft.subject != saved.subject || draft.body != saved.body
            || draft.replyToMessageID != saved.replyToMessageID
    }
    func updateEditorDraft(_ draft: Draft, isDirty: Bool) {
        // Late onChange/import callbacks from a dismissed composer must not
        // recreate recovery after an explicit Save, Discard or acknowledged Send.
        guard committedEditorCloseID != draft.id,
              recoverableDraft == nil,
              composingDraft == nil || composingDraft?.id == draft.id,
              editorDraft == nil || editorDraft?.id == draft.id else { return }
        editorDraft = draft; editorIsDirty = isDirty; editorIsPresented = true
        if pendingEditorRestoration?.id == draft.id { pendingEditorRestoration = nil }
        recoveryTask?.cancel()
        guard persistentStorageAvailable else {
            editorRecoveryError = "This temporary session cannot save draft recovery. Restore local storage before relying on saved edits."
            return
        }
        guard isDirty else {
            do { try recoveryStore.clear(draftID: draft.id) }
            catch { editorRecoveryError = "The previous recovery copy could not be cleared." }
            return
        }
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                guard let self, self.editorDraft?.id == draft.id, self.committedEditorCloseID != draft.id else { return }
                try self.recoveryStore.save(draft)
                self.editorRecoveryError = nil
            } catch is CancellationError {} catch {
                self?.editorRecoveryError = "Automatic draft recovery could not be saved. Use Save Draft before closing."
            }
        }
    }
    /// A disappeared sheet may be awaiting the delegate's Quit decision. Retain
    /// dirty text and restore it if termination is cancelled; disappearance is
    /// never interpreted as the user's permission to discard their edits.
    func editorDidDisappear(id: UUID) {
        if committedEditorCloseID == id { editorIsPresented = false; return }
        guard let draft = editorDraft, draft.id == id else { return }
        editorIsPresented = false
        if pendingEditorRestoration != nil { scheduleEditorRestoration() }
        else if editorIsDirty {
            pendingEditorRestoration = draft
            composingDraft = nil
            scheduleEditorRestoration()
        } else if !finishEditorClose(draft, decision: .discard) {
            restoreEditorAfterCancelledTermination(draft, recoveryError: editorRecoveryError)
        }
    }

    /// Return true only after the requested close has been committed. Send is
    /// already acknowledged before this method is called; it performs no mail IO.
    @discardableResult
    func finishEditorClose(_ draft: Draft, decision: EditorCloseDecision) -> Bool {
        guard editorDraft?.id == draft.id else {
            errorMessage = "This editor changed. Review the current draft before closing it."
            return false
        }
        recoveryTask?.cancel(); recoveryTask = nil
        editorRestorationID = UUID()
        if case .save = decision {
            guard persistentStorageAvailable else {
                let message = "This temporary session cannot save a draft permanently. Restore local storage or keep a copy before quitting."
                editorRecoveryError = message; errorMessage = message
                return false
            }
            guard saveDraft(draft) else { editorRecoveryError = errorMessage; return false }
        }
        do {
            // An unreadable-store fallback must not modify existing private
            // recovery. Explicit Discard may still close its temporary editor.
            if persistentStorageAvailable { try recoveryStore.clear(draftID: draft.id) }
        } catch {
            let message: String
            switch decision {
            case .save: message = "Your draft was saved, but its recovery copy could not be cleared. Restore storage access and try closing again."
            case .discard: message = "The recovery copy could not be cleared, so these edits have not been discarded. Restore storage access and try again."
            case .sent: message = "The send completed, but its recovery copy could not be cleared. Do not send again. Restore storage access and close the editor."
            }
            editorIsDirty = draftHasUnsavedChanges(draft)
            editorRecoveryError = message; errorMessage = message
            return false
        }
        committedEditorCloseID = draft.id
        pendingEditorRestoration = nil
        if recoverableDraft?.id == draft.id { recoverableDraft = nil }
        editorDraft = nil; editorIsDirty = false; editorRecoveryError = nil
        composingDraft = nil
        return true
    }
    func recoverUnsavedDraft() {
        guard let draft = recoverableDraft, composingDraft == nil, pendingEditorRestoration == nil,
              !editorIsPresented, editorDraft == nil else { return }
        let knownAccountIDs = Set([
            draft.accountID,
            draft.replyToMessageID.flatMap { id in state.messages.first { $0.id == id }?.accountID },
            state.drafts.first(where: { $0.id == draft.id })?.accountID
        ].compactMap { $0 })
        guard knownAccountIDs.count == 1, let accountID = knownAccountIDs.first,
              let account = state.accounts.first(where: { $0.id == accountID }) else {
            errorMessage = "The account for this recovered draft is unavailable or conflicts with its saved message. The recovery copy is preserved. Review the account or discard this recovery before opening another editor."
            return
        }
        setDemoMode(!account.isRemote)
        guard state.preferences.showDemoAccounts == !account.isRemote else { return }
        committedEditorCloseID = nil; composingDraft = draft; recoverableDraft = nil
    }
    func discardRecoveredDraft() {
        guard let draft = recoverableDraft else { return }
        do { try recoveryStore.clear(draftID: draft.id); recoverableDraft = nil }
        catch { report(error) }
    }
    func restoreEditorAfterCancelledTermination(_ draft: Draft, recoveryError: String? = nil) {
        // SwiftUI may dismiss an allowed sheet before the delegate vetoes Quit.
        // Retain the actual edited text until the replacement composer appears.
        guard committedEditorCloseID != draft.id else { return }
        pendingEditorRestoration = draft
        editorDraft = draft; editorIsDirty = draftHasUnsavedChanges(draft)
        editorRecoveryError = recoveryError
        composingDraft = nil
        if !editorIsPresented { scheduleEditorRestoration() }
    }
    private func scheduleEditorRestoration() {
        let revision = UUID(); editorRestorationID = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorRestorationID == revision,
                  !self.editorIsPresented, let draft = self.pendingEditorRestoration else { return }
            self.composingDraft = draft
        }
    }
    func editDraft(_ draft: Draft) {
        guard requirePendingRecoveryDecision() else { return }
        guard composingDraft == nil, pendingEditorRestoration == nil, !editorIsPresented, editorDraft == nil else { return }
        committedEditorCloseID = nil; composingDraft = draft
    }

    private func requirePendingRecoveryDecision() -> Bool {
        guard recoverableDraft == nil else {
            errorMessage = "Review or discard the recovered unsaved draft before opening another editor. Its recovery copy has been preserved."
            return false
        }
        return true
    }

    @discardableResult func perform(_ action: ProposedAction, confirmed: Bool = false) -> Bool {
        do {
            if let remote = try remoteProposal(for: action) {
                pendingRemoteAction = remote
                return false // Execution and selection changes wait for confirmation.
            }
            let executed = try executor.execute(action, confirmed: confirmed)
            refresh()
            statusMessage = action.explanation
            statusOffersUndo = executed.canUndo
            recordSuccessfulAction()
            if case .classify = action.type, action.origin == .user { research.record(.correction) }
            return true
        } catch { report(error); return false }
    }
    func report(_ error: Error) {
        if !(error is CancellationError) { errorMessage = error.localizedDescription; recordResearchError() }
    }
    func recordResearch(_ event: ResearchInteraction) { research.record(event) }
    private func recordResearchError() {
        recoveringFromError = nil
        guard research.isEnabled else { return }
        research.record(.error)
        if research.isEnabled { recoveringFromError = research.recordingEpoch }
    }
    private func recordSuccessfulAction() {
        research.record(.actionExecuted)
        if research.isEnabled, recoveringFromError == research.recordingEpoch { research.record(.errorRecovery) }
        recoveringFromError = nil
    }
    func openMessage(_ id: UUID) {
        guard let message = state.messages.first(where: { $0.id == id }) else { return }
        guard let account = state.accounts.first(where: { $0.id == message.accountID }) else { return }
        if state.preferences.showDemoAccounts != (account.providerType == .demo) {
            setDemoMode(account.providerType == .demo)
            navigate(.account(account.id))
        } else if destination == .today {
            navigate(.folder(message.folder))
        } else if !visibleMessages.contains(where: { $0.id == id }) {
            // Source links outside the current view keep a single account scope.
            navigate(.account(account.id))
        }
        selectedMessageID = id
        // Reading is deliberately explicit: selection alone does not mutate mail.
    }
    func navigate(_ value: MailDestination) {
        destination = value; selectedMessageID = nil; searchText = ""; clearSemanticSearch()
        research.record(.navigation)
    }
    func archive(_ message: MailMessage) {
        if perform(ProposedAction(type: .archive(messageIDs: [message.id]), explanation: "Archived “\(message.subject)”.")) { selectedMessageID = nil }
    }
    func trash(_ message: MailMessage) {
        if perform(ProposedAction(type: .move(messageIDs: [message.id], folder: .trash), explanation: "Moved “\(message.subject)” to Trash.")) { selectedMessageID = nil }
    }
    func toggleFlag(_ message: MailMessage) {
        perform(ProposedAction(type: .flag(messageIDs: [message.id], isFlagged: !message.isFlagged), explanation: message.isFlagged ? "Removed flag." : "Flagged “\(message.subject)”."))
    }
    func toggleRead(_ message: MailMessage) {
        perform(ProposedAction(type: .markRead(messageIDs: [message.id], isRead: !message.isRead), explanation: message.isRead ? "Marked unread." : "Marked read."))
    }
    func undo() {
        do { try executor.undo(); refresh(); statusMessage = "Undid the last change."; research.record(.undo) }
        catch { report(error) }
    }
    @discardableResult func acceptClassification(_ suggestion: ClassificationSuggestion) -> Bool {
        do {
            guard canAcceptAISuggestions else { throw MailActionError.confirmationRequired }
            let executed = try executor.acceptClassification(suggestion)
            refresh(); statusMessage = "Category accepted locally. You can undo this change."
            statusOffersUndo = executed.canUndo
            research.record(.aiAccepted)
            return true
        } catch { report(error); return false }
    }
    func compose(replyTo message: MailMessage? = nil, forward: Bool = false, replyAll: Bool = false, suggestedText: String? = nil) {
        guard suggestedText == nil || canAcceptAISuggestions else { return }
        guard requirePendingRecoveryDecision() else { return }
        guard composingDraft == nil, pendingEditorRestoration == nil, !editorIsPresented, editorDraft == nil else { return }
        committedEditorCloseID = nil
        research.record(.compose)
        if suggestedText != nil { research.record(.aiAccepted) }
        if let message {
            let prefix = forward ? "Fwd: " : "Re: "
            let subject = message.subject.lowercased().hasPrefix(prefix.lowercased()) ? message.subject : prefix + message.subject
            let body = forward ? "\n\n—— Forwarded message ——\nFrom: \(message.from.name) <\(message.from.email)>\nSubject: \(message.subject)\n\n\(message.body)" : suggestedText ?? "Hi \(message.from.name.components(separatedBy: " ").first ?? message.from.name),\n\n"
            guard let account = state.accounts.first(where: { $0.id == message.accountID }) else { return }
            let recipients = DraftComposition.recipients(for: message, account: account, replyAll: replyAll)
            var draft = Draft(to: forward ? "" : recipients.to, subject: subject, body: body, replyToMessageID: forward ? nil : message.id, accountID: message.accountID)
            draft.cc = forward ? "" : recipients.cc
            composingDraft = draft
        } else {
            guard let accountID = accountScopeID ?? displayedAccounts.first?.id else { return }
            composingDraft = Draft(accountID: accountID)
        }
    }
    @discardableResult func saveDraft(_ draft: Draft) -> Bool {
        var saved = draft; saved.updatedAt = Date()
        return perform(ProposedAction(type: .saveDraft(saved), explanation: "Saved draft “\(draft.subject.isEmpty ? "Untitled" : draft.subject)”."))
    }
    @discardableResult func sendDraft(_ draft: Draft) -> Bool {
        guard canSendDemo(draft) else { report(MailActionError.readOnlyAccount); return false }
        guard saveDraft(draft) else { return false }
        return perform(ProposedAction(type: .sendDraft(id: draft.id), explanation: "Sent “\(draft.subject)” in the demo. No email left this Mac."), confirmed: true)
    }

    func canSend(_ draft: Draft) -> Bool {
        if canSendDemo(draft) { return true }
        guard let accountID = draft.accountID,
              let account = state.accounts.first(where: { $0.id == accountID }), !account.isReadOnly,
              account.credentialReference != nil, account.status != .disconnected, account.status != .reauthenticationRequired,
              !accountController.writingAccounts.contains(accountID) else { return false }
        return (state.drafts.first(where: { $0.id == draft.id }) ?? draft).deliveryState == .notSent
    }

    func prepareRemoteDraft(_ draft: Draft, send: Bool) throws -> RemoteMailProposal {
        guard let accountID = draft.accountID else { throw MailActionError.accountNotFound }
        guard saveDraft(draft) else { throw AccountActionError.draftSaveFailed }
        return try accountController.propose(send ? .sendDraft(draftID: draft.id) : .syncDraft(draftID: draft.id), accountID: accountID,
            explanation: send ? "Send “\(draft.subject)” from this account." : "Synchronize draft “\(draft.subject)” to this account.")
    }

    /// Called only by the explicit confirmation surface. Failures remain in the
    /// active sheet and the durable remote action log, never a success toast.
    func executeRemote(_ proposal: RemoteMailProposal) async -> String? {
        do {
            _ = try await accountController.execute(proposal)
            refresh(); statusMessage = "Mail service confirmed the action. View Activity for details."
            recordSuccessfulAction()
            return nil
        } catch {
            refresh()
            recordResearchError()
            return error.localizedDescription
        }
    }

    func previewMove(_ message: MailMessage, to folder: MailFolderDescriptor) {
        do {
            pendingRemoteAction = try accountController.propose(.move(messageIDs: [message.id], destination: folder), accountID: message.accountID,
                explanation: "Move “\(message.subject)” to \(folder.name).")
        } catch { report(error) }
    }

    private func remoteProposal(for proposal: ProposedAction) throws -> RemoteMailProposal? {
        let ids: [UUID]
        switch proposal.type {
        case .archive(let value), .move(let value, _), .markRead(let value, _), .flag(let value, _): ids = value
        default: return nil
        }
        guard let first = ids.first, let source = state.messages.first(where: { $0.id == first }),
              let account = state.accounts.first(where: { $0.id == source.accountID }), account.isRemote else { return nil }
        guard ids.allSatisfy({ id in state.messages.contains(where: { $0.id == id && $0.accountID == account.id }) }) else { throw MailSyncError.accountMismatch }
        let action: RemoteMailAction
        switch proposal.type {
        case .archive: action = .archive(messageIDs: ids)
        case .markRead(_, let value): action = .markRead(messageIDs: ids, isRead: value)
        case .flag(_, let value): action = .flag(messageIDs: ids, isFlagged: value)
        case .move(_, let role):
            guard let folder = state.remoteFolders.first(where: { $0.accountID == account.id && $0.role == role }) else { throw AccountActionError.folderUnavailable }
            action = .move(messageIDs: ids, destination: folder)
        default: return nil
        }
        return try accountController.propose(action, accountID: account.id, explanation: proposal.explanation, origin: proposal.origin)
    }
    private func configureProviders() {
        mockAI = CachedAIProvider(provider: MockAIProvider(), store: cacheStore, promptVersion: "mock-v2", namespace: "demo")
        localAI = CachedAIProvider(provider: LocalAIProvider(configuration: state.preferences.localAI, client: localClient),
                                   store: cacheStore, namespace: state.preferences.localAI.endpoint)
    }
    private func resetAIRequests() {
        aiRevision = UUID()
        connectionTask?.cancel(); connectionRevision = UUID(); checkingLocalConnection = false
        localConnectionState = "Not tested"; localConnectionMessage = nil; localModelIdentity = nil
        cancelBriefing(); attentionItems = []; briefingProviderLabel = nil; briefingError = nil; briefingProgress = nil
        clearSemanticSearch(); configureProviders()
    }
    func setCategoryLearning(_ enabled: Bool) {
        do {
            var preferences = state.preferences; preferences.learnCategoryPreferences = enabled
            try executor.updatePreferences(preferences); refresh(); resetAIRequests()
        } catch { report(error) }
    }
    func setAutomationLevel(_ level: AutomationLevel) {
        do {
            var preferences = state.preferences; preferences.automationLevel = level
            try executor.updatePreferences(preferences); refresh(); resetAIRequests()
            automationController.cancel()
        } catch { report(error) }
    }
    func setResearchMode(_ mode: ResearchMode) {
        do {
            var preferences = state.preferences; preferences.researchMode = mode
            try executor.updatePreferences(preferences); refresh(); resetAIRequests()
            if mode == .traditional { showingAssistant = false }
            personalContext.cancel()
            automationController.cancel()
            recoveringFromError = nil
            research.configure(mode: mode, enabled: persistentStorageAvailable && preferences.researchMetricsEnabled && research.isEnabled)
        } catch { report(error) }
    }
    func setResearchMetricsEnabled(_ enabled: Bool) {
        guard persistentStorageAvailable else { return }
        // Opt-out takes effect even if the main mail store cannot be saved.
        recoveringFromError = nil
        if !enabled { research.configure(mode: state.preferences.researchMode, enabled: false) }
        do {
            var preferences = state.preferences; preferences.researchMetricsEnabled = enabled
            try executor.updatePreferences(preferences); refresh()
            researchOptOutSavePending = false
            if enabled, !research.isEnabled { research.retryRecording(mode: preferences.researchMode) }
            else { research.configure(mode: preferences.researchMode, enabled: enabled) }
        } catch {
            if !enabled {
                researchOptOutSavePending = true
                errorMessage = "Recording has stopped for this session, but the saved preference could not be updated. Use Retry Saving Opt-Out in Research Settings before restarting Flora Mail."
            } else { report(error) }
        }
    }
    func updateAIMode(_ mode: AIMode) {
        do {
            var preferences = state.preferences; preferences.aiMode = mode
            try executor.updatePreferences(preferences); refresh(); resetAIRequests()
        } catch { report(error) }
    }
    @discardableResult func saveLocalConfiguration(_ configuration: AIModelConfiguration) -> Bool {
        do {
            let validated = try configuration.validated()
            var preferences = state.preferences; preferences.localAI = validated
            try executor.updatePreferences(preferences); refresh(); resetAIRequests()
            statusMessage = "Local AI configuration saved."
            return true
        } catch { report(error); return false }
    }
    func testLocalConnection() async {
        connectionTask?.cancel()
        let revision = UUID(); connectionRevision = revision
        let configuration = state.preferences.localAI
        checkingLocalConnection = true; localConnectionState = "Checking…"; localConnectionMessage = nil
        let task = Task { @MainActor in
            do {
                let identity = try await localClient.inspect(configuration)
                try Task.checkCancellation()
                guard connectionRevision == revision else { return }
                localModelIdentity = identity
                localConnectionState = "Connected"
                localConnectionMessage = "\(identity.model) · Ollama \(identity.runtimeVersion) · Local execution enforced"
            } catch is CancellationError {
                guard connectionRevision == revision else { return }
                localConnectionState = "Cancelled"
            } catch {
                guard connectionRevision == revision else { return }
                localConnectionState = "Unavailable"; localConnectionMessage = error.localizedDescription
                localModelIdentity = nil
            }
            guard connectionRevision == revision else { return }
            checkingLocalConnection = false
        }
        connectionTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func cancelLocalConnectionTest() {
        connectionTask?.cancel(); connectionRevision = UUID(); checkingLocalConnection = false
        localConnectionState = "Cancelled"; localConnectionMessage = nil
    }
    func clearAICache() async {
        resetAIRequests()
        do {
            try await cacheStore.clear()
            try executor.clearAIResults(); refresh()
            statusMessage = "Cleared generated AI results. Accepted categories and messages are unchanged."
            aiRevision = UUID()
        } catch { report(error) }
    }
    private func performAI<T: Sendable>(for message: MailMessage? = nil, operation: (any AIProvider) async throws -> T) async throws -> T {
        try requireAI()
        research.record(.aiRequested)
        let identity = aiRequestIdentity
        let mode = state.preferences.aiMode
        do {
            let result = try await operation(ai)
            try Task.checkCancellation()
            guard identity == aiRequestIdentity else { throw CancellationError() }
            if let message {
                guard let current = state.messages.first(where: { $0.id == message.id }),
                      current.accountID == message.accountID, current.subject == message.subject, current.body == message.body, current.from == message.from else { throw CancellationError() }
            }
            if mode == .local { localConnectionState = "Connected"; localConnectionMessage = "\(state.preferences.localAI.model) · Local inference" }
            return result
        } catch is CancellationError { throw CancellationError() } catch {
            try Task.checkCancellation()
            guard identity == aiRequestIdentity else { throw CancellationError() }
            if mode == .local {
                switch error as? AIError {
                case .runtimeUnavailable, .modelUnavailable, .unsupportedRuntime, .invalidConfiguration:
                    localConnectionState = "Unavailable"
                case .unsupportedCapability: break
                default: localConnectionState = "Failed"
                }
                localConnectionMessage = error.localizedDescription
            }
            throw error
        }
    }
    func summary(for message: MailMessage) async throws -> MessageSummary {
        let result = try await performAI(for: message) { try await $0.summarize(message) }
        try executor.cacheSummary(result); refresh()
        return result
    }
    func classification(for message: MailMessage) async throws -> ClassificationSuggestion? {
        if let learned = learnedCategory(for: message) {
            try requireAI()
            try executor.cacheClassification(learned.classification, messageID: message.id); refresh()
            return learned.classification
        }
        let categories = state.categories
        let result = try await performAI(for: message) { try await $0.classify(message, categories: categories) }
        guard categories == state.categories else { throw CancellationError() }
        try executor.cacheClassification(result, messageID: message.id); refresh()
        return state.classifications.first { $0.messageID == message.id }
    }
    func actions(for message: MailMessage) async throws -> [ActionItem] {
        try await performAI(for: message) { try await $0.extractActions(message) }
    }
    func replies(for message: MailMessage) async throws -> [SuggestedReply] {
        try await performAI(for: message) { try await $0.generateReplies(message) }
    }
    func rewrite(_ text: String, tool: WritingTool, replyToMessageID: UUID? = nil, accountID: UUID? = nil) async throws -> String {
        let context = replyToMessageID.flatMap { id in state.messages.first { $0.id == id && (accountID == nil || $0.accountID == accountID) } }
        return try await performAI(for: context) { try await $0.rewrite(text, tool: tool, context: context) }
    }
    func assistantSearch(_ query: String) async throws -> (messages: [MailMessage], notice: String) {
        let result = try await searchIntelligence(query)
        let byID = Dictionary(scopedMessages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (result.messageIDs.compactMap { byID[$0] }, result.notice ?? "Matches in \(intelligenceScopeLabel)")
    }
    var intelligenceScopeLabel: String {
        if let accountID = accountScopeID { return displayedAccounts.first { $0.id == accountID }?.address.email ?? "this account" }
        return state.preferences.showDemoAccounts ? "Demo Mode" : "your connected accounts"
    }
    func learnedCategory(for message: MailMessage) -> LearnedCategorySuggestion? {
        CategoryPreferenceLearningService().suggestion(for: message, in: state, enabled: state.preferences.learnCategoryPreferences && aiEnabled)
    }
    var dailyBriefing: DailyBriefingSnapshot {
        let scope: MailIntelligenceScope = accountScopeID.map { .account($0) } ?? (state.preferences.showDemoAccounts ? .demo : .realAccounts)
        return PriorityBriefingService().build(snapshot: state, scope: scope, actions: embeddedAIEnabled ? attentionItems : [], aiProviderLabel: embeddedAIEnabled ? briefingProviderLabel : nil,
                                              includeTextRules: state.preferences.researchMode != .traditional && state.preferences.automationLevel != .manual)
    }
    func assistantAnswer(_ query: String) async throws -> MailAssistantResult {
        research.record(.search)
        if aiEnabled { research.record(.aiRequested) }
        let identity = aiRequestIdentity
        let messages = scopedMessages.filter { $0.folder != .trash }
        let service = MailIntelligenceService(provider: aiEnabled ? ai : nil)
        let result = try await service.answer(query: query, messages: messages, accountIDs: Set(messages.map(\.accountID)))
        try Task.checkCancellation()
        guard identity == aiRequestIdentity,
              result.sources.allSatisfy({ source in scopedMessages.contains(where: { source.matches($0) }) }) else { throw CancellationError() }
        return result
    }
    private func searchIntelligence(_ query: String) async throws -> MailSearchResult {
        research.record(.search)
        let identity = aiRequestIdentity
        let messages = scopedMessages.filter { $0.folder != .trash }
        let result = try await MailIntelligenceService(provider: aiEnabled ? ai : nil)
            .search(query: query, messages: messages, accountIDs: Set(messages.map(\.accountID)))
        try Task.checkCancellation()
        guard identity == aiRequestIdentity else { throw CancellationError() }
        return result
    }
    func cancelBriefing(userInitiated: Bool = false) {
        briefingTask?.cancel(); briefingRevision = UUID(); briefingProgress = nil
        if userInitiated { briefingError = "AI briefing cancelled. Your messages remain available." }
    }
    func refreshBriefing() async {
        cancelBriefing(); attentionItems = []; briefingError = nil
        guard aiEnabled else { return }
        briefingProviderLabel = state.preferences.aiMode == .local ? "Local AI · \(state.preferences.localAI.model)" : "Demo AI"
        let revision = UUID(); briefingRevision = revision
        let messages = Array(scopedMessages.filter { $0.folder == .inbox }.sorted { $0.date > $1.date }.prefix(state.preferences.showDemoAccounts ? 50 : 20))
        let task = Task { @MainActor in
            var items: [ActionItem] = []
            do {
                for (index, message) in messages.enumerated() {
                    try Task.checkCancellation()
                    guard briefingRevision == revision else { return }
                    briefingProgress = "Reviewing \(index + 1) of \(messages.count) messages…"
                    items += try await actions(for: message)
                    try Task.checkCancellation()
                    guard briefingRevision == revision else { return }
                    attentionItems = items
                }
            } catch is CancellationError { } catch {
                if briefingRevision == revision { briefingError = error.localizedDescription }
            }
            if briefingRevision == revision { briefingProgress = nil }
        }
        briefingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func clearSemanticSearch() {
        searchTask?.cancel(); semanticResults = nil; searchNotice = nil; searching = false; searchResultLabel = "Text matches"
    }
    func semanticSearch() {
        clearSemanticSearch()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard aiEnabled else { searchNotice = "AI is off. Showing text matches."; return }
        searching = true
        searchTask = Task {
            do {
                let result = try await searchIntelligence(query)
                try Task.checkCancellation()
                guard query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                semanticResults = result.messageIDs
                searchResultLabel = result.mode == .text || result.mode == .textFallback ? "Text matches" : "Expanded matches"
                reconcileSelection()
                searchNotice = result.notice ?? "\(searchResultLabel) · \(visibleMessages.count) in \(title)"
                searching = false
            } catch is CancellationError { } catch {
                guard !Task.isCancelled else { return }
                searchNotice = "Semantic search unavailable. Showing text matches."
                semanticResults = nil; searching = false
            }
        }
    }
}

enum AppError: LocalizedError {
    case aiDisabled
    var errorDescription: String? { "AI assistance is off. You can enable Demo AI in Settings." }
}
