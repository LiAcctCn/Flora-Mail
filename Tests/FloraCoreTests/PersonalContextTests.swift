import Foundation
import XCTest
@testable import FloraCore

private actor FixtureCalendarContext: CalendarContextProvider {
    var status: ContextAuthorizationStatus
    var result: CalendarEventsResult
    var permissionRequests = 0
    var intervals: [DateInterval] = []
    var unavailable: Bool
    init(status: ContextAuthorizationStatus = .authorized, events: [CalendarEventContext] = [], complete: Bool = true, unavailable: Bool = false) {
        self.status = status; result = CalendarEventsResult(events: events, isComplete: complete); self.unavailable = unavailable
    }
    func authorizationStatus() -> ContextAuthorizationStatus { status }
    func requestReadAccess() -> ContextAuthorizationStatus { permissionRequests += 1; status = .authorized; return status }
    func events(in interval: DateInterval, limit: Int) throws -> CalendarEventsResult {
        intervals.append(interval)
        if unavailable { throw PersonalContextError.unavailable }
        return result
    }
}
private actor FixtureContactsContext: ContactsContextProvider {
    var status: ContextAuthorizationStatus
    var result: [SenderContactContext]
    var permissionRequests = 0
    var emails: [String] = []
    init(status: ContextAuthorizationStatus = .authorized, contacts: [SenderContactContext] = []) { self.status = status; result = contacts }
    func authorizationStatus() -> ContextAuthorizationStatus { status }
    func requestReadAccess() -> ContextAuthorizationStatus { permissionRequests += 1; status = .authorized; return status }
    func contacts(matchingEmail email: String, limit: Int) -> [SenderContactContext] { emails.append(email); return result }
}

final class PersonalContextTests: XCTestCase, @unchecked Sendable {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso) ?? .distantPast }
    private var now: Date { date("2026-01-01T10:00:00Z") }
    private func message(_ body: String = "Can we meet on 2026-01-03 at 3 pm UTC for 30 minutes?") -> MailMessage {
        MailMessage(accountID: UUID(), from: MailAddress(name: "Colleague", email: "sender@example.test"), to: [], subject: "Project meeting", body: body, date: now)
    }
    private var detector: MeetingDetector { MeetingDetector(timeZoneIdentifier: "UTC") }

    func testExplicitMeetingHasSourceLinkedBoundedWindow() throws {
        let source = message(), meeting = try XCTUnwrap(detector.detect(in: source, now: now))
        XCTAssertEqual(meeting.sourceMessageID, source.id); XCTAssertTrue(source.body.contains(meeting.sourceQuote))
        XCTAssertEqual(meeting.candidateStart, date("2026-01-03T15:00:00Z")); XCTAssertEqual(meeting.candidateEnd, date("2026-01-03T15:30:00Z"))
        XCTAssertTrue(meeting.canCheckCalendar); XCTAssertTrue(meeting.isTentative); XCTAssertTrue(meeting.ambiguities.isEmpty)
    }
    func testTomorrowUsesOriginalMessageDateAndMarksPastIntent() throws {
        let meeting = try XCTUnwrap(detector.detect(in: message("Can we meet tomorrow at 3 pm UTC for 30 minutes?"), now: date("2026-01-10T10:00:00Z")))
        XCTAssertEqual(meeting.candidateStart, date("2026-01-02T15:00:00Z")); XCTAssertFalse(meeting.canCheckCalendar)
        XCTAssertTrue(meeting.ambiguities.contains(where: { $0.contains("past") }))
    }
    func testMissingTimezoneDurationAlternativesAndInvalidDatesStayAmbiguous() throws {
        for text in ["Can we meet tomorrow at 3 pm?", "Meeting 2026-02-30 at 3 pm UTC for 30 minutes", "Meeting 2026-01-03 at 3 pm UTC or 2026-01-04 at 4 pm UTC for 30 minutes", "No meeting 2026-01-03 at 3 pm UTC for 30 minutes", "Meeting 2026-01-03 at 15:00 UTC+99:99 for 30 minutes", "Meeting 2026-01-03 at 15:00 UTC for 30 minutes or for 60 minutes"] {
            let result = try XCTUnwrap(detector.detect(in: message(text), now: now))
            XCTAssertFalse(result.canCheckCalendar, text); XCTAssertFalse(result.ambiguities.isEmpty)
        }
    }
    func testQuotedReplyDoesNotCreateANewMeetingSuggestion() {
        XCTAssertNil(detector.detect(in: message("Thanks for your notes.\n> Can we meet 2026-01-03 at 3 pm UTC for 30 minutes?"), now: now))
        XCTAssertNil(detector.detect(in: message("Thanks.\nOn Jan 1, Sender wrote:\nCan we meet 2026-01-03 at 3 pm UTC for 30 minutes?"), now: now))
    }
    func testExplicitUTCOffsetDoesNotBecomeASecondMeetingTime() throws {
        let result = try XCTUnwrap(detector.detect(in: message("Meeting 2026-01-03 at 15:00 UTC+02:00 for 30 minutes"), now: now))
        XCTAssertEqual(result.candidateStart, date("2026-01-03T13:00:00Z")); XCTAssertTrue(result.canCheckCalendar)
    }
    func testInspectNeverRequestsPermissionAndDeniedMeansUnknown() async throws {
        let calendar = FixtureCalendarContext(status: .notDetermined), contacts = FixtureContactsContext(status: .denied)
        let service = PersonalContextService(calendar: calendar, contacts: contacts, detector: detector)
        let context = try await service.inspect(message: message(), now: now)
        XCTAssertEqual(context.availability.status, .unknown); XCTAssertTrue(context.senderMatches.isEmpty)
        let calendarRequests = await calendar.permissionRequests, contactRequests = await contacts.permissionRequests
        let intervals = await calendar.intervals, emails = await contacts.emails
        XCTAssertEqual(calendarRequests, 0); XCTAssertEqual(contactRequests, 0); XCTAssertTrue(intervals.isEmpty); XCTAssertTrue(emails.isEmpty)
        let permitted = await service.requestCalendarAccess(); XCTAssertEqual(permitted, .authorized)
        let requestsAfterChoice = await calendar.permissionRequests; XCTAssertEqual(requestsAfterChoice, 1)
    }
    func testContextReadsOnlySenderAndRelevantIntervalAndRejectsUnrelatedMatches() async throws {
        let source = message()
        let calendar = FixtureCalendarContext()
        let contacts = FixtureContactsContext(contacts: [SenderContactContext(id: "person", displayName: "Known Sender", matchedEmail: source.from.email), SenderContactContext(id: "private", displayName: "Unrelated Person", matchedEmail: "unrelated@example.test")])
        let service = PersonalContextService(calendar: calendar, contacts: contacts, detector: detector)
        let context = try await service.inspect(message: source, now: now)
        let intervals = await calendar.intervals, emails = await contacts.emails
        XCTAssertEqual(emails, [source.from.email]); XCTAssertEqual(intervals, [DateInterval(start: date("2026-01-03T15:00:00Z"), end: date("2026-01-03T15:30:00Z"))])
        XCTAssertEqual(context.sourceMessageID, source.id); XCTAssertEqual(context.accountID, source.accountID)
        XCTAssertEqual(context.senderMatches.map(\.id), ["person"]); XCTAssertEqual(context.availability.status, .noConflicts)
        XCTAssertTrue(context.availability.explanation.contains("does not confirm"))
    }
    func testIncompleteCalendarDataCannotClaimNoConflicts() async throws {
        let calendar = FixtureCalendarContext(complete: false), contacts = FixtureContactsContext()
        let result = try await PersonalContextService(calendar: calendar, contacts: contacts, detector: detector).inspect(message: message(), now: now)
        XCTAssertEqual(result.availability.status, .unknown)
        XCTAssertTrue(result.availability.explanation.contains("part"))
    }
    func testFreeEventsAndUnrelatedWindowsDoNotBecomeConflicts() async throws {
        let start = date("2026-01-03T15:00:00Z"), end = date("2026-01-03T15:30:00Z")
        let calendar = FixtureCalendarContext(events: [CalendarEventContext(id: "free", title: "Available block", start: start, end: end, busyStatus: .free), CalendarEventContext(id: "unrelated", title: "Outside window", start: now, end: now.addingTimeInterval(1_000))])
        let result = try await PersonalContextService(calendar: calendar, contacts: FixtureContactsContext(), detector: detector).inspect(message: message(), now: now)
        XCTAssertEqual(result.availability.status, .noConflicts); XCTAssertTrue(result.availability.conflictingEvents.isEmpty)
    }
    func testUnknownEventStatusIsPotentialConflictNotCertainAvailability() async throws {
        let calendar = FixtureCalendarContext(events: [CalendarEventContext(id: "event", title: "Review", start: date("2026-01-03T15:10:00Z"), end: date("2026-01-03T16:00:00Z"), busyStatus: .unknown)])
        let result = try await PersonalContextService(calendar: calendar, contacts: FixtureContactsContext(), detector: detector).inspect(message: message(), now: now)
        XCTAssertEqual(result.availability.status, .conflicts); XCTAssertEqual(result.availability.conflictingEvents.count, 1)
    }
    func testExplicitChosenWindowAllowsUsefulCheckWhilePreservingSourceAmbiguity() async throws {
        let source = message("Can we meet tomorrow at 3 pm?"), calendar = FixtureCalendarContext()
        let interval = DateInterval(start: date("2026-01-02T15:00:00Z"), duration: 1_800)
        let result = try await PersonalContextService(calendar: calendar, contacts: FixtureContactsContext(), detector: detector).inspect(message: source, confirmedInterval: interval, now: now)
        XCTAssertFalse(result.meeting?.ambiguities.isEmpty ?? true); XCTAssertEqual(result.availability.status, .noConflicts)
        XCTAssertEqual(result.availability.checkedInterval, interval); XCTAssertTrue(result.availability.explanation.contains("your chosen"))
    }
    func testAmbiguousDatesNeverQueryCalendarWithoutUserChosenWindow() async throws {
        let calendar = FixtureCalendarContext()
        let result = try await PersonalContextService(calendar: calendar, contacts: FixtureContactsContext(), detector: detector).inspect(message: message("Can we meet tomorrow at 3 pm?"), now: now)
        let intervals = await calendar.intervals
        XCTAssertEqual(result.availability.status, .unknown); XCTAssertTrue(intervals.isEmpty)
    }
    func testChosenScopeBoundsRejectBeforeReadingAnyPersonalData() async throws {
        for interval in [DateInterval(start: now, duration: 9 * 3_600), DateInterval(start: now.addingTimeInterval(100 * 86_400), duration: 1_800), DateInterval(start: now.addingTimeInterval(-86_400), duration: 1_800)] {
            let calendar = FixtureCalendarContext(), contacts = FixtureContactsContext()
            do { _ = try await PersonalContextService(calendar: calendar, contacts: contacts, detector: detector).inspect(message: message(), confirmedInterval: interval, now: now); XCTFail("Excessive scope allowed") }
            catch { XCTAssertEqual(error as? PersonalContextError, .invalidScope) }
            let intervals = await calendar.intervals, emails = await contacts.emails
            XCTAssertTrue(intervals.isEmpty); XCTAssertTrue(emails.isEmpty)
        }
    }
    func testUnavailableCalendarPreservesSenderAndSourceWithoutClaimingAvailability() async throws {
        let source = message()
        let result = try await PersonalContextService(calendar: FixtureCalendarContext(unavailable: true), contacts: FixtureContactsContext(contacts: [SenderContactContext(id: "sender", displayName: "Sender", matchedEmail: source.from.email)]), detector: detector).inspect(message: source, now: now)
        XCTAssertEqual(result.availability.status, .unknown); XCTAssertEqual(result.senderMatches.count, 1); XCTAssertEqual(result.sourceMessageID, source.id)
    }
}
