import Foundation

/// Context is read on explicit inspection, stays in memory, and is never supplied
/// automatically to AI. There is no mailbox-wide, contacts-wide or calendar-wide query.
public struct PersonalContextService: Sendable {
    public static let maximumWindow: TimeInterval = 8 * 3_600
    public static let maximumEvents = 100
    public static let maximumContacts = 3
    private let calendar: any CalendarContextProvider
    private let contacts: any ContactsContextProvider
    private let detector: MeetingDetector
    public init(calendar: any CalendarContextProvider, contacts: any ContactsContextProvider, detector: MeetingDetector = MeetingDetector()) {
        self.calendar = calendar; self.contacts = contacts; self.detector = detector
    }
    public func calendarAuthorization() async -> ContextAuthorizationStatus { await calendar.authorizationStatus() }
    public func contactsAuthorization() async -> ContextAuthorizationStatus { await contacts.authorizationStatus() }
    public func requestCalendarAccess() async -> ContextAuthorizationStatus { await calendar.requestReadAccess() }
    public func requestContactsAccess() async -> ContextAuthorizationStatus { await contacts.requestReadAccess() }

    public func inspect(message: MailMessage, confirmedInterval: DateInterval? = nil, now: Date = Date()) async throws -> PersonalMessageContext {
        try Task.checkCancellation()
        if let confirmedInterval {
            guard confirmedInterval.duration > 0, confirmedInterval.duration <= Self.maximumWindow,
                  confirmedInterval.start >= now.addingTimeInterval(-60), confirmedInterval.end > now,
                  confirmedInterval.end <= now.addingTimeInterval(90 * 86_400) else { throw PersonalContextError.invalidScope }
        }
        async let calendarPermission = calendar.authorizationStatus()
        async let contactsPermission = contacts.authorizationStatus()
        let (calendarStatus, contactsStatus) = await (calendarPermission, contactsPermission)
        let meeting = detector.detect(in: message, now: now)
        var notices: [String] = [], matches: [SenderContactContext] = []
        if contactsStatus.canRead {
            if (try? OutgoingMIMEComposer.addresses(message.from.email))?.count == 1 {
                do {
                    let fetched = try await contacts.contacts(matchingEmail: message.from.email, limit: Self.maximumContacts)
                    matches = Array(fetched.filter { $0.matchedEmail.caseInsensitiveCompare(message.from.email) == .orderedSame }.prefix(Self.maximumContacts)).map {
                        SenderContactContext(id: String($0.id.prefix(500)), displayName: $0.displayName.isEmpty ? message.from.email : String($0.displayName.prefix(200)), matchedEmail: message.from.email, organization: $0.organization.map { String($0.prefix(200)) })
                    }
                    if matches.isEmpty { notices.append("No matching accessible contact was found for this sender.") }
                } catch is CancellationError { throw CancellationError() }
                catch { notices.append("The selected sender's contact information is unavailable.") }
            } else { notices.append("The sender address could not be matched to a contact.") }
        } else { notices.append("Contacts access is \(contactsStatus.title.lowercased()). No contacts were read.") }
        try Task.checkCancellation()
        var availability = CalendarAvailability(status: .unknown, explanation: "No precise meeting window was identified. Calendar availability is unknown.")
        if meeting != nil || confirmedInterval != nil {
            if confirmedInterval == nil && meeting?.canCheckCalendar != true { availability = CalendarAvailability(status: .unknown, explanation: "Confirm the proposed date, time zone and duration before checking conflicts.") }
            else if !calendarStatus.canRead { availability = CalendarAvailability(status: .unknown, explanation: "Calendar read access is \(calendarStatus.title.lowercased()). Availability is unknown.") }
            else if let start = confirmedInterval?.start ?? meeting?.candidateStart, let end = confirmedInterval?.end ?? meeting?.candidateEnd,
                    end > start, end.timeIntervalSince(start) <= Self.maximumWindow, end <= now.addingTimeInterval(90 * 86_400) {
                let interval = DateInterval(start: start, end: end)
                do {
                    let result = try await calendar.events(in: interval, limit: Self.maximumEvents)
                    try Task.checkCancellation()
                    let overlapping = Array(result.events.filter { $0.end > start && $0.start < end && $0.end > $0.start && $0.busyStatus != .free }.prefix(Self.maximumEvents)).map {
                        CalendarEventContext(id: String($0.id.prefix(500)), title: String($0.title.prefix(200)), start: $0.start, end: $0.end, busyStatus: $0.busyStatus)
                    }
                    if !result.isComplete || result.events.count > Self.maximumEvents {
                        availability = CalendarAvailability(status: .unknown, checkedInterval: interval, conflictingEvents: overlapping, explanation: "Only part of this calendar window was returned. Availability remains unknown.")
                    } else if !overlapping.isEmpty {
                        availability = CalendarAvailability(status: .conflicts, checkedInterval: interval, conflictingEvents: overlapping, explanation: "Potential conflicts exist in accessible calendars. Tentative or unknown event status also needs review.")
                    } else {
                        availability = CalendarAvailability(status: .noConflicts, checkedInterval: interval, explanation: "No conflicts found in accessible calendars for \(confirmedInterval == nil ? "the proposed" : "your chosen") window. This does not confirm the person's availability or acceptance.")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { availability = CalendarAvailability(status: .unknown, explanation: "Calendar information could not be read. Availability remains unknown.") }
            }
        }
        try Task.checkCancellation()
        return PersonalMessageContext(sourceMessageID: message.id, accountID: message.accountID, senderMatches: matches, meeting: meeting, availability: availability, calendarAuthorization: calendarStatus, contactsAuthorization: contactsStatus, notices: notices)
    }
}
