import Foundation
import Testing
@testable import FloraCore

@Suite("Source-linked local priority briefing")
struct PriorityBriefingTests {
    @Test func scopesSeparateDemoAndRealAndExcludeNonInboxAttention() {
        let fixture = BriefingFixture()
        let real = fixture.message(body: "Please reply with your availability.")
        var demo = fixture.message(body: "Please reply with your availability."); demo.accountID = fixture.demo.id
        var archived = fixture.message(body: "Please reply now."); archived.folder = .archive; archived.isFlagged = true
        var trash = fixture.message(body: "Deadline today."); trash.folder = .trash; trash.isImportant = true
        let state = fixture.snapshot([real, demo, archived, trash])
        let realResult = fixture.build(state, scope: .realAccounts)
        #expect(realResult.availableInboxCount == 1)
        #expect(realResult.needsAttention.map(\.messageID) == [real.id])
        let demoResult = fixture.build(state, scope: .demo)
        #expect(demoResult.availableInboxCount == 1)
        #expect((demoResult.needsAttention + demoResult.updates).allSatisfy { $0.accountID == fixture.demo.id })
        #expect(fixture.build(state, scope: .account(UUID())).consideredMessageCount == 0)
    }
    @Test func flagsAndImportantRemainAuthoritativeMailStateWithoutMutation() throws {
        let fixture = BriefingFixture(); var mail = fixture.message(body: "An ordinary fictional update.")
        mail.isFlagged = true; mail.isImportant = true
        let state = fixture.snapshot([mail]); let result = fixture.build(state)
        let item = try #require(result.needsAttention.first)
        #expect(item.signals.contains { $0.kind == .flagged && $0.provenance == .mailState })
        #expect(item.signals.contains { $0.kind == .important && $0.provenance == .mailState })
        #expect(item.message == mail); #expect(state.messages == [mail])
    }
    @Test func explicitDeadlinesAreQuotedRulesAndRelativeDatesAnchorToMessageDate() throws {
        let fixture = BriefingFixture()
        let mail = fixture.message(body: "Please review the proposal.\nThe deadline is 2026-09-15.")
        let result = fixture.build(fixture.snapshot([mail])); let item = try #require(result.needsAttention.first)
        let signal = try #require(item.signals.first { $0.kind == .deadline })
        #expect(signal.title == "Possible deadline tomorrow")
        #expect(signal.provenance == .textRule); #expect(signal.sourceQuote == "The deadline is 2026-09-15.")
        #expect(signal.dueDate == fixture.date(2026, 9, 15)); #expect(result.deadlineCount == 1)
        let old = fixture.message(body: "The deadline is tomorrow.", date: fixture.date(2026, 8, 20))
        #expect(fixture.build(fixture.snapshot([old])).needsAttention.isEmpty)
    }
    @Test func ambiguousAndInvalidDatesRemainUnresolved() throws {
        let fixture = BriefingFixture()
        for text in ["The deadline is next Friday.", "The deadline is 2026-02-31.", "The deadline moved from 2026-09-14 to 2026-09-18."] {
            let mail = fixture.message(body: text)
            let item = try #require(fixture.build(fixture.snapshot([mail])).needsAttention.first)
            let signal = try #require(item.signals.first { $0.kind == .deadline })
            #expect(signal.dueDate == nil); #expect(signal.title == "Possible deadline to review")
        }
    }
    @Test func cachedReplySuppressesReplyCueOnlyInSameAccountAndConversation() {
        let fixture = BriefingFixture()
        let mail = fixture.message(body: "Please reply with your availability.")
        var sent = fixture.message(body: "My reply.", date: fixture.now.addingTimeInterval(60))
        sent.folder = .sent; sent.threadID = mail.threadID; sent.from = fixture.account.address; sent.to = [mail.from]
        let answered = fixture.build(fixture.snapshot([mail, sent]))
        #expect(answered.replyNeededCount == 0)
        #expect(answered.updates.first?.signals.contains { $0.kind == .replySent && $0.sourceMessageID == sent.id } == true)
        sent.accountID = fixture.demo.id
        #expect(fixture.build(fixture.snapshot([mail, sent])).replyNeededCount == 1)
    }
    @Test func quotedRepliesSignaturesAndNoReplyInstructionsDoNotCreateReplyObligations() {
        let fixture = BriefingFixture()
        let messages = [
            fixture.message(body: "Thanks for the update.\n> Please reply with your availability."),
            fixture.message(body: "Already handled.\nOn Monday, Sender wrote:\nPlease reply with your availability."),
            fixture.message(body: "An update.\n--\nPlease confirm your appointment."),
            fixture.message(body: "Do not reply. Please confirm your account using the website.")
        ]
        #expect(fixture.build(fixture.snapshot(messages)).replyNeededCount == 0)
    }
    @Test func copiedRecipientsAndAutomatedSendersAreNotAssumedToNeedReplies() {
        let fixture = BriefingFixture()
        var copied = fixture.message(body: "Please reply with your availability.")
        copied.cc = copied.to; copied.to = [MailAddress(name: "Other", email: "other@example.com")]
        var automated = fixture.message(body: "Please confirm your subscription."); automated.from.email = "no-reply@example.com"
        #expect(fixture.build(fixture.snapshot([copied, automated])).replyNeededCount == 0)
    }
    @Test func aiActionEvidenceMustRemainInTheExactCurrentDirectMessage() throws {
        let fixture = BriefingFixture(); let mail = fixture.message(body: "Review the attached document.")
        let valid = ActionItem(messageID: mail.id, title: "Document review suggested", sourceQuote: mail.body)
        let bad = ActionItem(messageID: mail.id, title: "Invented payment", sourceQuote: "Please pay 500 dollars.")
        let foreign = ActionItem(messageID: UUID(), title: "Other account request", sourceQuote: mail.body)
        let result = fixture.build(fixture.snapshot([mail]), actions: [valid, bad, foreign], label: "Local AI · fictional-model")
        let item = try #require(result.needsAttention.first)
        let generated = item.signals.filter { $0.provenance == .generated }
        #expect(generated.count == 1); #expect(generated.first?.provider == "Local AI · fictional-model")
        #expect(item.message.subject == mail.subject); #expect(item.message.from == mail.from)
        #expect(fixture.build(fixture.snapshot([mail]), actions: [valid], label: nil).needsAttention.isEmpty)
        var changed = mail; changed.body = "Updated content with no prior request."
        #expect(fixture.build(fixture.snapshot([changed]), actions: [valid], label: "Local AI · fictional-model").needsAttention.isEmpty)
    }
    @Test func retainedSummaryRequiresCurrentQuotesAndMatchingProviderModel() throws {
        let fixture = BriefingFixture(); let mail = fixture.message(body: "The project is on schedule.")
        let fact = ExtractedFact(text: "The project is on schedule.", sourceMessageID: mail.id, sourceQuote: mail.body)
        var state = fixture.snapshot([mail])
        state.summaries = [MessageSummary(messageID: mail.id, headline: "Generated overview", facts: [fact], provider: "Mock AI · extractive demo")]
        #expect(fixture.build(state, label: "Local AI · model-a").updates.first?.summary == nil)
        state.summaries[0].provider = "Local AI · model-b"
        #expect(fixture.build(state, label: "Local AI · model-a").updates.first?.summary == nil)
        state.summaries[0].provider = "Local AI · model-a · First 12,000 body characters only"
        #expect(fixture.build(state, label: "Local AI · model-a").updates.first?.summary?.provider == state.summaries[0].provider)
        state.summaries[0].facts[0].sourceMessageID = UUID()
        #expect(fixture.build(state, label: "Local AI · model-a").updates.first?.summary == nil)
    }
    @Test func generatedSignalsHaveStableUniqueIDsEvenWhenEvidenceQuotesRepeat() throws {
        let fixture = BriefingFixture(); let mail = fixture.message(body: "Review the document and prepare comments.")
        let actions = [ActionItem(messageID: mail.id, title: "Review document", sourceQuote: mail.body),
                       ActionItem(messageID: mail.id, title: "Prepare comments", sourceQuote: mail.body),
                       ActionItem(messageID: mail.id, title: "Review document", sourceQuote: mail.body)]
        let first = fixture.build(fixture.snapshot([mail]), actions: actions, label: "Local AI · fixture")
        let second = fixture.build(fixture.snapshot([mail]), actions: actions, label: "Local AI · fixture")
        let signals = try #require(first.needsAttention.first).signals.filter { $0.provenance == .generated }
        #expect(signals.count == 2); #expect(Set(signals.map(\.id)).count == 2); #expect(first == second)
    }
    @Test func conditionalNoActionStatementKeepsModelSuggestionAsAnUnverifiedUpdate() throws {
        let fixture = BriefingFixture()
        let quote = "No action is required if your payment details are up to date."
        let mail = fixture.message(body: "Your automatic payment is scheduled for Friday.\n" + quote)
        let action = ActionItem(messageID: mail.id, title: "Check automatic payment schedule", sourceQuote: quote)
        let result = fixture.build(fixture.snapshot([mail]), actions: [action], label: "Local AI · fixture")
        #expect(result.needsAttention.isEmpty)
        let item = try #require(result.updates.first)
        #expect(item.headline == "Conditional update")
        #expect(item.signals.contains { $0.provenance == .generated && $0.title == action.title })
        #expect(item.signals.contains { $0.provenance == .textRule && $0.sourceQuote == quote && $0.explanation.contains("has not checked") })
    }
    @Test func noActionCueDoesNotOverrideFlagsOrASeparateExplicitRequest() throws {
        let fixture = BriefingFixture()
        let quote = "No action is required if your payment details are up to date."
        var flagged = fixture.message(body: quote); flagged.isFlagged = true
        let flaggedAction = ActionItem(messageID: flagged.id, title: "Check details", sourceQuote: quote)
        #expect(fixture.build(fixture.snapshot([flagged]), actions: [flaggedAction], label: "Local AI · fixture").needsAttention.first?.messageID == flagged.id)
        let request = "Please review the separate attached document."
        let mail = fixture.message(body: quote + "\n" + request)
        let action = ActionItem(messageID: mail.id, title: "Review document", sourceQuote: request)
        let result = fixture.build(fixture.snapshot([mail]), actions: [action], label: "Local AI · fixture")
        #expect(result.needsAttention.first?.messageID == mail.id)
        #expect(result.needsAttention.first?.signals.contains { $0.title == "Conditional update" } == false)
    }
    @Test func unconditionalNoActionStatementDoesNotMatchNegatedOrQuotedText() throws {
        let fixture = BriefingFixture()
        let informational = fixture.message(body: "The report is ready.\nNo action is required.")
        let suggestion = ActionItem(messageID: informational.id, title: "Read the report", sourceQuote: "The report is ready.")
        #expect(fixture.build(fixture.snapshot([informational]), actions: [suggestion], label: "Local AI · fixture").needsAttention.isEmpty)
        let text = "It is not true that no action is required. Review this problem."
        let mail = fixture.message(body: text)
        let action = ActionItem(messageID: mail.id, title: "Review problem", sourceQuote: text)
        #expect(fixture.build(fixture.snapshot([mail]), actions: [action], label: "Local AI · fixture").needsAttention.count == 1)
    }
    @Test func routineMailIsLabeledAsATextRuleAndNeverMoved() throws {
        let fixture = BriefingFixture(); let mail = fixture.message(body: "Weekly newsletter. You can unsubscribe at any time.")
        let state = fixture.snapshot([mail]); let result = fixture.build(state)
        let item = try #require(result.lowPriority.first)
        #expect(item.signals.contains { $0.kind == .lowPriority && $0.provenance == .textRule })
        #expect(item.message.folder == .inbox); #expect(state.messages == [mail])
    }
    @Test func dashboardBoundsAreVisibleAndOrderingIsDeterministic() {
        let fixture = BriefingFixture()
        var messages = (0..<5).map { fixture.message(body: "Fictional update \($0)", date: fixture.now.addingTimeInterval(Double(-$0 * 60))) }
        messages[4].isFlagged = true
        let state = fixture.snapshot(messages)
        let first = PriorityBriefingService().build(snapshot: state, scope: .realAccounts, now: fixture.now, calendar: fixture.calendar, limit: 2)
        let second = PriorityBriefingService().build(snapshot: state, scope: .realAccounts, now: fixture.now, calendar: fixture.calendar, limit: 2)
        #expect(first == second); #expect(first.isTruncated); #expect(first.consideredMessageCount == 2); #expect(first.availableInboxCount == 5)
        #expect(first.needsAttention.first?.messageID == messages[4].id)
    }
}

private struct BriefingFixture {
    let account = MailAccount(name: "Fictional real account", address: MailAddress(name: "Reader", email: "reader@example.com"), providerType: .gmail)
    let demo = MailAccount(name: "Fictional Demo", address: MailAddress(name: "Demo reader", email: "demo@example.com"))
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0) ?? .current; value.locale = Locale(identifier: "en_US_POSIX"); return value
    }
    var now: Date { date(2026, 9, 14) }
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast }
    func message(body: String, date: Date? = nil) -> MailMessage {
        MailMessage(accountID: account.id, from: MailAddress(name: "Sender", email: "sender@example.com"), to: [account.address], subject: "Fictional original subject", body: body, date: date ?? now)
    }
    func snapshot(_ messages: [MailMessage]) -> AppSnapshot { AppSnapshot(accounts: [account, demo], messages: messages) }
    func build(_ snapshot: AppSnapshot, scope: MailIntelligenceScope = .realAccounts, actions: [ActionItem] = [], label: String? = nil) -> DailyBriefingSnapshot {
        PriorityBriefingService().build(snapshot: snapshot, scope: scope, actions: actions, aiProviderLabel: label, now: now, calendar: calendar)
    }
}
