import Foundation

public enum ContextAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined, authorized, limited, denied, restricted, unavailable
    public var canRead: Bool { self == .authorized || self == .limited }
    public var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .authorized: "Read access allowed"
        case .limited: "Limited access"
        case .denied: "Access denied"
        case .restricted: "Access restricted"
        case .unavailable: "Unavailable"
        }
    }
}
public enum PersonalContextError: LocalizedError, Equatable, Sendable {
    case permissionRequired, unavailable, invalidScope
    public var errorDescription: String? {
        switch self {
        case .permissionRequired: "Personal context access is not allowed. You can choose access in Settings; mail remains usable."
        case .unavailable: "Personal context is unavailable. Mail remains usable."
        case .invalidScope: "This context request exceeds the selected sender or relevant time window."
        }
    }
}
public struct SenderContactContext: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let matchedEmail: String
    public let organization: String?
    public init(id: String, displayName: String, matchedEmail: String, organization: String? = nil) {
        self.id = id; self.displayName = displayName; self.matchedEmail = matchedEmail; self.organization = organization
    }
}
public enum CalendarBusyStatus: String, Equatable, Sendable { case busy, free, tentative, unknown }
public struct CalendarEventContext: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let busyStatus: CalendarBusyStatus
    public init(id: String, title: String, start: Date, end: Date, busyStatus: CalendarBusyStatus = .busy) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.busyStatus = busyStatus
    }
}
public struct CalendarEventsResult: Equatable, Sendable {
    public let events: [CalendarEventContext]
    public let isComplete: Bool
    public init(events: [CalendarEventContext], isComplete: Bool = true) { self.events = events; self.isComplete = isComplete }
}
public struct MeetingSuggestion: Identifiable, Equatable, Sendable {
    public var id: UUID { sourceMessageID }
    public let sourceMessageID: UUID
    public let sourceQuote: String
    public let candidateStart: Date?
    public let candidateEnd: Date?
    public let timeZoneIdentifier: String
    public let ambiguities: [String]
    public let explanation: String
    public let isTentative: Bool
    public var canCheckCalendar: Bool { candidateStart != nil && candidateEnd != nil && ambiguities.isEmpty }
    public init(sourceMessageID: UUID, sourceQuote: String, candidateStart: Date?, candidateEnd: Date?, timeZoneIdentifier: String, ambiguities: [String], explanation: String, isTentative: Bool = true) {
        self.sourceMessageID = sourceMessageID; self.sourceQuote = sourceQuote; self.candidateStart = candidateStart; self.candidateEnd = candidateEnd
        self.timeZoneIdentifier = timeZoneIdentifier; self.ambiguities = ambiguities; self.explanation = explanation; self.isTentative = isTentative
    }
}
public struct CalendarAvailability: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable { case unknown, noConflicts, conflicts }
    public let status: Status
    public let checkedInterval: DateInterval?
    public let conflictingEvents: [CalendarEventContext]
    public let explanation: String
    public init(status: Status, checkedInterval: DateInterval? = nil, conflictingEvents: [CalendarEventContext] = [], explanation: String) {
        self.status = status; self.checkedInterval = checkedInterval; self.conflictingEvents = conflictingEvents; self.explanation = explanation
    }
}
public struct PersonalMessageContext: Equatable, Sendable {
    public let sourceMessageID: UUID
    public let accountID: UUID
    public let senderMatches: [SenderContactContext]
    public let meeting: MeetingSuggestion?
    public let availability: CalendarAvailability
    public let calendarAuthorization: ContextAuthorizationStatus
    public let contactsAuthorization: ContextAuthorizationStatus
    public let notices: [String]
    public init(sourceMessageID: UUID, accountID: UUID, senderMatches: [SenderContactContext], meeting: MeetingSuggestion?, availability: CalendarAvailability, calendarAuthorization: ContextAuthorizationStatus, contactsAuthorization: ContextAuthorizationStatus, notices: [String] = []) {
        self.sourceMessageID = sourceMessageID; self.accountID = accountID; self.senderMatches = senderMatches; self.meeting = meeting; self.availability = availability
        self.calendarAuthorization = calendarAuthorization; self.contactsAuthorization = contactsAuthorization; self.notices = notices
    }
}

/// Read-only protocols intentionally contain no event/contact save or delete API.
/// Permission requests are separate entry points and must be explicitly chosen.
public protocol CalendarContextProvider: Sendable {
    func authorizationStatus() async -> ContextAuthorizationStatus
    func requestReadAccess() async -> ContextAuthorizationStatus
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarEventsResult
}
public protocol ContactsContextProvider: Sendable {
    func authorizationStatus() async -> ContextAuthorizationStatus
    func requestReadAccess() async -> ContextAuthorizationStatus
    func contacts(matchingEmail email: String, limit: Int) async throws -> [SenderContactContext]
}
