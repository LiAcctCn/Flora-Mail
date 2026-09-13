import SwiftUI
import FloraCore

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Activity").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Mail service operations and local changes are recorded separately. Remote read/flag changes offer a confirmed inverse when still valid; sends cannot be undone.").font(.callout).foregroundStyle(.secondary)
            if model.state.history.isEmpty && model.state.remoteActionHistory.isEmpty { EmptyMailView(title: "No changes yet", message: "Accepted suggestions and mail actions will appear here.", icon: "clock.arrow.circlepath") }
            else {
                List {
                    if !model.state.remoteActionHistory.isEmpty {
                        Section("Mail service actions") {
                            ForEach(model.state.remoteActionHistory.reversed()) { record in RemoteActivityRow(record: record) }
                        }
                    }
                    Section("Local actions") {
                    ForEach(model.state.history.reversed()) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle").foregroundStyle(entry.undone ? Color.secondary : .floraAccent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.proposal.explanation).strikethrough(entry.undone).font(.callout)
                            Text("\(entry.proposal.origin.rawValue.capitalized) · \(entry.undone ? "Undone" : "Executed locally") · \(entry.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 7)
                    }
                    }
                }.listStyle(.inset)
            }
            HStack { Spacer(); Button("Undo Last Local Action") { model.undo() }.disabled(!model.canUndo) }
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
    @State private var showingAutomation = false
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
            Section("Adaptive categories") {
                Toggle("Learn from my confirmed category choices", isOn: Binding(get: { model.state.preferences.learnCategoryPreferences }, set: { model.setCategoryLearning($0) }))
                Text("After two matching choices for a sender in one account, Flora can suggest that category. Conflicting corrections suspend the pattern. Suggestions remain local and require acceptance; deleted categories stay deleted. Disabling this setting stops using history for suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            PersonalContextSettingsView()
            Section("Privacy & accounts") {
                LabeledContent("Mail access", value: model.state.preferences.showDemoAccounts ? "Demo Mode" : "Real accounts · Per-account permission")
                LabeledContent("AI connection", value: "Loopback only · No cloud fallback")
                LabeledContent("Sending", value: "Preview and explicit confirmation")
                Text("Demo Mode needs no credentials. Real accounts use Keychain; synchronized mail stays available offline.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Human control") {
                Picker("Assistance level", selection: Binding(get: { model.state.preferences.automationLevel }, set: { model.setAutomationLevel($0) })) {
                    ForEach(AutomationLevel.allCases) { level in Text("Level \(level.rawValue) · \(level.title)").tag(level) }
                }
                Text("Choosing a higher level does not authorize a rule. Level 3 requires an exact saved scope; Level 4 requires an expiring grant for one reviewed batch. Send and deletion are never automated.").font(.caption).foregroundStyle(.secondary)
                Button("Automation Rules…") { showingAutomation = true }
                LabeledContent("Mail Undo", value: "⌥⌘Z · Current session")
                LabeledContent("Text editing Undo", value: "⌘Z · Composer")
                Text("Demo changes use local Undo. Remote read/flag Undo executes an inverse at the provider; sends and moves do not have an Undo shortcut.").font(.caption).foregroundStyle(.secondary)
            }
            ResearchSettingsView()
            Section("Local storage") {
                Text(model.storageURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("Versioned JSON, written atomically through a repository. Messages, drafts, categories, AI results, preferences, rules, and activity persist across launches.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Generated AI Cache") { Task { await model.clearAICache() } }
                Text("Clears generated results only. Your messages, drafts and accepted categories are kept.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 650, height: 760)
            .sheet(isPresented: $showingAutomation) { AutomationView().environment(model) }
    }
}
