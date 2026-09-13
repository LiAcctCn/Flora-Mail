import Foundation
import EventKit
import Contacts
import FloraCore

/// Store objects never leave these actors. Only bounded value types cross into
/// the app; neither adapter exposes a Calendar or Contacts mutation capability.
actor NativeCalendarContextProvider: CalendarContextProvider {
    private let store = EKEventStore()
    func authorizationStatus() -> ContextAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        case .fullAccess: .authorized
        @unknown default: .unavailable
        }
    }
    func requestReadAccess() async -> ContextAuthorizationStatus {
        // macOS has no read-only Calendar grant; full access is required to read.
        // Flora keeps its own interface strictly read-only despite the OS grant.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") as? String != nil else { return .unavailable }
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { allowed, _ in continuation.resume(returning: allowed) }
        }
        return granted ? authorizationStatus() : (authorizationStatus() == .notDetermined ? .unavailable : authorizationStatus())
    }
    func events(in interval: DateInterval, limit: Int) async throws -> CalendarEventsResult {
        try Task.checkCancellation()
        guard authorizationStatus().canRead else { throw PersonalContextError.permissionRequired }
        guard interval.duration > 0, interval.duration <= PersonalContextService.maximumWindow,
              limit > 0, limit <= PersonalContextService.maximumEvents else { throw PersonalContextError.invalidScope }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        var found: [CalendarEventContext] = [], complete = true
        store.enumerateEvents(matching: predicate) { event, stop in
            if Task.isCancelled { stop.pointee = true; complete = false; return }
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate,
                  end > interval.start, start < interval.end, end > start else { return }
            guard found.count < limit else { complete = false; stop.pointee = true; return }
            let availability: CalendarBusyStatus
            switch event.availability {
            case .free: availability = .free
            case .busy, .unavailable: availability = .busy
            case .tentative: availability = .tentative
            case .notSupported: availability = .unknown
            @unknown default: availability = .unknown
            }
            let identity = (event.eventIdentifier ?? event.calendarItemIdentifier) + "@" + String(start.timeIntervalSince1970)
            found.append(CalendarEventContext(id: identity, title: String((event.title ?? "Calendar event").prefix(200)), start: start, end: end, busyStatus: availability))
        }
        try Task.checkCancellation()
        guard authorizationStatus().canRead else { throw PersonalContextError.permissionRequired }
        return CalendarEventsResult(events: found.sorted { $0.start < $1.start }, isComplete: complete)
    }
}

actor NativeContactsContextProvider: ContactsContextProvider {
    private let store = CNContactStore()
    func authorizationStatus() -> ContextAuthorizationStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unavailable
        }
    }
    func requestReadAccess() async -> ContextAuthorizationStatus {
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") as? String != nil else { return .unavailable }
        let granted: Bool = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { allowed, _ in continuation.resume(returning: allowed) }
        }
        return granted ? authorizationStatus() : (authorizationStatus() == .notDetermined ? .unavailable : authorizationStatus())
    }
    func contacts(matchingEmail email: String, limit: Int) async throws -> [SenderContactContext] {
        try Task.checkCancellation()
        guard authorizationStatus().canRead else { throw PersonalContextError.permissionRequired }
        guard limit > 0, limit <= PersonalContextService.maximumContacts,
              (try? OutgoingMIMEComposer.addresses(email))?.count == 1 else { throw PersonalContextError.invalidScope }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor,
                                      CNContactFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        var matches: [SenderContactContext] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard contact.emailAddresses.contains(where: { String($0.value).caseInsensitiveCompare(email) == .orderedSame }) else { return }
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                matches.append(SenderContactContext(id: contact.identifier, displayName: name.isEmpty ? email : String(name.prefix(200)), matchedEmail: email,
                                                    organization: contact.organizationName.isEmpty ? nil : String(contact.organizationName.prefix(200))))
                if matches.count >= limit { stop.pointee = true }
            }
        } catch { throw PersonalContextError.unavailable }
        try Task.checkCancellation()
        guard authorizationStatus().canRead else { throw PersonalContextError.permissionRequired }
        return matches
    }
}
