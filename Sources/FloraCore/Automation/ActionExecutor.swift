import Foundation

/// The only mutation gateway. Providers and UI share this state; AI providers receive
/// values and cannot access the executor. Changes become visible only after save succeeds.
@MainActor
public final class ActionExecutor {
    public private(set) var state: AppSnapshot
    private let repository: any MailRepository
    private let now: () -> Date
    private struct UndoRecord {
        var actionID: UUID
        var before: AppSnapshot
        var after: AppSnapshot
    }
    private var undoStack: [UndoRecord] = []

    public init(repository: any MailRepository, initialState: AppSnapshot, now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.state = initialState
        self.now = now
        // History persists, but inverse operations are deliberately session-only.
        for index in state.history.indices { state.history[index].canUndo = false }
        for index in state.remoteActionHistory.indices where state.remoteActionHistory[index].status == .prepared {
            state.remoteActionHistory[index].status = .outcomeUnknown
            state.remoteActionHistory[index].errorMessage = "The previous action was interrupted. Check the account before retrying."
            let action = state.remoteActionHistory[index].proposal.action
            if let id = action.draftID, let draftIndex = state.drafts.firstIndex(where: { $0.id == id }) {
                if action.isSend { state.drafts[draftIndex].deliveryState = .outcomeUnknown }
                else { state.drafts[draftIndex].draftSyncStatus = .outcomeUnknown }
            }
        }
        for index in state.accounts.indices where state.accounts[index].status == .syncing {
            state.accounts[index].status = state.accounts[index].credentialReference == nil ? .disconnected : .connected
            state.accounts[index].syncState.errorMessage = "The previous sync was interrupted. Cached mail remains available."
        }
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    @discardableResult
    public func execute(_ proposal: ProposedAction, confirmed: Bool = false, ruleID: UUID? = nil) throws -> ExecutedAction {
        let timestamp = now()
        try ActionPermissionPolicy.validate(proposal, confirmed: confirmed, ruleID: ruleID, state: state, now: timestamp)
        let before = state
        var candidate = state
        switch proposal.type {
        case .archive(let ids):
            try updateMessages(ids, in: &candidate) { $0.folder = .archive }
        case .move(let ids, let folder):
            try updateMessages(ids, in: &candidate) { $0.folder = folder }
        case .markRead(let ids, let isRead):
            try updateMessages(ids, in: &candidate) { $0.isRead = isRead }
        case .flag(let ids, let isFlagged):
            try updateMessages(ids, in: &candidate) { $0.isFlagged = isFlagged }
        case .classify(let messageID, let categoryID):
            guard categoryID == nil || candidate.categories.contains(where: { $0.id == categoryID }) else {
                throw MailActionError.categoryNotFound
            }
            if proposal.origin == .ai {
                guard let categoryID, candidate.classifications.contains(where: { $0.messageID == messageID && $0.categoryID == categoryID }) else {
                    throw MailActionError.staleClassification
                }
            }
            try updateMessages([messageID], in: &candidate) { $0.categoryID = categoryID }
            candidate.classifications.removeAll { $0.messageID == messageID }
        case .createCategory(var category):
            category.name = try validatedCategoryName(category.name, state: candidate)
            guard !candidate.categories.contains(where: { $0.id == category.id }) else { throw MailActionError.duplicateCategory }
            candidate.categories.append(category)
        case .renameCategory(let id, let name):
            guard let index = candidate.categories.firstIndex(where: { $0.id == id }) else { throw MailActionError.categoryNotFound }
            candidate.categories[index].name = try validatedCategoryName(name, excluding: id, state: candidate)
        case .deleteCategory(let id):
            guard candidate.categories.contains(where: { $0.id == id }) else { throw MailActionError.categoryNotFound }
            candidate.categories.removeAll { $0.id == id }
            for index in candidate.messages.indices where candidate.messages[index].categoryID == id {
                candidate.messages[index].categoryID = nil
            }
            candidate.classifications.removeAll { $0.categoryID == id }
        case .saveDraft(var draft):
            draft.updatedAt = timestamp
            if let index = candidate.drafts.firstIndex(where: { $0.id == draft.id }) {
                let old = candidate.drafts[index]
                // An editor owns text, never remote identity or delivery authority.
                guard draft.accountID == old.accountID else { throw MailActionError.readOnlyAccount }
                draft.providerDraftID = old.providerDraftID; draft.providerDraftMessageID = old.providerDraftMessageID
                draft.deliveryState = old.deliveryState
                draft.draftSyncStatus = old.draftSyncStatus == .outcomeUnknown ? .outcomeUnknown : (Self.sameDraftContent(draft, old) ? old.draftSyncStatus : .localOnly)
                candidate.drafts[index] = draft
            } else {
                draft.providerDraftID = nil; draft.providerDraftMessageID = nil
                draft.deliveryState = .notSent; draft.draftSyncStatus = .localOnly
                candidate.drafts.append(draft)
            }
        case .deleteDraft(let id):
            guard candidate.drafts.contains(where: { $0.id == id }) else { throw MailActionError.draftNotFound }
            candidate.drafts.removeAll { $0.id == id }
        case .sendDraft(let id):
            guard let draft = candidate.drafts.first(where: { $0.id == id }) else { throw MailActionError.draftNotFound }
            let recipients: [MailAddress], copied: [MailAddress], blindCopied: [MailAddress]
            do {
                recipients = try OutgoingMIMEComposer.addresses(draft.to)
                copied = try OutgoingMIMEComposer.addresses(draft.cc)
                blindCopied = try OutgoingMIMEComposer.addresses(draft.bcc)
                guard !(recipients + copied + blindCopied).isEmpty, (recipients + copied + blindCopied).count <= 100 else { throw MailActionError.invalidRecipient }
            } catch { throw MailActionError.invalidRecipient }
            guard !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailActionError.emptySubject }
            let reply = candidate.messages.first { $0.id == draft.replyToMessageID }
            let sendingAccount: MailAccount?
            if let accountID = draft.accountID { sendingAccount = candidate.accounts.first { $0.id == accountID && !$0.isRemote } }
            else if let reply { sendingAccount = candidate.accounts.first { $0.id == reply.accountID && !$0.isRemote } }
            else { sendingAccount = candidate.accounts.first { !$0.isRemote } }
            guard let account = sendingAccount else { throw MailActionError.accountNotFound }
            // Demo delivery is only a local Sent record. There is no networking.
            candidate.messages.append(MailMessage(accountID: account.id, threadID: reply?.threadID ?? UUID(), from: account.address,
                                                 to: recipients, subject: draft.subject, body: draft.body, date: timestamp, folder: .sent, isRead: true,
                                                 attachments: draft.attachments.map { MailAttachment(id: $0.id, name: $0.name, size: $0.size, mimeType: $0.mimeType) }, cc: copied))
            candidate.drafts.removeAll { $0.id == id }
        }
        var recordedProposal = proposal
        if proposal.origin == .automation, let ruleID, let rule = state.rules.first(where: { $0.id == ruleID }) {
            recordedProposal.explanation += " · Rule: \(rule.name)"
        }
        let executed = ExecutedAction(proposal: recordedProposal, date: timestamp)
        candidate.history.append(executed)
        try repository.save(candidate)
        state = candidate
        undoStack.append(UndoRecord(actionID: executed.id, before: before, after: candidate))
        return executed
    }

    /// Confirmation is tied to the actual suggestion the user reviewed.
    @discardableResult
    public func acceptClassification(_ suggestion: ClassificationSuggestion) throws -> ExecutedAction {
        guard state.classifications.contains(suggestion), state.messages.contains(where: { $0.id == suggestion.messageID }) else {
            throw MailActionError.staleClassification
        }
        return try execute(ProposedAction(type: .classify(messageID: suggestion.messageID, categoryID: suggestion.categoryID),
                                          explanation: "Accepted category suggestion: \(suggestion.explanation)", origin: .ai), confirmed: true)
    }

    public func undo() throws {
        guard let record = undoStack.last else { throw MailActionError.noUndo }
        var candidate = state
        restoreMessageChanges(before: record.before.messages, after: record.after.messages, current: &candidate.messages)
        restoreChanges(before: record.before.categories, after: record.after.categories, current: &candidate.categories)
        let authoritativeDrafts = Dictionary(candidate.drafts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        restoreChanges(before: record.before.drafts, after: record.after.drafts, current: &candidate.drafts)
        for index in candidate.drafts.indices {
            guard let latest = authoritativeDrafts[candidate.drafts[index].id] else { continue }
            candidate.drafts[index].providerDraftID = latest.providerDraftID
            candidate.drafts[index].providerDraftMessageID = latest.providerDraftMessageID
            candidate.drafts[index].deliveryState = latest.deliveryState
            candidate.drafts[index].draftSyncStatus = latest.draftSyncStatus == .outcomeUnknown ? .outcomeUnknown : (Self.sameDraftContent(candidate.drafts[index], latest) ? latest.draftSyncStatus : .localOnly)
        }
        // Keep AI work produced after unrelated actions. Restore only predictions
        // affected by classification/category mutations, grouped by source message.
        let changedPredictions = Set((record.before.classifications + record.after.classifications).filter {
            record.before.classifications.contains($0) != record.after.classifications.contains($0)
        }.map(\.messageID))
        candidate.classifications.removeAll { changedPredictions.contains($0.messageID) }
        candidate.classifications += record.before.classifications.filter { prediction in
            guard changedPredictions.contains(prediction.messageID),
                  let oldSource = record.before.messages.first(where: { $0.id == prediction.messageID }),
                  let currentSource = candidate.messages.first(where: { $0.id == prediction.messageID }) else { return false }
            return Self.sameAIContent(oldSource, currentSource)
        }
        let availableCategories = Set(candidate.categories.map(\.id))
        let availableMessages = Set(candidate.messages.map(\.id))
        let uncategorizedMessages = Set(candidate.messages.filter { $0.categoryID == nil }.map(\.id))
        candidate.summaries.removeAll { !availableMessages.contains($0.messageID) }
        candidate.classifications.removeAll {
            !availableCategories.contains($0.categoryID) || !uncategorizedMessages.contains($0.messageID)
        }
        if let index = candidate.history.firstIndex(where: { $0.id == record.actionID }) {
            candidate.history[index].undone = true
            candidate.history[index].canUndo = false
        }
        try repository.save(candidate)
        state = candidate
        undoStack.removeLast()
    }

    public func updatePreferences(_ preferences: UserPreferences) throws {
        var candidate = state
        candidate.preferences = preferences
        try repository.save(candidate)
        state = candidate
    }

    /// Account and synchronization changes are trusted service operations, never
    /// model actions. They share the same transactional repository gateway.
    public func upsertAccount(_ account: MailAccount) throws {
        var candidate = state
        if let index = candidate.accounts.firstIndex(where: { $0.id == account.id }) {
            let existing = candidate.accounts[index]
            guard existing.providerType == account.providerType,
                  existing.providerAccountID == nil || account.providerAccountID == existing.providerAccountID else { throw MailSyncError.accountMismatch }
            candidate.accounts[index] = account
        } else {
            guard !candidate.accounts.contains(where: {
                $0.providerType == account.providerType && account.providerAccountID != nil && $0.providerAccountID == account.providerAccountID
            }) else { throw MailSyncError.accountMismatch }
            candidate.accounts.append(account)
        }
        try repository.save(candidate); state = candidate
    }

    public func updateAccount(_ account: MailAccount) throws { try upsertAccount(account) }

    public func setAccountSyncStatus(accountID: UUID, status: MailAccountStatus, errorMessage: String? = nil, lastSuccessfulSync: Date? = nil) throws {
        guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else { throw MailSyncError.accountNotFound }
        var candidate = state
        candidate.accounts[index].status = status
        candidate.accounts[index].syncState.errorMessage = errorMessage
        if let lastSuccessfulSync { candidate.accounts[index].syncState.lastSuccessfulSync = lastSuccessfulSync }
        try repository.save(candidate); state = candidate
    }

    public func updateRemoteFolders(_ folders: [MailFolderDescriptor], accountID: UUID) throws {
        guard state.accounts.contains(where: { $0.id == accountID }) else { throw MailSyncError.accountNotFound }
        guard folders.allSatisfy({ $0.accountID == accountID && !$0.id.isEmpty }), Set(folders.map(\.id)).count == folders.count else { throw MailSyncError.accountMismatch }
        var candidate = state
        candidate.remoteFolders.removeAll { $0.accountID == accountID }
        candidate.remoteFolders += folders
        try repository.save(candidate); state = candidate
    }

    /// Incoming pages are deduplicated by account + provider ID. Server flags and
    /// content may change; local classifications and valid downloaded files survive.
    public func commitSyncPage(_ page: MailSyncPage, accountID: UUID) throws {
        guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID && $0.isRemote }) else { throw MailSyncError.accountNotFound }
        guard page.messages.allSatisfy({ $0.accountID == accountID && !$0.providerID.isEmpty }) else { throw MailSyncError.accountMismatch }
        var candidate = state
        let deleted = Set(page.deletedProviderMessageIDs)
        let deletedLocalIDs = Set(candidate.messages.filter { $0.accountID == accountID && deleted.contains($0.providerID) }.map(\.id))
        candidate.messages.removeAll { deletedLocalIDs.contains($0.id) }
        candidate.summaries.removeAll { deletedLocalIDs.contains($0.messageID) }
        candidate.classifications.removeAll { deletedLocalIDs.contains($0.messageID) }
        for update in page.messageStateUpdates {
            if let index = candidate.messages.firstIndex(where: { $0.accountID == accountID && $0.providerID == update.providerID }) {
                candidate.messages[index].isRead = update.isRead
                candidate.messages[index].isFlagged = update.isFlagged
            }
        }
        mergeRemoteMessages(page.messages, accountID: accountID, into: &candidate)
        candidate.accounts[accountIndex].syncState.checkpoint = page.checkpoint
        candidate.accounts[accountIndex].syncState.errorMessage = nil
        try repository.save(candidate); state = candidate
    }

    /// A conversation read is a separate transaction from mailbox pagination.
    /// Missing messages are not interpreted as deletions, and neither successful
    /// nor failed retrieval moves the account's durable synchronization cursor.
    public func commitRemoteThread(_ thread: MailThread, sourceMessageID: UUID) throws {
        guard let source = state.messages.first(where: { $0.id == sourceMessageID }) else { throw MailThreadError.sourceUnavailable }
        guard let account = state.accounts.first(where: { $0.id == source.accountID && $0.isRemote }) else { throw MailSyncError.accountNotFound }
        guard account.status != .disconnected else { throw MailSyncError.disconnected }
        guard let providerThreadID = source.providerThreadID, !providerThreadID.isEmpty,
              thread.id == source.threadID, !thread.messages.isEmpty,
              thread.messages.contains(where: { $0.providerID == source.providerID }) else { throw MailThreadError.invalidThread }
        guard thread.messages.count <= MailThreadService.maximumMessages else { throw MailThreadError.tooLarge }
        guard thread.messages.allSatisfy({ $0.accountID == account.id }) else { throw MailSyncError.accountMismatch }
        var textBytes = 0
        for message in thread.messages {
            guard !message.providerID.isEmpty, message.providerID.utf8.count <= 8_192,
                  message.providerThreadID == providerThreadID, message.threadID == source.threadID else { throw MailThreadError.invalidThread }
            textBytes += message.body.utf8.count + (message.htmlBody?.utf8.count ?? 0) + message.subject.utf8.count
            guard textBytes <= MailThreadService.maximumTextBytes else { throw MailThreadError.tooLarge }
        }
        var candidate = state
        mergeRemoteMessages(thread.messages, accountID: account.id, into: &candidate)
        try repository.save(candidate); state = candidate
    }

    /// Both sync pages and explicit conversation reads use identical identity,
    /// annotation, attachment and source-cache preservation rules.
    private func mergeRemoteMessages(_ messages: [MailMessage], accountID: UUID, into candidate: inout AppSnapshot) {
        for var message in messages {
            let canonicalID = StableMailIdentity.message(accountID: accountID, providerID: message.providerID)
            message.id = canonicalID
            message.threadID = StableMailIdentity.thread(accountID: accountID, providerID: message.providerThreadID ?? message.providerID)
            // A provider supplies metadata, never authority to open a local path.
            message.attachments = message.attachments.map { attachment in
                var value = attachment; value.downloadState = .notDownloaded; value.localRelativePath = nil
                return value
            }
            if let index = candidate.messages.firstIndex(where: { $0.accountID == accountID && $0.providerID == message.providerID }) {
                let old = candidate.messages[index]
                // Keep the ID already referenced by local annotations/drafts even
                // when importing a store written by an earlier adapter revision.
                message.id = old.id; message.categoryID = old.categoryID
                if message.body.isEmpty, message.htmlBody == nil, !message.contentWarnings.isEmpty,
                   !old.body.isEmpty || old.htmlBody?.isEmpty == false {
                    // A failed body read is not evidence that previously cached
                    // content was removed. Retain it with an explicit freshness
                    // warning while still accepting fresh envelope and flag data.
                    message.body = old.body; message.htmlBody = old.htmlBody; message.attachments = old.attachments
                    message.contentWarnings = Array(Set(message.contentWarnings + old.contentWarnings + [
                        "Showing previously cached content and attachments because the latest message body is unavailable."
                    ])).sorted()
                }
                let sameSource = Self.sameAIContent(old, message)
                if !sameSource {
                    candidate.summaries.removeAll { $0.messageID == old.id }
                    candidate.classifications.removeAll { $0.messageID == old.id }
                }
                message.attachments = message.attachments.map { attachment in
                    guard let prior = old.attachments.first(where: { $0.providerID != nil && $0.providerID == attachment.providerID && $0.name == attachment.name && $0.size == attachment.size }) else { return attachment }
                    var result = attachment; result.id = prior.id; result.downloadState = prior.downloadState; result.localRelativePath = prior.localRelativePath
                    return result
                }
                candidate.messages[index] = message
            } else {
                // An external adapter cannot manufacture a confirmed local category.
                message.categoryID = nil
                candidate.messages.append(message)
            }
        }
    }

    public func markAttachmentDownloaded(messageID: UUID, attachmentID: UUID, relativePath: String) throws {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { throw MailSyncError.unsupportedContent }
        var candidate = state
        guard let messageIndex = candidate.messages.firstIndex(where: { $0.id == messageID }),
              let attachmentIndex = candidate.messages[messageIndex].attachments.firstIndex(where: { $0.id == attachmentID }) else { throw MailActionError.messageNotFound }
        candidate.messages[messageIndex].attachments[attachmentIndex].downloadState = .downloaded
        candidate.messages[messageIndex].attachments[attachmentIndex].localRelativePath = relativePath
        try repository.save(candidate); state = candidate
    }

    public func cache(summary: MessageSummary, classification: ClassificationSuggestion?) throws {
        guard state.messages.contains(where: { $0.id == summary.messageID }) else { throw MailActionError.messageNotFound }
        if let classification {
            guard classification.messageID == summary.messageID else { throw MailActionError.staleClassification }
            guard state.categories.contains(where: { $0.id == classification.categoryID }) else { throw MailActionError.categoryNotFound }
        }
        var candidate = state
        candidate.summaries.removeAll { $0.messageID == summary.messageID }
        candidate.summaries.append(summary)
        candidate.classifications.removeAll { $0.messageID == summary.messageID }
        // A user-confirmed category takes precedence over a prediction.
        if let classification, candidate.messages.first(where: { $0.id == summary.messageID })?.categoryID == nil {
            candidate.classifications.append(classification)
        }
        try repository.save(candidate)
        state = candidate
    }

    /// Capabilities complete independently; a failed summary must not block classification.
    public func cacheSummary(_ summary: MessageSummary) throws {
        guard state.messages.contains(where: { $0.id == summary.messageID }) else { throw MailActionError.messageNotFound }
        var candidate = state
        candidate.summaries.removeAll { $0.messageID == summary.messageID }
        candidate.summaries.append(summary)
        try repository.save(candidate)
        state = candidate
    }

    public func cacheClassification(_ suggestion: ClassificationSuggestion?, messageID: UUID) throws {
        guard let message = state.messages.first(where: { $0.id == messageID }) else { throw MailActionError.messageNotFound }
        if let suggestion {
            guard suggestion.messageID == messageID else { throw MailActionError.staleClassification }
            guard state.categories.contains(where: { $0.id == suggestion.categoryID }) else { throw MailActionError.categoryNotFound }
        }
        var candidate = state
        candidate.classifications.removeAll { $0.messageID == messageID }
        if let suggestion, message.categoryID == nil { candidate.classifications.append(suggestion) }
        try repository.save(candidate)
        state = candidate
    }

    public func clearAIResults() throws {
        var candidate = state
        candidate.summaries = []; candidate.classifications = []
        try repository.save(candidate)
        state = candidate
    }

    public func saveAutomationRule(_ rule: AutomationRule, confirmed: Bool = false) throws {
        guard rule.olderThanDays >= 1, rule.olderThanDays <= 36_500,
              (try? Self.recipientAddresses(rule.senderEmail))?.count == 1,
              !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailActionError.invalidAutomation }
        var authorizedRule = rule
        if rule.enabled {
            guard confirmed else { throw MailActionError.confirmationRequired }
            authorizedRule.authorizedAt = now()
        } else { authorizedRule.authorizedAt = nil }
        var candidate = state
        candidate.rules.removeAll { $0.id == rule.id }
        candidate.rules.append(authorizedRule)
        try repository.save(candidate)
        state = candidate
    }

    private func updateMessages(_ ids: [UUID], in snapshot: inout AppSnapshot, change: (inout MailMessage) -> Void) throws {
        guard !ids.isEmpty else { throw MailActionError.emptySelection }
        let selected = Set(ids)
        guard selected.isSubset(of: Set(snapshot.messages.map(\.id))) else { throw MailActionError.messageNotFound }
        for index in snapshot.messages.indices where selected.contains(snapshot.messages[index].id) { change(&snapshot.messages[index]) }
    }

    private func validatedCategoryName(_ name: String, excluding id: UUID? = nil, state: AppSnapshot) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 50 else { throw MailActionError.invalidCategoryName }
        guard !state.categories.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) else {
            throw MailActionError.duplicateCategory
        }
        return cleaned
    }

    private func restoreChanges<T: Identifiable & Equatable>(before: [T], after: [T], current: inout [T]) where T.ID == UUID {
        let changedIDs = Set((before + after).filter { before.contains($0) != after.contains($0) }.map(\.id))
        // Replace edited records in place so Undo does not reorder the user's
        // categories. Records removed by the action return to their prior slot.
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        current = current.compactMap { changedIDs.contains($0.id) ? previous[$0.id] : $0 }
        for (index, record) in before.enumerated() where changedIDs.contains(record.id) && !current.contains(where: { $0.id == record.id }) {
            current.insert(record, at: min(index, current.count))
        }
    }

    /// Undo local annotation changes without overwriting newer synchronized
    /// source text, flags, attachments or server deletion with an old snapshot.
    private func restoreMessageChanges(before: [MailMessage], after: [MailMessage], current: inout [MailMessage]) {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        current.removeAll { old[$0.id] == nil && new[$0.id] != nil }
        for index in current.indices {
            guard let previous = old[current[index].id], let changed = new[current[index].id] else { continue }
            if previous.categoryID != changed.categoryID { current[index].categoryID = previous.categoryID }
            if previous.folder != changed.folder { current[index].folder = previous.folder }
            if previous.isRead != changed.isRead { current[index].isRead = previous.isRead }
            if previous.isFlagged != changed.isFlagged { current[index].isFlagged = previous.isFlagged }
        }
    }

    private static func sameAIContent(_ lhs: MailMessage, _ rhs: MailMessage) -> Bool {
        lhs.subject == rhs.subject && lhs.body == rhs.body && lhs.from == rhs.from && lhs.to == rhs.to && lhs.cc == rhs.cc && lhs.htmlBody == rhs.htmlBody
    }

    private static func recipientAddresses(_ input: String) throws -> [MailAddress] {
        let parts = input.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, parts.allSatisfy({ address in
            address.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil
        }) else { throw MailActionError.invalidRecipient }
        return parts.map { MailAddress(name: "", email: $0) }
    }
}

extension ActionExecutor {
    // These methods deliberately remain module-internal: the application can
    // execute only through RemoteActionCoordinator, never publish fake receipts.
    func beginRemoteAction(_ proposal: RemoteMailProposal) throws {
        guard !state.remoteActionHistory.contains(where: { $0.id == proposal.id }) else { throw RemoteActionError.staleProposal }
        guard !state.remoteActionHistory.contains(where: { $0.proposal.accountID == proposal.accountID && $0.status == .prepared }) else { throw RemoteActionError.alreadyExecuting }
        var candidate = state
        var record = RemoteActionRecord(proposal: proposal, date: now())
        record.undoState = proposal.action.messageIDs.compactMap { id in state.messages.first(where: { $0.id == id }).map(RemoteUndoState.init) }
        candidate.remoteActionHistory.append(record)
        if proposal.action.isSend, let draftID = proposal.action.draftID,
           let index = candidate.drafts.firstIndex(where: { $0.id == draftID }) { candidate.drafts[index].deliveryState = .sending }
        do { try repository.save(candidate) } catch { throw RemoteActionError.persistenceFailed }
        state = candidate
    }

    func failRemoteAction(_ id: UUID, error: RemoteActionError) throws {
        guard let index = state.remoteActionHistory.firstIndex(where: { $0.id == id }) else { throw RemoteActionError.invalidRequest }
        var candidate = state
        let proposal = candidate.remoteActionHistory[index].proposal
        let unknown = error == .outcomeUnknown || error == .persistenceFailed
        candidate.remoteActionHistory[index].status = unknown ? .outcomeUnknown : .failed
        candidate.remoteActionHistory[index].errorMessage = error.localizedDescription
        if let draftID = proposal.action.draftID, let draftIndex = candidate.drafts.firstIndex(where: { $0.id == draftID }) {
            if proposal.action.isSend { candidate.drafts[draftIndex].deliveryState = unknown ? .outcomeUnknown : .notSent }
            else if unknown { candidate.drafts[draftIndex].draftSyncStatus = .outcomeUnknown }
        }
        try repository.save(candidate); state = candidate
    }

    func completeRemoteAction(_ request: AuthorizedRemoteAction, receipt: RemoteActionReceipt) throws -> RemoteActionRecord {
        guard let index = state.remoteActionHistory.firstIndex(where: { $0.id == request.id && $0.status == .prepared }) else { throw RemoteActionError.invalidRequest }
        let accountID = request.account.id
        guard receipt.messages.allSatisfy({ $0.accountID == accountID && !$0.providerID.isEmpty }),
              Set(receipt.messages.map(\.providerID)).count == receipt.messages.count else { throw MailSyncError.accountMismatch }
        var candidate = state
        if request.action.draftID != nil {
            let previousDraftID = request.draft?.providerDraftMessageID ?? request.draft?.providerDraftID
            let permittedRemovals = Set([previousDraftID].compactMap { $0 })
            let removed = Set(receipt.removedProviderMessageIDs)
            guard receipt.messages.isEmpty, receipt.removedProviderMessageIDs.count <= 1,
                  removed.isSubset(of: permittedRemovals), !removed.contains("") else { throw MailSyncError.accountMismatch }
            if !request.action.isSend {
                guard let reference = receipt.draftReference, !reference.providerDraftID.isEmpty,
                      !removed.contains(reference.providerMessageID ?? reference.providerDraftID) else { throw MailSyncError.unsupportedContent }
            }
            // IMAP can confirm replacement or post-send cleanup of one exact old
            // Drafts UID. That receipt never authorizes deletion of other mail.
            let removedLocalIDs = Set(candidate.messages.filter { $0.accountID == accountID && removed.contains($0.providerID) }.map(\.id))
            candidate.messages.removeAll { removedLocalIDs.contains($0.id) }
            candidate.summaries.removeAll { removedLocalIDs.contains($0.messageID) }
            candidate.classifications.removeAll { removedLocalIDs.contains($0.messageID) }
        } else {
            let originalIDs = Set(request.messages.map(\.providerID)), removed = Set(receipt.removedProviderMessageIDs)
            guard removed.isSubset(of: originalIDs), receipt.messages.count == request.messages.count else { throw MailSyncError.accountMismatch }
            let returnedIDs = Set(receipt.messages.map(\.providerID))
            switch request.action {
            case .markRead(_, let value):
                guard removed.isEmpty, returnedIDs == originalIDs, receipt.messages.allSatisfy({ $0.isRead == value }) else { throw MailSyncError.unsupportedContent }
            case .flag(_, let value):
                guard removed.isEmpty, returnedIDs == originalIDs, receipt.messages.allSatisfy({ $0.isFlagged == value }) else { throw MailSyncError.unsupportedContent }
            case .move(_, let destination):
                guard originalIDs.subtracting(returnedIDs) == removed, returnedIDs.subtracting(originalIDs).count == removed.count else { throw MailSyncError.accountMismatch }
                guard receipt.messages.allSatisfy({ $0.providerFolderIDs.contains(destination.id) }) else { throw MailSyncError.unsupportedContent }
            case .archive:
                guard originalIDs.subtracting(returnedIDs) == removed, returnedIDs.subtracting(originalIDs).count == removed.count else { throw MailSyncError.accountMismatch }
                if request.account.providerType == .gmail {
                    guard receipt.messages.allSatisfy({ !$0.providerFolderIDs.contains("INBOX") && $0.folder != .inbox }) else { throw MailSyncError.unsupportedContent }
                } else {
                    let archiveIDs = Set(candidate.remoteFolders.filter { $0.accountID == accountID && $0.role == .archive }.map(\.id))
                    guard !archiveIDs.isEmpty, receipt.messages.allSatisfy({ !archiveIDs.isDisjoint(with: $0.providerFolderIDs) }) else { throw MailSyncError.unsupportedContent }
                }
            default: throw MailSyncError.unsupportedContent
            }
            let removedLocalIDs = Set(candidate.messages.filter { $0.accountID == accountID && removed.contains($0.providerID) }.map(\.id))
            // An identity replacement is accepted only from an acknowledged move.
            // Transfer local annotations using source RFC Message-ID when unique.
            let replacements = receipt.messages
            for incomingIndex in replacements.indices where !originalIDs.contains(replacements[incomingIndex].providerID) {
                let incoming = replacements[incomingIndex]
                let matches = request.messages.filter {
                    removed.contains($0.providerID) && ((removed.count == 1 && replacements.count == 1) || ($0.internetMessageID != nil && $0.internetMessageID == incoming.internetMessageID))
                }
                if matches.count == 1, let old = candidate.messages.first(where: { $0.id == matches[0].id }) {
                    // mergeRemoteMessages preserves annotations on existing IDs;
                    // retain the local record while replacing its provider identity.
                    if let oldIndex = candidate.messages.firstIndex(where: { $0.id == old.id }) { candidate.messages[oldIndex].providerID = incoming.providerID }
                }
            }
            candidate.messages.removeAll { $0.accountID == accountID && removed.contains($0.providerID) }
            let trulyRemoved = removedLocalIDs.subtracting(candidate.messages.map(\.id))
            candidate.summaries.removeAll { trulyRemoved.contains($0.messageID) }
            candidate.classifications.removeAll { trulyRemoved.contains($0.messageID) }
            mergeRemoteMessages(replacements, accountID: accountID, into: &candidate)
        }
        if let draftID = request.action.draftID, let draftIndex = candidate.drafts.firstIndex(where: { $0.id == draftID }) {
            if let reference = receipt.draftReference {
                candidate.drafts[draftIndex].providerDraftID = reference.providerDraftID
                candidate.drafts[draftIndex].providerDraftMessageID = reference.providerMessageID
            }
            if request.action.isSend { candidate.drafts[draftIndex].deliveryState = .sent }
            else { candidate.drafts[draftIndex].draftSyncStatus = Self.sameDraftContent(candidate.drafts[draftIndex], request.draft) ? .synced : .localOnly }
        }
        candidate.remoteActionHistory[index].status = .completed
        if let originalID = request.action.isSend ? nil : candidate.remoteActionHistory[index].proposal.undoesRecordID,
           let originalIndex = candidate.remoteActionHistory.firstIndex(where: { $0.id == originalID }) {
            candidate.remoteActionHistory[originalIndex].undoneByActionID = request.id
        }
        candidate.remoteActionHistory[index].sentProviderMessageID = receipt.sentProviderMessageID
        let advisories = Self.boundedRemoteAdvisories(receipt.advisories)
        candidate.remoteActionHistory[index].errorMessage = advisories.isEmpty ? nil : advisories.joined(separator: "\n")
        try repository.save(candidate); state = candidate
        return candidate.remoteActionHistory[index]
    }

    private static func boundedRemoteAdvisories(_ advisories: [String]) -> [String] {
        let omitted = "Additional provider guidance could not be displayed. Review the account if further cleanup is needed."
        // Advice cannot turn an acknowledged send into an unknown result. Invalid
        // or unbounded advice is replaced, while the delivery acknowledgement stays.
        guard advisories.count <= 4 else { return [omitted] }
        var safe: [String] = []
        for value in advisories {
            guard value.utf8.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                if !safe.contains(omitted) { safe.append(omitted) }; continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { safe.append(trimmed) }
        }
        return safe
    }

    func resolveRemoteOutcome(_ id: UUID, resolution: RemoteOutcomeResolution) throws -> RemoteActionRecord {
        guard let index = state.remoteActionHistory.firstIndex(where: { $0.id == id && $0.status == .outcomeUnknown }) else { throw RemoteActionError.invalidRequest }
        var candidate = state
        candidate.remoteActionHistory[index].resolution = resolution
        candidate.remoteActionHistory[index].resolvedAt = now()
        candidate.remoteActionHistory[index].status = resolution == .confirmedApplied ? .completed : .failed
        candidate.remoteActionHistory[index].errorMessage = resolution == .confirmedApplied ? "User checked the account and confirmed the action was applied." : "User checked the account and confirmed the action was not applied. A new reviewed attempt is allowed."
        if resolution == .confirmedApplied, let originalID = candidate.remoteActionHistory[index].proposal.undoesRecordID,
           let originalIndex = candidate.remoteActionHistory.firstIndex(where: { $0.id == originalID }) {
            candidate.remoteActionHistory[originalIndex].undoneByActionID = id
        }
        let action = candidate.remoteActionHistory[index].proposal.action
        if let id = action.draftID, let draftIndex = candidate.drafts.firstIndex(where: { $0.id == id }) {
            if action.isSend { candidate.drafts[draftIndex].deliveryState = resolution == .confirmedApplied ? .sent : .notSent }
            else { candidate.drafts[draftIndex].draftSyncStatus = resolution == .confirmedApplied ? .outcomeUnknown : .localOnly }
        }
        try repository.save(candidate); state = candidate
        return candidate.remoteActionHistory[index]
    }

    private static func sameDraftContent(_ lhs: Draft, _ rhs: Draft?) -> Bool {
        guard let rhs else { return false }
        return lhs.accountID == rhs.accountID && lhs.replyToMessageID == rhs.replyToMessageID && lhs.to == rhs.to && lhs.cc == rhs.cc && lhs.bcc == rhs.bcc && lhs.subject == rhs.subject && lhs.body == rhs.body && lhs.attachments == rhs.attachments
    }
}
