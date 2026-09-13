import CryptoKit
import Foundation

public enum AutomationPolicy {
    public static func validateScope(_ rule: AutomationRule, state: AppSnapshot) throws {
        guard let accountID = rule.accountID, state.accounts.contains(where: { $0.id == accountID }),
              (1...36_500).contains(rule.olderThanDays), (1...50).contains(rule.maxMessages),
              !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.count <= 100,
              !rule.senderEmail.contains("*"), !rule.senderEmail.contains("?"),
              let addresses = try? OutgoingMIMEComposer.addresses(rule.senderEmail), addresses.count == 1,
              addresses[0].email.caseInsensitiveCompare(rule.senderEmail.trimmingCharacters(in: .whitespaces)) == .orderedSame else { throw AutomationError.invalidScope }
    }
    public static func matches(_ message: MailMessage, rule: AutomationRule, now: Date) -> Bool {
        message.accountID == rule.accountID && message.folder == .inbox && message.date < now.addingTimeInterval(-Double(rule.olderThanDays) * 86_400)
        && message.from.email.caseInsensitiveCompare(rule.senderEmail.trimmingCharacters(in: .whitespaces)) == .orderedSame
        && (rule.action != .markRead || !message.isRead)
    }
    static func matchingMessages(_ rule: AutomationRule, state: AppSnapshot, now: Date) -> [MailMessage] {
        state.messages.filter { matches($0, rule: rule, now: now) }.sorted {
            if $0.date == $1.date { return $0.id.uuidString < $1.id.uuidString }; return $0.date < $1.date
        }
    }
    static func messageFingerprint(_ message: MailMessage) throws -> String { try digest(message) }
    static func ruleFingerprint(_ rule: AutomationRule) throws -> String { try digest(rule) }
    static func previewFingerprint(_ rule: AutomationRule, messages: [MailMessage]) throws -> String {
        struct Source: Encodable {
            let id: UUID; let accountID: UUID; let providerID: String; let date: Date; let sender: String; let folder: MailFolder; let isRead: Bool; let isFlagged: Bool; let contentFingerprint: String
            init(_ message: MailMessage) throws { contentFingerprint = try AutomationPolicy.digest(message); id = message.id; accountID = message.accountID; providerID = message.providerID; date = message.date; sender = message.from.email; folder = message.folder; isRead = message.isRead; isFlagged = message.isFlagged }
        }
        struct Payload: Encodable { let rule: AutomationRule; let sources: [Source] }
        return try digest(Payload(rule: rule, sources: try messages.map(Source.init)))
    }
    static func validatePreview(_ preview: AutomationPreview, state: AppSnapshot, now: Date) throws {
        try validateScope(preview.rule, state: state)
        let current = matchingMessages(preview.rule, state: state, now: now)
        guard preview.accountID == preview.rule.accountID,
              preview.messageIDs == Array(current.prefix(preview.rule.maxMessages)).map(\.id), preview.totalMatchingCount == current.count,
              try previewFingerprint(preview.rule, messages: current) == preview.sourceFingerprint else { throw AutomationError.stalePreview }
    }
    static func validateReusableRule(_ rule: AutomationRule, state: AppSnapshot, now: Date) throws {
        try validateScope(rule, state: state)
        guard state.preferences.automationLevel == .rules else { throw AutomationError.levelNotAllowed }
        guard rule.enabled, !rule.delegationOnly, let authorized = rule.authorizedAt, authorized <= now else { throw AutomationError.ruleUnavailable }
        guard let expiry = rule.expiresAt, expiry > now else { throw AutomationError.expired }
    }
    static func validateRun(_ run: AutomationRunRecord, state: AppSnapshot, now: Date) throws -> AutomationRule {
        guard run.status == .running, let rule = state.rules.first(where: { $0.id == run.ruleID }) else { throw AutomationError.ruleUnavailable }
        try validateScope(rule, state: state)
        guard try ruleFingerprint(rule) == run.ruleFingerprint else { throw AutomationError.stalePreview }
        if let id = run.grantID {
            guard rule.enabled, let authorized = rule.authorizedAt, authorized <= now else { throw AutomationError.ruleUnavailable }
            guard let deadline = rule.expiresAt, deadline > now else { throw AutomationError.expired }
            guard state.preferences.automationLevel >= .delegated else { throw AutomationError.levelNotAllowed }
            guard let grant = state.automationGrants.first(where: { $0.id == id }), grant.revokedAt == nil,
                  grant.consumedByRunID == run.id, grant.accountID == run.accountID, grant.messageIDs == run.messageIDs,
                  grant.ruleFingerprint == run.ruleFingerprint, !grant.messageIDs.isEmpty, grant.messageIDs.count <= 10,
                  grant.authorizedAt <= now, grant.expiresAt <= grant.authorizedAt.addingTimeInterval(3_600), grant.expiresAt <= deadline else { throw AutomationError.delegationConsumed }
            guard grant.expiresAt > now else { throw AutomationError.expired }
        } else { try validateReusableRule(rule, state: state, now: now) }
        return rule
    }
    static func validateDispatch(_ dispatch: AuthorizedAutomationDispatch, state: AppSnapshot, now: Date) throws {
        guard let run = state.automationRuns.first(where: { $0.id == dispatch.runID }),
              run.activeDispatchID == dispatch.id, run.activeMessageID == dispatch.messageID,
              run.ruleID == dispatch.ruleID, run.grantID == dispatch.grantID, run.accountID == dispatch.accountID,
              run.messageIDs.contains(dispatch.messageID), !run.completedMessageIDs.contains(dispatch.messageID),
              !state.remoteActionHistory.contains(where: { $0.id == dispatch.id }),
              !state.history.contains(where: { $0.proposal.id == dispatch.id }) else { throw AutomationError.ruleUnavailable }
        let rule = try validateRun(run, state: state, now: now)
        guard rule.action == dispatch.action, let message = state.messages.first(where: { $0.id == dispatch.messageID }), matches(message, rule: rule, now: now),
              run.messageFingerprints[message.id.uuidString] == (try messageFingerprint(message)) else { throw AutomationError.invalidScope }
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
