import SwiftUI
import FloraCore

struct AutomationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AutomationRule?
    private var controller: AutomationController { model.automationController }
    private var accountIDs: Set<UUID> { Set(model.displayedAccounts.map(\.id)) }
    private var rules: [AutomationRule] { controller.rules.filter { $0.accountID.map(accountIDs.contains) == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Automation", systemImage: "checklist").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { controller.dismissPreview(); dismiss() }.disabled(controller.isRunning).keyboardShortcut(.cancelAction)
            }
            Text("Level \(model.state.preferences.automationLevel.rawValue) · \(model.state.preferences.automationLevel.title) · \(model.intelligenceScopeLabel)").font(.callout)
            Text("Rules run only when you choose Run Now. Opening Flora or synchronizing mail does not run them. Each scope names one account, sender, age, action and batch limit. Sending and deletion are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("New Rule") {
                    editing = AutomationRule(name: "Inbox rule", senderEmail: "", olderThanDays: 30, enabled: true,
                                             accountID: model.accountScopeID ?? model.displayedAccounts.first?.id,
                                             expiresAt: Date().addingTimeInterval(7 * 86_400))
                }.disabled(model.state.preferences.automationLevel < .rules || model.displayedAccounts.isEmpty || controller.isRunning)
                if model.state.preferences.automationLevel < .rules {
                    Text("Choose Level 3 or 4 in Settings to authorize a scope.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop Run") { controller.cancel() }
                }
            }
            if let error = controller.errorMessage { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
            if let status = controller.statusMessage { Text(status).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let preview = controller.preview {
                        previewSection(preview)
                    }
                    if rules.isEmpty {
                        Text("No rules for this mail mode. Normal mail controls are always available.").foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                    ForEach(rules) { rule in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(rule.name).font(.headline)
                                Spacer()
                                Text(rule.enabled ? (rule.expiresAt.map { $0 > Date() } == true ? (rule.delegationOnly ? "Delegation scope" : "Authorized scope") : "Expired") : "Revoked / disabled").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(scopeDescription(rule)).font(.callout)
                            if let expiry = rule.expiresAt { Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("Preview Matches") { controller.preview(rule: rule) }.disabled(!rule.enabled || controller.isRunning)
                                Button("Edit & Reauthorize") { editing = rule }.disabled(controller.isRunning || model.state.preferences.automationLevel < .rules)
                                if rule.enabled { Button("Revoke") { controller.revokeRule(id: rule.id) } }
                            }.controlSize(.small)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                    let grants = controller.grants.filter { accountIDs.contains($0.accountID) }
                    if !grants.isEmpty {
                        DisclosureGroup("One-run authorizations · \(grants.count)") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(grants.reversed()) { grant in
                                    HStack {
                                        Text("\(grant.messageIDs.count) messages · \(grant.isRevoked ? "Revoked" : grant.isConsumed ? "Consumed" : grant.expiresAt <= Date() ? "Expired" : "Ready") · Expires \(grant.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                        Spacer()
                                        if !grant.isRevoked { Button("Revoke") { controller.revokeDelegation(id: grant.id) }.controlSize(.small) }
                                    }
                                }
                            }.padding(.top, 8)
                        }
                    }
                    let history = controller.history.filter { accountIDs.contains($0.accountID) }
                    if !history.isEmpty {
                        Divider()
                        Text("Run history").font(.headline)
                        ForEach(history) { run in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AutomationController.description(for: run)).font(.callout)
                                Text(run.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                if let error = run.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 5)
                        }
                        Text("Completed actions also appear in Activity. Local Demo changes can be undone during this session. Remote read changes may offer a real inverse; remote archive and sent messages have no Undo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 720, height: 650)
            .interactiveDismissDisabled(controller.isRunning)
            .sheet(item: $editing) { rule in AutomationRuleEditor(rule: rule).environment(model) }
            .onDisappear { controller.dismissPreview() }
    }

    private func previewSection(_ preview: AutomationPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review before running").font(.headline)
            Text(preview.explanation).font(.callout)
            Text(scopeDescription(preview.rule)).font(.caption).foregroundStyle(.secondary)
            ForEach(controller.matches) { message in
                Text("\(message.from.email) · \(message.subject)").font(.caption).lineLimit(2)
            }
            Text("\(preview.messageIDs.count) selected of \(preview.totalMatchingCount) matching cached messages. A changed scope requires a fresh preview.").font(.caption).foregroundStyle(.secondary)
            if preview.rule.delegationOnly && model.state.preferences.automationLevel < .delegated {
                Text("This scope requires Level 4 and one-run approval. Lowering the level does not make it reusable.").font(.caption).foregroundStyle(.secondary)
            }
            if model.state.preferences.automationLevel == .delegated {
                if let grant = controller.activeGrant {
                    Text("One run authorized until \(grant.expiresAt.formatted(date: .omitted, time: .shortened)). The grant is consumed before execution.").font(.caption)
                } else {
                    Button("Authorize One Run for These Messages") {
                        controller.authorizeDelegation(expiresAt: min(preview.rule.expiresAt ?? .distantPast, Date().addingTimeInterval(30 * 60)), confirmed: true)
                    }.disabled(preview.messageIDs.count > 10)
                    if preview.messageIDs.count > 10 {
                        Text("Level 4 allows at most 10 messages. Edit the rule with a smaller batch limit and preview again.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Expires within 30 minutes or when the rule expires. This grants one attempt for this exact batch; it does not start execution.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Run Now") { Task { await controller.runPreview() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isRunning || preview.messageIDs.isEmpty || model.state.preferences.automationLevel < .rules || (preview.rule.delegationOnly && model.state.preferences.automationLevel < .delegated) || (model.state.preferences.automationLevel == .delegated && controller.activeGrant == nil))
                Button("Cancel Preview") { controller.dismissPreview() }.disabled(controller.isRunning)
            }
        }.padding(16).background(Color.floraAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
    private func scopeDescription(_ rule: AutomationRule) -> String {
        let account = model.state.accounts.first { $0.id == rule.accountID }?.address.email ?? "Account unavailable"
        return "\(rule.action.title) at most \(rule.maxMessages) Inbox messages from exactly \(rule.senderEmail), older than \(rule.olderThanDays) days, in \(account)."
    }
}

private struct AutomationRuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rule: AutomationRule
    @State private var name: String
    @State private var sender: String
    @State private var accountID: UUID?
    @State private var action: AutomationAction
    @State private var days: Int
    @State private var maximum: Int
    @State private var expiry: Date
    init(rule: AutomationRule) {
        self.rule = rule
        _name = State(initialValue: rule.name); _sender = State(initialValue: rule.senderEmail)
        _accountID = State(initialValue: rule.accountID); _action = State(initialValue: rule.action)
        _days = State(initialValue: rule.olderThanDays); _maximum = State(initialValue: rule.maxMessages)
        _expiry = State(initialValue: rule.expiresAt.map { max($0, Date().addingTimeInterval(3_600)) } ?? Date().addingTimeInterval(7 * 86_400))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review automation scope").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                Picker("Account", selection: $accountID) {
                    ForEach(model.displayedAccounts) { account in Text(account.address.email).tag(Optional(account.id)) }
                }
                TextField("Exact sender address", text: $sender)
                Picker("Action", selection: $action) { ForEach(AutomationAction.allCases) { action in Text(action.title).tag(action) } }
                LabeledContent("Folder", value: "Inbox only")
                Stepper("Older than \(days) days", value: $days, in: 1...3_650)
                Stepper("At most \(maximum) messages per run", value: $maximum, in: 1...(model.state.preferences.automationLevel == .delegated ? 10 : 50))
                DatePicker("Authorization expires", selection: $expiry)
            }
            Text(model.state.preferences.automationLevel == .delegated ? "This saves a delegation-only scope. Each run requires a new approval for the exact matched messages. Lowering the assistance level cannot make this scope reusable. No action runs until you review matches, authorize one run and choose Run Now." : "Saving explicitly authorizes this reusable scope until expiry. Each Run Now applies only a reviewed batch within these limits. Editing the scope invalidates previous authorizations. No action runs when you save.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.automationController.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Authorize Rule Scope") {
                    var candidate = rule
                    candidate.name = name; candidate.senderEmail = sender; candidate.accountID = accountID
                    candidate.action = action; candidate.olderThanDays = days; candidate.maxMessages = maximum
                    candidate.expiresAt = expiry; candidate.enabled = true
                    candidate.delegationOnly = model.state.preferences.automationLevel == .delegated
                    model.automationController.saveRule(candidate, confirmed: true)
                    if model.automationController.errorMessage == nil { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(accountID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 580)
            .onAppear { if model.state.preferences.automationLevel == .delegated { maximum = min(maximum, 10) } }
    }
}
