import SwiftUI
import FloraCore

struct AppShell: View {
    @Environment(AppModel.self) private var model
    @State private var discardRecovery = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let draft = model.recoverableDraft {
                    HStack {
                        Label("Recover unsaved draft: \(draft.subject.isEmpty ? "Untitled" : draft.subject)", systemImage: "doc.badge.clock").font(.caption).lineLimit(1)
                        Spacer()
                        Button("Review") { model.recoverUnsavedDraft() }
                        Button("Discard…") { discardRecovery = true }
                    }.padding(10).background(.orange.opacity(0.08))
                }
                if let warning = model.storageWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1))
                }
                if !model.state.preferences.showDemoAccounts {
                    MailSyncStatusView()
                    Divider()
                }
                if model.destination == .today {
                    TodayView()
                } else if model.destination == .localDrafts || (model.destination == .folder(.drafts) && model.state.preferences.showDemoAccounts) {
                    DraftsView()
                } else {
                    HSplitView {
                        MessageListView().frame(minWidth: 270, idealWidth: 330, maxWidth: 430)
                        Group {
                            if let message = model.selectedMessage { ReaderView(message: message).id(message.id) }
                            else { EmptyMailView() }
                        }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let status = model.statusMessage {
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.floraAccent)
                        Text(status).font(.caption).lineLimit(2)
                        Spacer()
                        if model.statusOffersUndo && model.canUndo { Button("Undo") { model.undo() }.buttonStyle(.link).font(.caption) }
                        Button { model.statusMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss status").accessibilityLabel("Dismiss status")
                    }.padding(.horizontal, 18).padding(.vertical, 10).background(.bar)
                }
            }
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.destination != .today {
                        Button { if let message = model.selectedMessage { model.archive(message) } } label: { Label("Archive", systemImage: "archivebox") }
                            .disabled(!model.canMutateSelection || model.selectedMessage?.folder == .archive).help("Archive selected message")
                        Button { if let message = model.selectedMessage { model.trash(message) } } label: { Label("Trash", systemImage: "trash") }
                            .disabled(!model.canMutateSelection || model.selectedMessage?.folder == .trash).help("Move selected message to Trash")
                        Button { if let message = model.selectedMessage { model.toggleFlag(message) } } label: {
                            Label("Flag", systemImage: model.selectedMessage?.isFlagged == true ? "flag.fill" : "flag")
                        }.disabled(!model.canMutateSelection).help("Toggle flag")
                    }
                    Button { model.showingAccountConnection = true } label: { Label("Add Account", systemImage: "person.badge.plus") }.help("Connect Google, Microsoft or iCloud Mail")
                    Button { model.showingHistory = true } label: { Label("Activity", systemImage: "clock.arrow.circlepath") }.help("Action history and Undo")
                    Button { model.showingAssistant.toggle() } label: { Label("Assistant", systemImage: "sparkle.magnifyingglass") }.help("Open optional mail assistant")
                    Button { model.compose() } label: { Label("Compose", systemImage: "square.and.pencil") }.disabled(!model.canCompose).help("New message (⌘N)")
                }
            }
        }
        .sheet(isPresented: $model.showingAccountConnection) { AddAccountView(existing: nil).environment(model) }
        .sheet(item: $model.composingDraft) { draft in ComposerView(draft: draft).environment(model) }
        .sheet(isPresented: $model.showingHistory) { ActivityView().environment(model) }
        .sheet(isPresented: $model.showingCategories) { CategoriesView().environment(model) }
        .sheet(isPresented: $model.showingAssistant) { AssistantView().environment(model) }
        .sheet(item: $model.pendingRemoteAction) { proposal in RemoteActionPreview(proposal: proposal).environment(model) }
        .confirmationDialog("Discard the recovered unsaved draft?", isPresented: $discardRecovery, titleVisibility: .visible) {
            Button("Discard Recovery Copy", role: .destructive) { model.discardRecoveredDraft() }
        } message: { Text("Previously saved drafts are kept.") }
        .alert("Couldn’t complete that action", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(Color.floraAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Flora Mail").font(.headline)
                    Text("A little more clarity.").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 20)
            List(selection: Binding<MailDestination?>(get: { model.destination }, set: { if let value = $0 { model.navigate(value) } })) {
                Label("Today", systemImage: "sun.max").tag(MailDestination.today)
                Section("Mail") {
                    row("Inbox", icon: "tray", destination: .folder(.inbox), count: model.scopedMessages.filter { $0.folder == .inbox && !$0.isRead }.count)
                    row("Important", icon: "flag", destination: .important)
                    row("Sent", icon: "paperplane", destination: .folder(.sent))
                    row("Drafts", icon: "doc", destination: .folder(.drafts), count: model.state.preferences.showDemoAccounts ? model.visibleDrafts.count : 0)
                    if !model.state.preferences.showDemoAccounts { row("Local Drafts", icon: "square.and.pencil", destination: .localDrafts, count: model.visibleDrafts.count) }
                    row("Archive", icon: "archivebox", destination: .folder(.archive))
                    row("Trash", icon: "trash", destination: .folder(.trash))
                }
                Section {
                    ForEach(model.state.categories) { category in
                        Label { Text(category.name) } icon: { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.floraAccent) }
                            .tag(MailDestination.category(category.id))
                    }
                    Button { model.showingCategories = true } label: { Label("Edit Categories…", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text("Categories") }
                Section(model.state.preferences.showDemoAccounts ? "Accounts · Demo" : "Accounts") {
                    ForEach(model.displayedAccounts) { account in
                        Label(account.isRemote ? account.address.email : account.name, systemImage: "at")
                            .tag(MailDestination.account(account.id))
                        if account.isRemote {
                            DisclosureGroup("Folders & Labels") {
                                ForEach(model.state.remoteFolders.filter { $0.accountID == account.id }) { folder in
                                    Label(folder.name, systemImage: folder.isLabel ? "tag" : "folder")
                                        .tag(MailDestination.providerFolder(accountID: account.id, folderID: folder.id))
                                }
                            }
                        }
                    }
                    if model.displayedAccounts.isEmpty { SettingsLink { Label("Add Account…", systemImage: "plus.circle") } }
                }
            }.listStyle(.sidebar)
            Divider().padding(.horizontal, 12)
            HStack {
                Label(model.state.preferences.showDemoAccounts ? "Demo Mode" : "Cached mail", systemImage: "internaldrive").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
            }.padding(16)
        }
    }
    private func row(_ title: String, icon: String, destination: MailDestination, count: Int = 0) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }.tag(destination)
    }
}

private struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.title).font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(model.visibleMessages.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(model.title.lowercased())", text: $model.searchText)
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search mail")
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(8).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                if !model.searchText.isEmpty {
                    HStack {
                        Text(model.searchResultLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.searching { ProgressView().controlSize(.mini) }
                        else if model.semanticResults != nil { Button("Use Text") { model.clearSemanticSearch() }.font(.caption) }
                        else { Button("Try Semantic") { model.semanticSearch() }.font(.caption).disabled(!model.aiEnabled) }
                    }
                }
                if let notice = model.searchNotice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
            }.padding(16)
            Divider()
            if model.visibleMessages.isEmpty {
                EmptyMailView(title: model.searchText.isEmpty ? "All clear" : "No matches", message: model.searchText.isEmpty ? "No messages in this view." : "Try another word or a broader mailbox.", icon: "tray")
            } else {
                List(selection: $model.selectedMessageID) {
                    ForEach(model.visibleMessages) { message in
                        MessageRow(message: message).tag(message.id)
                            .contextMenu {
                                Button("Reply") { model.compose(replyTo: message) }
                                Button("Forward") { model.compose(replyTo: message, forward: true) }
                                Divider()
                                Button(message.isRead ? "Mark Unread" : "Mark Read") { model.toggleRead(message) }.disabled(model.isReadOnly(message))
                                Button(message.isFlagged ? "Remove Flag" : "Flag") { model.toggleFlag(message) }.disabled(model.isReadOnly(message))
                                Button("Archive") { model.archive(message) }.disabled(model.isReadOnly(message) || message.folder == .archive)
                                Button("Move to Inbox") { model.perform(ProposedAction(type: .move(messageIDs: [message.id], folder: .inbox), explanation: "Moved message to Inbox.")) }.disabled(model.isReadOnly(message) || message.folder == .inbox)
                                Button("Move to Trash") { model.trash(message) }.disabled(model.isReadOnly(message) || message.folder == .trash)
                            }
                    }
                }.listStyle(.inset).alternatingRowBackgrounds(.disabled)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.searchText) { _, _ in model.clearSemanticSearch(); model.reconcileSelection() }
        .background {
            Button("Focus Search") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(message.isRead ? .clear : Color.floraAccent).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.from.name).font(.system(size: 13, weight: message.isRead ? .medium : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.date, format: .dateTime.month(.abbreviated).day()).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(message.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(message.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 5) {
                    if let category = model.state.categories.first(where: { $0.id == message.categoryID }) {
                        Text(category.name).font(.system(size: 9, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.floraAccent.opacity(0.09), in: Capsule())
                    }
                    Spacer()
                    if !message.attachments.isEmpty { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary) }
                    if message.isFlagged { Image(systemName: "flag.fill").font(.caption2).foregroundStyle(Color.floraAccent) }
                    let count = model.state.messages.filter { $0.accountID == message.accountID && $0.threadID == message.threadID }.count
                    if count > 1 { Label("\(count)", systemImage: "bubble.left.and.bubble.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            }
        }.padding(.vertical, 10).accessibilityElement(children: .combine)
    }
}

private struct DraftsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(model.state.preferences.showDemoAccounts ? "Drafts" : "Local Drafts").font(.largeTitle.weight(.semibold)); Spacer(); Button("New Message") { model.compose() }.disabled(!model.canCompose) }
            Text("Your words, at your pace. Drafts are saved on this Mac.").foregroundStyle(.secondary)
            if model.visibleDrafts.isEmpty { EmptyMailView(title: "No drafts", message: "Start a new message whenever you’re ready.", icon: "square.and.pencil") }
            else {
                List(model.visibleDrafts) { draft in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(draft.subject.isEmpty ? "Untitled message" : draft.subject).font(.headline)
                            Text(draft.to.isEmpty ? "No recipient yet" : draft.to).font(.caption).foregroundStyle(.secondary)
                            Text(draft.body).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit Draft") { model.editDraft(draft) }
                        Button { model.perform(ProposedAction(type: .deleteDraft(id: draft.id), explanation: "Deleted draft. Undo is available.")) } label: { Image(systemName: "trash") }.help("Delete draft")
                    }.padding(.vertical, 12).accessibilityElement(children: .contain)
                }.listStyle(.inset)
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Reads local status only; network work stays in AccountController.
private struct MailSyncStatusView: View {
    @Environment(AppModel.self) private var model
    private var accounts: [MailAccount] {
        model.displayedAccounts.filter { model.accountScopeID == nil || $0.id == model.accountScopeID }
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            if let active = accounts.first(where: { model.accountController.isSyncing($0.id) }) {
                ProgressView().controlSize(.mini)
                Text(model.accountController.syncProgress[active.id] ?? "Syncing…").font(.caption)
                Button("Cancel Sync") { model.accountController.cancelSync(active.id) }.controlSize(.small)
            } else if let failed = accounts.first(where: { $0.syncState.errorMessage != nil }) {
                Text(failed.syncState.errorMessage ?? "Sync unavailable. Cached mail remains available.").font(.caption).lineLimit(2)
                SettingsLink { Text("Accounts…") }.controlSize(.small)
            } else if let date = accounts.compactMap({ $0.syncState.lastSuccessfulSync }).min() {
                Text("Last updated \(date.formatted(.relative(presentation: .named))) · Cached mail is available offline").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(accounts.isEmpty ? "Connect an account in Settings to retrieve mail." : "Cached mail · Sync to retrieve recent messages.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if accounts.contains(where: { $0.credentialReference != nil }) {
                Button(accounts.contains(where: { model.accountController.moreAvailable.contains($0.id) }) ? "Load Next Batch" : "Sync Now") {
                    for account in accounts where account.credentialReference != nil { model.accountController.syncNow(account.id) }
                }.controlSize(.small).disabled(accounts.contains { model.accountController.isSyncing($0.id) })
            }
            SettingsLink { Text("Accounts…") }.controlSize(.small)
        }.padding(.horizontal, 18).padding(.vertical, 9)
    }
}
