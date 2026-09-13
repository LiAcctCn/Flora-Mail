import Foundation
import XCTest
import FloraCore
@testable import FloraMail

private actor ControllerCalendarFixture: CalendarContextProvider {
    var permissions = 0
    var reads = 0
    var status = ContextAuthorizationStatus.notDetermined
    func authorizationStatus() -> ContextAuthorizationStatus { status }
    func requestReadAccess() -> ContextAuthorizationStatus { permissions += 1; status = .authorized; return status }
    func events(in interval: DateInterval, limit: Int) -> CalendarEventsResult { reads += 1; return CalendarEventsResult(events: []) }
}
private actor ControllerContactsFixture: ContactsContextProvider {
    var permissions = 0
    var reads: [String] = []
    private var status = ContextAuthorizationStatus.authorized
    private var entered = false
    private var enteringWaiter: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    let gatedEmail: String?
    init(gatedEmail: String? = nil) { self.gatedEmail = gatedEmail }
    func authorizationStatus() -> ContextAuthorizationStatus { status }
    func requestReadAccess() -> ContextAuthorizationStatus { permissions += 1; status = .authorized; return status }
    func contacts(matchingEmail email: String, limit: Int) async -> [SenderContactContext] {
        reads.append(email)
        if email == gatedEmail {
            entered = true; enteringWaiter?.resume(); enteringWaiter = nil
            await withCheckedContinuation { blocked = $0 }
        }
        return [SenderContactContext(id: email, displayName: "Selected Sender", matchedEmail: email)]
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteringWaiter = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

@MainActor
final class PersonalContextControllerTests: XCTestCase {
    private func message(email: String) -> MailMessage {
        MailMessage(accountID: UUID(), from: MailAddress(name: "Sender", email: email), to: [], subject: "Notes", body: "Please review the notes.")
    }
    private func waitUntilFinished(_ controller: PersonalContextController) async throws {
        for _ in 0..<200 {
            if !controller.isLoading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Context task did not finish within one second")
    }
    func testConstructionAndStatusRefreshNeverPromptOrReadPersonalData() async {
        let calendar = ControllerCalendarFixture(), contacts = ControllerContactsFixture()
        let controller = PersonalContextController(service: PersonalContextService(calendar: calendar, contacts: contacts))
        await controller.refreshAuthorization()
        let calendarPermissions = await calendar.permissions, contactPermissions = await contacts.permissions
        let calendarReads = await calendar.reads, contactReads = await contacts.reads
        XCTAssertEqual(calendarPermissions, 0); XCTAssertEqual(contactPermissions, 0)
        XCTAssertEqual(calendarReads, 0); XCTAssertTrue(contactReads.isEmpty); XCTAssertNil(controller.context)
        await controller.requestCalendarAccess()
        await controller.requestContactsAccess()
        let requestedCalendar = await calendar.permissions, requestedContacts = await contacts.permissions
        XCTAssertEqual(requestedCalendar, 1); XCTAssertEqual(requestedContacts, 1)
        XCTAssertEqual(controller.calendarAuthorization, .authorized); XCTAssertFalse(controller.isRequestingAccess)
    }
    func testChangingSelectionRejectsLateContextFromPreviousAccount() async throws {
        let first = message(email: "first@example.test"), second = message(email: "second@example.test")
        let contacts = ControllerContactsFixture(gatedEmail: first.from.email)
        let controller = PersonalContextController(service: PersonalContextService(calendar: ControllerCalendarFixture(), contacts: contacts))
        controller.inspect(message: first)
        await contacts.waitUntilEntered()
        controller.inspect(message: second)
        try await waitUntilFinished(controller)
        XCTAssertEqual(controller.context?.sourceMessageID, second.id); XCTAssertEqual(controller.context?.accountID, second.accountID)
        await contacts.release()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(controller.context?.sourceMessageID, second.id); XCTAssertEqual(controller.context?.senderMatches.first?.matchedEmail, second.from.email)
    }
    func testCancelClearsContextAndDiscardedRequestCannotRestoreIt() async throws {
        let first = message(email: "first@example.test")
        let contacts = ControllerContactsFixture(gatedEmail: first.from.email)
        let controller = PersonalContextController(service: PersonalContextService(calendar: ControllerCalendarFixture(), contacts: contacts))
        controller.inspect(message: first)
        await contacts.waitUntilEntered()
        controller.cancel()
        await contacts.release()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(controller.context); XCTAssertFalse(controller.isLoading); XCTAssertNil(controller.errorMessage)
    }
}
