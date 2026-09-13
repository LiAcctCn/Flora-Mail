import Foundation
import Testing
@testable import FloraCore

@Suite("Confirmed category preference learning")
struct CategoryPreferenceLearningTests {
    @Test func learningRequiresOptInAndTwoDistinctConfirmedMessages() throws {
        var fixture = CategoryLearningFixture()
        let first = fixture.addChoice(category: fixture.school.id)
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
        fixture.snapshot.history.append(ExecutedAction(proposal: ProposedAction(type: .classify(messageID: first, categoryID: fixture.school.id), explanation: "Repeated click"), date: fixture.clock))
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
        _ = fixture.addChoice(category: fixture.school.id)
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: false) == nil)
        let result = try #require(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true))
        #expect(result.classification.categoryID == fixture.school.id); #expect(result.supportCount == 2)
        #expect(Set(result.supportingMessageIDs).count == 2)
        #expect(result.explanation.contains("confirmed history"))
    }
    @Test func latestConflictingCorrectionSuspendsOldPatternUntilTwoNewChoicesAgree() throws {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id); _ = fixture.addChoice(category: fixture.school.id)
        _ = fixture.addChoice(category: fixture.work.id)
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
        _ = fixture.addChoice(category: fixture.work.id)
        let result = try #require(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true))
        #expect(result.classification.categoryID == fixture.work.id); #expect(result.supportCount == 2)
    }
    @Test func latestChoicePerMessagePreventsOldCategoryFromWinningByRepeatedHistory() throws {
        var fixture = CategoryLearningFixture()
        let first = fixture.addChoice(category: fixture.school.id); let second = fixture.addChoice(category: fixture.school.id)
        fixture.correct(first, category: fixture.work.id); fixture.correct(second, category: fixture.work.id)
        let result = try #require(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true))
        #expect(result.classification.categoryID == fixture.work.id)
        #expect(result.evidence.allSatisfy { $0.categoryID == fixture.work.id })
    }
    @Test func undoneCorrectionsDoNotTrainAndExplicitClearIsRespected() throws {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id); _ = fixture.addChoice(category: fixture.school.id)
        let changed = fixture.addChoice(category: fixture.work.id)
        fixture.snapshot.history[fixture.snapshot.history.count - 1].undone = true
        fixture.snapshot.messages.removeAll { $0.id == changed }
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true)?.classification.categoryID == fixture.school.id)
        fixture.correct(fixture.target.id, category: nil)
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
    }
    @Test func deletedCategoryIsNotRecreatedEvenWhenItsNameIsReused() throws {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id); _ = fixture.addChoice(category: fixture.school.id)
        let deletedID = fixture.school.id
        fixture.snapshot.categories.removeAll { $0.id == deletedID }
        fixture.snapshot.categories.append(MailCategory(name: fixture.school.name))
        let before = fixture.snapshot
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
        #expect(fixture.snapshot == before)
    }
    @Test func accountAndSenderIdentitySeparateDemoAndRealLearning() throws {
        var fixture = CategoryLearningFixture()
        let demo = MailAccount(name: "Fictional demo", address: fixture.account.address)
        fixture.snapshot.accounts.append(demo)
        _ = fixture.addChoice(category: fixture.school.id, accountID: demo.id)
        _ = fixture.addChoice(category: fixture.school.id, accountID: demo.id)
        _ = fixture.addChoice(category: fixture.school.id, sender: "someone-else@example.com")
        _ = fixture.addChoice(category: fixture.school.id, sender: "someone-else@example.com")
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
        _ = fixture.addChoice(category: fixture.work.id); _ = fixture.addChoice(category: fixture.work.id)
        let result = try #require(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true))
        #expect(result.evidence.allSatisfy { $0.accountID == fixture.account.id })
        #expect(result.classification.categoryID == fixture.work.id)
    }
    @Test func predictionsAndAutomationAreNotConfirmedUserEvidence() {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id, origin: .automation)
        _ = fixture.addChoice(category: fixture.school.id, origin: .automation)
        fixture.snapshot.classifications = [ClassificationSuggestion(messageID: fixture.target.id, categoryID: fixture.school.id, explanation: "Unaccepted prediction")]
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
    }
    @Test func acceptedSuggestionProvenanceAndPersistenceRemainReviewable() throws {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id, origin: .ai); _ = fixture.addChoice(category: fixture.school.id)
        let before = fixture.snapshot
        let result = try #require(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true))
        #expect(result.evidence.contains { $0.acceptedAISuggestion })
        #expect(result.supportingActionIDs.allSatisfy { id in fixture.snapshot.history.contains { $0.id == id } })
        let restored = try JSONDecoder().decode(AppSnapshot.self, from: JSONEncoder().encode(fixture.snapshot))
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: restored, enabled: true) == result)
        #expect(fixture.snapshot == before)
    }
    @Test func confirmedTargetAssignmentAlwaysWins() {
        var fixture = CategoryLearningFixture()
        _ = fixture.addChoice(category: fixture.school.id); _ = fixture.addChoice(category: fixture.school.id)
        fixture.target.categoryID = fixture.work.id
        #expect(CategoryPreferenceLearningService().suggestion(for: fixture.target, in: fixture.snapshot, enabled: true) == nil)
    }
}

private struct CategoryLearningFixture {
    let account = MailAccount(name: "Fictional real account", address: MailAddress(name: "Reader", email: "reader@example.com"), providerType: .gmail)
    let school = MailCategory(name: "School")
    let work = MailCategory(name: "Work")
    var clock = Date(timeIntervalSince1970: 1_789_344_000)
    var target: MailMessage
    var snapshot: AppSnapshot
    init() {
        target = MailMessage(accountID: account.id, from: MailAddress(name: "Sender", email: "sender@example.com"), to: [account.address], subject: "New fictional mail", body: "New content")
        snapshot = AppSnapshot(accounts: [account], messages: [target], categories: [school, work])
    }
    @discardableResult mutating func addChoice(category: UUID, accountID: UUID? = nil, sender: String = "sender@example.com", origin: ActionOrigin = .user) -> UUID {
        let message = MailMessage(accountID: accountID ?? account.id, from: MailAddress(name: "Sender", email: sender), to: [account.address], subject: "Confirmed fictional mail", body: "Fictional evidence", categoryID: category)
        snapshot.messages.append(message); clock += 60
        snapshot.history.append(ExecutedAction(proposal: ProposedAction(type: .classify(messageID: message.id, categoryID: category), explanation: "Confirmed local category", origin: origin), date: clock))
        return message.id
    }
    mutating func correct(_ id: UUID, category: UUID?) {
        if let index = snapshot.messages.firstIndex(where: { $0.id == id }) { snapshot.messages[index].categoryID = category }
        clock += 60
        snapshot.history.append(ExecutedAction(proposal: ProposedAction(type: .classify(messageID: id, categoryID: category), explanation: "User correction"), date: clock))
    }
}
