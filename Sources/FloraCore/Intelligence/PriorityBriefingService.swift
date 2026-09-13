import Foundation

/// Builds a bounded local dashboard from cached values. No inference or mail
/// operation is performed here. Every cue names its rule or retained provider
/// and links to an actual message in the explicitly selected account scope.
public struct PriorityBriefingService: Sendable {
    public init() {}
    public func build(snapshot: AppSnapshot, scope: MailIntelligenceScope, actions: [ActionItem] = [], aiProviderLabel: String? = nil,
                      now: Date = Date(), calendar: Calendar = .current, limit: Int = 250) -> DailyBriefingSnapshot {
        let accounts = snapshot.accounts.filter { account in
            switch scope { case .account(let id): account.id == id; case .demo: !account.isRemote; case .realAccounts: account.isRemote }
        }
        let accountByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let messages = snapshot.messages.filter { accountByID[$0.accountID] != nil }
        let inbox = messages.filter { $0.folder == .inbox }.sorted {
            let leftPinned = $0.isFlagged || $0.isImportant, rightPinned = $1.isFlagged || $1.isImportant
            if leftPinned != rightPinned { return leftPinned }
            return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
        let considered = Array(inbox.prefix(min(max(limit, 1), 1_000)))
        let actionGroups = Dictionary(grouping: actions.prefix(3_000), by: \.messageID)
        let summaryGroups = Dictionary(grouping: snapshot.summaries, by: \.messageID)
        let sentGroups = Dictionary(grouping: messages.filter { $0.folder == .sent }, by: { threadKey($0) })
        let providerLabel = aiProviderLabel.flatMap(Self.validProviderLabel)
        var ranked: [(item: BriefingItem, score: Int)] = []
        for message in considered {
            guard let account = accountByID[message.accountID] else { continue }
            let lines = BriefingTextRules.directLines(message.body)
            let directText = lines.joined(separator: "\n")
            let messageAge = calendar.dateComponents([.day], from: calendar.startOfDay(for: message.date), to: calendar.startOfDay(for: now)).day ?? Int.max
            var signals: [(signal: BriefingSignal, score: Int)] = []
            if message.isFlagged {
                signals.append((BriefingSignal(messageID: message.id, kind: .flagged, title: "Flagged email", explanation: "This message is flagged in the cached mailbox. The briefing has not changed its flags.", provenance: .mailState), 90))
            }
            if message.isImportant {
                signals.append((BriefingSignal(messageID: message.id, kind: .important, title: "Marked important", explanation: "The mail provider marks this message important. This is mail metadata, not a new AI prediction.", provenance: .mailState), 80))
            }
            let reply = newestReply(to: message, account: account, candidates: sentGroups[threadKey(message)] ?? [])
            let addressedToAccount = message.to.contains { equalAddress($0.email, account.address.email) } && !equalAddress(message.from.email, account.address.email)
            let canSuggestReply = addressedToAccount && !BriefingTextRules.automatedSender(message.from.email)
            if let quote = BriefingTextRules.replyRequest(in: lines), canSuggestReply, (-1...30).contains(messageAge) {
                if let reply {
                    signals.append((BriefingSignal(messageID: message.id, kind: .replySent, title: "A newer reply is cached", explanation: "A later Sent message in this account and conversation addresses this sender. Review the conversation to verify the request is resolved.", provenance: .mailState, sourceMessageID: reply.id), 10))
                } else {
                    signals.append((BriefingSignal(messageID: message.id, kind: .replyRequested, title: "Possible reply needed", explanation: "A direct line asks for a reply or confirmation, and the message is addressed to this account. This English text rule does not establish an obligation or check other mail clients.", provenance: .textRule, sourceQuote: quote), 70))
                }
            }
            if let deadline = BriefingTextRules.deadline(in: lines, messageDate: message.date, calendar: calendar) {
                let offset = deadline.date.flatMap { calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0).day }
                if let offset, (-7...7).contains(offset) {
                    let title = offset < 0 ? "Possible overdue deadline" : offset == 0 ? "Possible deadline today" : offset == 1 ? "Possible deadline tomorrow" : "Possible deadline this week"
                    let explanation = "A direct line contains deadline wording and a date. Relative dates are interpreted from this email's date in your calendar; verify the original before acting. Completion status is unknown."
                    signals.append((BriefingSignal(messageID: message.id, kind: .deadline, title: title, explanation: explanation, provenance: .textRule, sourceQuote: deadline.quote, dueDate: deadline.date), offset <= 2 ? 95 : 65))
                } else if offset == nil, (-1...7).contains(messageAge) {
                    signals.append((BriefingSignal(messageID: message.id, kind: .deadline, title: "Possible deadline to review", explanation: "The message mentions a deadline, but this local text rule cannot resolve a reliable date. Check the quoted source; no calendar event was created.", provenance: .textRule, sourceQuote: deadline.quote), 55))
                }
            }
            if let providerLabel, (-1...30).contains(messageAge) {
                let noAction = BriefingTextRules.noActionStatement(in: lines)
                var keptGeneratedAction = false
                for action in (actionGroups[message.id] ?? []).prefix(3) {
                    guard validQuote(action.sourceQuote, in: message.body), directText.contains(action.sourceQuote),
                          !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.title.count <= 500 else { continue }
                    // A known newer reply prevents a model's reply suggestion
                    // from resurfacing as a new obligation in the briefing.
                    if reply != nil, BriefingTextRules.replyRequest(in: [action.sourceQuote]) != nil { continue }
                    signals.append((BriefingSignal(messageID: message.id, kind: .actionSuggested, title: action.title,
                                                   explanation: "A retained \(providerLabel) action suggestion cites this direct message text. The quote is present; the interpretation still needs review. Nothing was executed.", provenance: .generated, provider: providerLabel, sourceQuote: action.sourceQuote), noAction == nil ? 60 : 25))
                    keptGeneratedAction = true
                }
                if let noAction, keptGeneratedAction {
                    let explanation = noAction.conditional
                        ? "The original makes 'no action required' conditional. Flora has not checked whether that condition holds. The model's suggestion remains available with this update, without treating it as a confirmed request."
                        : "The original explicitly says no action is required, and this local rule found no separate direct request. The generated suggestion remains available for review; it is not treated as a confirmed request."
                    signals.append((BriefingSignal(messageID: message.id, kind: .update, title: noAction.conditional ? "Conditional update" : "Informational update", explanation: explanation,
                                                   provenance: .textRule, sourceQuote: noAction.quote), 30))
                }
            }
            let summary = providerLabel.flatMap { label in
                (summaryGroups[message.id] ?? []).sorted { $0.generatedAt > $1.generatedAt }.first { summary in
                    Self.sameProvider(summary.provider, as: label) && summary.messageID == message.id && !summary.facts.isEmpty && summary.facts.count <= 5 &&
                    !summary.headline.isEmpty && summary.headline.count <= 1_200 && summary.facts.allSatisfy {
                        $0.sourceMessageID == message.id && $0.text.count <= 1_000 && validQuote($0.sourceQuote, in: message.body)
                    }
                }
            }
            if signals.allSatisfy({ $0.score < 50 }), BriefingTextRules.automatedSender(message.from.email) || BriefingTextRules.lowPriorityQuote(in: lines) != nil {
                signals.append((BriefingSignal(messageID: message.id, kind: .lowPriority, title: "Review later", explanation: "An automated sender name or subscription footer suggests this may be a routine update. This text rule can be wrong; the message remains in Inbox.", provenance: .textRule, sourceQuote: BriefingTextRules.lowPriorityQuote(in: lines)), 5))
            }
            if !message.isRead {
                signals.append((BriefingSignal(messageID: message.id, kind: .unread, title: "Unread update", explanation: "This message is unread in the cached mailbox. It has not been marked read by the briefing.", provenance: .mailState), 15))
            }
            if signals.isEmpty {
                signals.append((BriefingSignal(messageID: message.id, kind: .update, title: message.subject, explanation: "A cached Inbox update with no current attention cue from these rules. This is not a guarantee that no action is needed.", provenance: .mailState), 10))
            }
            signals.sort { $0.score == $1.score ? $0.signal.id < $1.signal.id : $0.score > $1.score }
            var uniqueSignalIDs: Set<String> = []
            signals = signals.filter { uniqueSignalIDs.insert($0.signal.id).inserted }
            let score = signals.first?.score ?? 10
            let low = score < 50 && signals.contains { $0.signal.kind == .lowPriority }
            let priority: BriefingPriority = score >= 95 ? .urgent : score >= 50 ? .attention : low ? .low : .normal
            ranked.append((BriefingItem(message: message, priority: priority, signals: signals.map(\.signal), summary: summary), score))
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.message.date != $1.item.message.date { return $0.item.message.date > $1.item.message.date }
            return $0.item.id.uuidString < $1.item.id.uuidString
        }
        return DailyBriefingSnapshot(scope: scope, generatedAt: now,
                                     needsAttention: ranked.filter { $0.item.priority == .attention || $0.item.priority == .urgent }.map(\.item),
                                     updates: ranked.filter { $0.item.priority == .normal }.map(\.item), lowPriority: ranked.filter { $0.item.priority == .low }.map(\.item),
                                     availableInboxCount: inbox.count, consideredMessageCount: considered.count)
    }
    private func newestReply(to message: MailMessage, account: MailAccount, candidates: [MailMessage]) -> MailMessage? {
        candidates.filter { candidate in
            candidate.accountID == message.accountID && candidate.date > message.date && equalAddress(candidate.from.email, account.address.email) &&
            (candidate.to + candidate.cc).contains { equalAddress($0.email, message.from.email) }
        }.max { $0.date < $1.date }
    }
    private func threadKey(_ message: MailMessage) -> String { "\(message.accountID):\(message.threadID)" }
    private func equalAddress(_ left: String, _ right: String) -> Bool { !left.isEmpty && left.caseInsensitiveCompare(right) == .orderedSame }
    private func validQuote(_ quote: String, in body: String) -> Bool { !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quote.count <= 2_000 && body.contains(quote) }
    private static func validProviderLabel(_ label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= 250, label == "Demo AI" || label == "Mock AI" || label.hasPrefix("Mock AI · ") || label == "Local AI" || label.hasPrefix("Local AI · ") else { return nil }
        return label
    }
    private static func sameProvider(_ actual: String, as requested: String) -> Bool {
        if requested == "Demo AI" || requested == "Mock AI" { return actual == "Mock AI" || actual.hasPrefix("Mock AI · ") }
        return actual == requested || actual.hasPrefix(requested + " · ")
    }
}
