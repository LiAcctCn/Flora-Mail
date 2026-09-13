import SwiftUI
import FloraCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Activity").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("A record of what actually changed. Undo is available for this session’s reversible actions, most recent first.").font(.callout).foregroundStyle(.secondary)
            if model.state.history.isEmpty { EmptyMailView(title: "No changes yet", message: "Accepted suggestions and mail actions will appear here.", icon: "clock.arrow.circlepath") }
            else {
                List(model.state.history.reversed()) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle").foregroundStyle(entry.undone ? Color.secondary : .floraAccent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.proposal.explanation).strikethrough(entry.undone).font(.callout)
                            Text("\(entry.proposal.origin.rawValue.capitalized) · \(entry.undone ? "Undone" : "Executed locally") · \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 7)
                }.listStyle(.inset)
            }
            HStack { Spacer(); Button("Undo Last Mail Action") { model.undo() }.disabled(!model.canUndo) }
        }.padding(24).frame(width: 630, height: 520)
    }
}

struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var editingID: UUID?
    @State private var renameText = ""
    @State private var removal: MailCategory?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your categories").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("You define the structure. AI can suggest an existing category; it cannot create one. Categories and assignments stay on this Mac.").font(.callout).foregroundStyle(.secondary)
            List(model.state.categories) { category in
                HStack {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Color.floraAccent)
                    if editingID == category.id {
                        TextField("Category name", text: $renameText).onSubmit { rename(category) }
                        Button("Save") { rename(category) }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") { editingID = nil }
                    } else {
                        Text(category.name)
                        Spacer()
                        Text("\(model.state.messages.filter { $0.categoryID == category.id }.count)").foregroundStyle(.secondary).font(.caption)
                        Button("Rename") { editingID = category.id; renameText = category.name }.buttonStyle(.link)
                        Button { removal = category } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove \(category.name)")
                    }
                }.padding(.vertical, 7).accessibilityElement(children: .contain)
            }.listStyle(.inset)
            HStack {
                TextField("New category, e.g. Personal", text: $newName).textFieldStyle(.roundedBorder).onSubmit(create)
                Button("Add Category", action: create).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.canUndo { Button("Undo Last Mail Action") { model.undo() }.buttonStyle(.link).font(.caption) }
        }.padding(24).frame(width: 560, height: 510)
            .confirmationDialog("Remove \(removal?.name ?? "category")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("Remove Category", role: .destructive) {
                    if let removal { model.perform(ProposedAction(type: .deleteCategory(id: removal.id), explanation: "Removed category “\(removal.name)” and its local assignments.")) }
                    removal = nil
                }
            } message: { Text("Messages are kept. Local assignments and predictions for this category are removed. AI will use only your remaining categories. You can undo this.") }
    }
    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.perform(ProposedAction(type: .createCategory(MailCategory(name: name)), explanation: "Created category “\(name)”.")) { newName = "" }
    }
    private func rename(_ category: MailCategory) {
        if model.perform(ProposedAction(type: .renameCategory(id: category.id, name: renameText), explanation: "Renamed category “\(category.name)” to “\(renameText)”.")) { editingID = nil }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            AccountsSettingsView()
            Section("AI assistance") {
                Picker("Provider", selection: Binding(get: { model.state.preferences.aiMode }, set: { model.updateAIMode($0) })) {
                    ForEach(AIMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                }
                Text("Demo AI uses local text rules. Local AI uses your configured on-device model. Off keeps all traditional mail controls available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LocalAISettingsView()
            Section("Privacy & accounts") {
                LabeledContent("Mail access", value: model.state.preferences.showDemoAccounts ? "Demo Mode" : "Real accounts · Read only")
                LabeledContent("AI connection", value: "Loopback only · No cloud fallback")
                LabeledContent("Sending", value: "Local demo only")
                Text("Demo Mode needs no credentials. Real accounts use Keychain; synchronized mail stays available offline.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Human control") {
                Text("Suggestions never send or move mail. Accept a classification or a writing preview to apply it. Automated rules are disabled in this milestone.").font(.callout)
                LabeledContent("Mail Undo", value: "⌥⌘Z · Current session")
                LabeledContent("Text editing Undo", value: "⌘Z · Composer")
                Text("Demo mailbox changes are reversible. All server-side mail actions are disabled for real accounts.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local storage") {
                Text(model.storageURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("Versioned JSON, written atomically through a repository. Messages, drafts, categories, AI results, preferences, rules, and activity persist across launches.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Generated AI Cache") { Task { await model.clearAICache() } }
                Text("Clears generated results only. Your messages, drafts and accepted categories are kept.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 650, height: 760)
    }
}

struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MailMessage] = []
    @State private var searched = false
    @State private var busy = false
    @State private var notice: String?
    @State private var searchTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Mail assistant", systemImage: "sparkle.magnifyingglass").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(model.state.preferences.aiMode == .mock ? "An optional way to find mail. Demo search uses keyword expansion and returns original messages." : "Find original messages using text search. Mailbox-wide semantic inference is not enabled in this local provider.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Find messages about deadlines or meetings", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Find", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            HStack {
                ForEach(["Needs a reply", "School deadlines", "Project meeting"], id: \.self) { prompt in
                    Button(prompt) { query = prompt; search() }.controlSize(.small)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if searched && results.isEmpty { EmptyMailView(title: "No matching messages", message: "Try a sender, subject, or topic.", icon: "magnifyingglass") }
            else {
                List(results) { message in
                    Button {
                        model.openMessage(message.id); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.subject).font(.headline)
                            Text("\(message.from.name) · \(message.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            Text(message.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
            Text("Read-only · No actions are executed from this panel").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 650, height: 550)
            .onDisappear { searchTask?.cancel() }
    }
    private func search() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true; searched = false; notice = nil
        searchTask = Task { @MainActor in
            do {
                let result = try await model.assistantSearch(text)
                try Task.checkCancellation()
                results = result.messages
                notice = result.notice
            } catch is CancellationError { return } catch {
                notice = error.localizedDescription
            }
            busy = false; searched = true
        }
    }
}
