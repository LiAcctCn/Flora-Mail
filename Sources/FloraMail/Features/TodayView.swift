import SwiftUI
import FloraCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    private var inbox: [MailMessage] { model.scopedMessages.filter { $0.folder == .inbox }.sorted { $0.date > $1.date } }
    private var attentionIDs: Set<UUID> { Set(model.attentionItems.map(\.messageID)) }
    private var attention: [MailMessage] { inbox.filter { $0.isFlagged || $0.isImportant || attentionIDs.contains($0.id) } }
    private var updates: [MailMessage] { inbox.filter { !$0.isFlagged && !$0.isImportant && !attentionIDs.contains($0.id) } }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning." : hour < 18 ? "Good afternoon." : "Good evening."
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionEyebrow(title: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        Text(greeting).font(.system(size: 34, weight: .medium, design: .serif))
                        Text("A clearer view of your day.").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(model.state.preferences.showDemoAccounts ? "Demo mailbox" : "Cached mail · Read-only", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 7).background(.quaternary.opacity(0.5), in: Capsule())
                }
                if !model.state.accounts.contains(where: { $0.providerType != .demo }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome to Flora Mail").font(.headline)
                            Text("Connect your mail account, or explore the fictional inbox in Demo Mode.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add Account") { model.showingAccountConnection = true }.buttonStyle(.borderedProminent)
                    }.padding(18).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 16) {
                    metric("Flagged emails", value: inbox.filter(\.isFlagged).count, icon: "flag", destination: .important)
                    metric("\(model.aiEnabled ? "Action suggestions" : "Unread emails")", value: model.aiEnabled ? attentionIDs.count : inbox.filter { !$0.isRead }.count, icon: "arrowshape.turn.up.left", destination: .folder(.inbox))
                    metric("In your inbox", value: inbox.count, icon: "tray", destination: .folder(.inbox))
                    metric("Saved drafts", value: model.visibleDrafts.count, icon: "doc", destination: model.state.preferences.showDemoAccounts ? .folder(.drafts) : .localDrafts)
                }
                HStack(spacing: 7) {
                    Image(systemName: model.aiEnabled ? "sparkles" : "hand.raised").foregroundStyle(Color.floraAccent)
                    Text(model.aiEnabled ? "\(model.aiLabel) · Generated suggestions link to cached mail. Every item links to its original." : "AI is off. Your mail, flags, categories, and composer are still available.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.state.preferences.showDemoAccounts && model.aiEnabled && model.briefingProgress == nil {
                    HStack {
                        Button("Generate Briefing") { Task { await model.refreshBriefing() } }
                        Text("Review up to 20 recent inbox messages with \(model.aiLabel).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let progress = model.briefingProgress {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelBriefing(userInitiated: true) }.controlSize(.small)
                    }
                }
                if let error = model.briefingError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.circle").font(.caption)
                        Spacer()
                        if model.state.preferences.aiMode == .local { SettingsLink { Text("Configure Local AI") } }
                        Button("Retry") { Task { await model.refreshBriefing() } }
                    }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Needs attention").font(.title2.weight(.semibold))
                        Text("\(attention.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Inbox") { model.navigate(.folder(.inbox)) }.buttonStyle(.link)
                    }
                    if attention.isEmpty { Text("Nothing flagged for your attention. You’re up to date.").foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(attention.prefix(5)) { message in
                        attentionRow(message)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Other updates").font(.title2.weight(.semibold))
                        Spacer()
                        Text("\(updates.count) messages").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(updates.prefix(4)) { message in
                        Button { model.openMessage(message.id) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.subject).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                                    Text(message.from.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(message.date, style: .date).font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Image(systemName: "leaf").foregroundStyle(Color.floraAccent)
                    Text("Your inbox stays yours. Flora suggests; you decide.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.top, 6)
            }.padding(36).frame(maxWidth: 1150, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear { model.cancelBriefing() }
        .task(id: "\(model.aiRequestIdentity)-\(inbox.map { "\($0.id):\($0.subject):\($0.body)" }.joined())") {
            if model.state.preferences.showDemoAccounts { await model.refreshBriefing() }
            else { model.cancelBriefing(); model.attentionItems = [] }
        }
    }
    private func metric(_ title: String, value: Int, icon: String, destination: MailDestination) -> some View {
        Button { model.navigate(destination) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Image(systemName: icon).foregroundStyle(Color.floraAccent); Spacer() }
                Text("\(value)").font(.system(size: 31, weight: .regular, design: .rounded)).foregroundStyle(.primary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.floraAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.floraAccent.opacity(0.1)))
        }.buttonStyle(.plain).accessibilityLabel("\(value) \(title)")
    }
    private func attentionRow(_ message: MailMessage) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(message.from.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.floraAccent)
                .frame(width: 36, height: 36).background(Color.floraAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message.from.name).font(.system(size: 12, weight: .semibold))
                    Text("·").foregroundStyle(.tertiary)
                    Text(message.subject).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let action = model.attentionItems.first(where: { $0.messageID == message.id }) {
                    Text(action.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text("\(model.aiLabel) suggestion · Verify in original email").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(message.preview).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    Label("Flagged message", systemImage: "flag.fill").font(.system(size: 10)).foregroundStyle(Color.floraAccent)
                }
            }
            Spacer(minLength: 12)
            VStack(spacing: 9) {
                Button("View") { model.openMessage(message.id) }.controlSize(.small)
                Button("Reply") { model.compose(replyTo: message) }.buttonStyle(.link).font(.caption)
            }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}
