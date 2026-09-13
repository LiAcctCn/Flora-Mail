import SwiftUI
import FloraCore

struct PersonalContextSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Section("Personal context") {
            LabeledContent("Calendar", value: model.personalContext.calendarAuthorization.title)
            LabeledContent("Contacts", value: model.personalContext.contactsAuthorization.title)
            HStack {
                Button("Allow Calendar Context") { Task { await model.personalContext.requestCalendarAccess() } }
                Button("Allow Contact Context") { Task { await model.personalContext.requestContactsAccess() } }
            }.disabled(model.personalContext.isRequestingAccess)
            Text("Optional macOS permissions. A reader check looks up only the selected sender and a reviewed meeting interval. Context is kept in memory and is never added to AI prompts. Flora does not create events or modify contacts.")
                .font(.caption).foregroundStyle(.secondary)
            Text("To revoke access, use System Settings → Privacy & Security → Calendars or Contacts.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.personalContext.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.task { await model.personalContext.refreshAuthorization() }
    }
}

struct PersonalContextView: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    @State private var start = Date().addingTimeInterval(3_600)
    @State private var duration = 30
    @State private var showTimeReview = false
    private var sourceIdentity: String {
        [message.id.uuidString, message.accountID.uuidString, message.subject, message.body, message.from.email, message.from.name, String(message.date.timeIntervalSince1970)].joined(separator: "\u{1F}")
    }
    private var context: PersonalMessageContext? {
        guard model.personalContext.context?.sourceMessageID == message.id,
              model.personalContext.context?.accountID == message.accountID else { return nil }
        return model.personalContext.context
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Personal context", systemImage: "calendar.badge.clock").font(.headline)
                Spacer()
                if model.personalContext.isLoading {
                    ProgressView().controlSize(.mini)
                    Button("Cancel") { model.personalContext.cancel() }.controlSize(.small)
                } else {
                    Button(context == nil ? "Check Context" : "Refresh Context") {
                        model.personalContext.inspect(message: message)
                    }.controlSize(.small)
                }
            }
            Text("Check this sender and a proposed time using local Contacts and Calendar. Access is optional.")
                .font(.caption).foregroundStyle(.secondary)
            if let context {
                ForEach(context.senderMatches) { contact in
                    Label(contact.displayName + (contact.organization.map { " · " + $0 } ?? ""), systemImage: "person.crop.circle")
                        .font(.callout)
                }
                if context.senderMatches.isEmpty {
                    Text(context.contactsAuthorization.canRead ? "No matching contact found." : "Contact context: \(context.contactsAuthorization.title)").font(.caption).foregroundStyle(.secondary)
                }
                if let meeting = context.meeting {
                    Text("Meeting mentioned · Tentative").font(.subheadline.weight(.medium))
                    Text("Source: “\(meeting.sourceQuote)”").font(.caption).textSelection(.enabled)
                    if let date = meeting.candidateStart {
                        Text("Unconfirmed time reference: \(formatted(date, zone: meeting.timeZoneIdentifier)) · \(meeting.timeZoneIdentifier)").font(.caption)
                    }
                    ForEach(meeting.ambiguities, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Text(context.availability.explanation).font(.callout)
                    ForEach(context.availability.conflictingEvents) { event in
                        Label("\(event.title) · \(event.start.formatted(date: .omitted, time: .shortened))", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption)
                    }
                    DisclosureGroup("Review a time to check", isExpanded: $showTimeReview) {
                        VStack(alignment: .leading, spacing: 10) {
                            DatePicker("Start", selection: $start)
                            Picker("Duration", selection: $duration) {
                                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                            }.frame(maxWidth: 280)
                            Text("Times use \(TimeZone.current.identifier). Confirm the sender’s intended time zone. A clear calendar does not confirm your availability.").font(.caption).foregroundStyle(.secondary)
                            Button("Check Chosen Time") {
                                model.personalContext.inspect(message: message, confirmedInterval: DateInterval(start: start, duration: Double(duration) * 60))
                            }.disabled(model.personalContext.isLoading)
                        }.padding(.top, 8)
                    }.font(.callout)
                    Button("Draft a Reply") { model.compose(replyTo: message) }.controlSize(.small)
                }
                ForEach(context.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if !context.calendarAuthorization.canRead || !context.contactsAuthorization.canRead {
                    SettingsLink { Text("Personal Context Settings") }.controlSize(.small)
                }
            }
            if let error = model.personalContext.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .onDisappear { model.personalContext.cancel() }
            .onChange(of: sourceIdentity) { _, _ in model.personalContext.cancel() }
    }
    private func formatted(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        return formatter.string(from: date)
    }
}
