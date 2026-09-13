import Foundation
import Observation
import FloraCore

/// UI owns when to inspect a selected message. Merely opening mail or Settings
/// never requests OS permissions; each access method is an explicit button action.
@MainActor @Observable
final class PersonalContextController {
    private(set) var context: PersonalMessageContext?
    private(set) var calendarAuthorization: ContextAuthorizationStatus = .notDetermined
    private(set) var contactsAuthorization: ContextAuthorizationStatus = .notDetermined
    private(set) var isLoading = false
    private(set) var isRequestingAccess = false
    private(set) var errorMessage: String?
    private let service: PersonalContextService
    private var task: Task<Void, Never>?
    private var revision = UUID()

    init(service: PersonalContextService = PersonalContextService(calendar: NativeCalendarContextProvider(), contacts: NativeContactsContextProvider())) { self.service = service }
    func refreshAuthorization() async {
        calendarAuthorization = await service.calendarAuthorization()
        contactsAuthorization = await service.contactsAuthorization()
    }
    func requestCalendarAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true; defer { isRequestingAccess = false }
        calendarAuthorization = await service.requestCalendarAccess()
    }
    func requestContactsAccess() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true; defer { isRequestingAccess = false }
        contactsAuthorization = await service.requestContactsAccess()
    }
    /// Starts its own cancellable task; call directly from an explicit Reader button.
    func inspect(message: MailMessage, confirmedInterval: DateInterval? = nil, now: Date = Date()) {
        cancel(); let request = UUID(); revision = request; isLoading = true
        task = Task { [weak self, service] in
            do {
                let result = try await service.inspect(message: message, confirmedInterval: confirmedInterval, now: now)
                try Task.checkCancellation()
                guard let self, self.revision == request else { return }
                self.context = result; self.calendarAuthorization = result.calendarAuthorization; self.contactsAuthorization = result.contactsAuthorization
                self.isLoading = false; self.task = nil
            } catch {
                guard let self, self.revision == request else { return }
                self.isLoading = false; self.task = nil
                if !(error is CancellationError) { self.errorMessage = "Personal context is unavailable. Your mail remains usable." }
            }
        }
    }
    func cancel() {
        revision = UUID(); task?.cancel(); task = nil; isLoading = false; context = nil; errorMessage = nil
    }
}
