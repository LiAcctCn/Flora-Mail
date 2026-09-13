import SwiftUI
import UniformTypeIdentifiers
import FloraCore

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingConnection = false
    @State private var reconnecting: MailAccount?
    @State private var disconnecting: MailAccount?
    @State private var syncSettings = MailSyncSettings()

    var body: some View {
        Section("Accounts") {
            Toggle("Demo Mode", isOn: Binding(get: { model.state.preferences.showDemoAccounts }, set: { model.setDemoMode($0) }))
            Text(model.state.preferences.showDemoAccounts ? "Showing fictional demo mail. Connected accounts remain cached separately." : "Showing cached real mail. Server-side mail actions are disabled.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.state.accounts.filter(\.isReadOnly)) { account in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.providerType.title).font(.headline)
                            Text(account.address.email).textSelection(.enabled)
                        }
                        Spacer()
                        Text(model.accountController.isDisconnecting(account.id) ? "Disconnecting…" : account.status.title).font(.caption).foregroundStyle(account.status == .connected ? Color.floraAccent : .secondary)
                    }
                    if let progress = model.accountController.syncProgress[account.id] {
                        HStack { ProgressView().controlSize(.small); Text(progress).font(.caption) }
                    } else if let date = account.syncState.lastSuccessfulSync {
                        HStack(spacing: 4) { Text("Last successful sync:"); Text(date, style: .relative); Text("ago") }.font(.caption).foregroundStyle(.secondary)
                    } else { Text("No successful sync yet").font(.caption).foregroundStyle(.secondary) }
                    if let error = account.syncState.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Restart Recent Sync") { model.accountController.restartRecentSync(account.id) }
                            .controlSize(.small).disabled(account.credentialReference == nil || model.accountController.isSyncing(account.id) || model.accountController.isDisconnecting(account.id))
                    }
                    HStack {
                        Button(account.credentialReference == nil ? "Connect" : "Reauthenticate") {
                            reconnecting = account; model.accountController.clearConnectionError(); showingConnection = true
                        }.disabled(model.accountController.isSyncing(account.id) || model.accountController.connecting || model.accountController.isDisconnecting(account.id))
                        if model.accountController.isSyncing(account.id) {
                            Button("Cancel Sync") { model.accountController.cancelSync(account.id) }
                        } else {
                            Button(model.accountController.moreAvailable.contains(account.id) || account.syncState.checkpoint?.initialComplete == false ? "Load Next Batch" : "Sync Now") {
                                model.accountController.syncNow(account.id)
                            }.disabled(account.credentialReference == nil || model.accountController.isDisconnecting(account.id))
                        }
                        Button("Disconnect") { disconnecting = account }.disabled(account.credentialReference == nil || model.accountController.connecting || model.accountController.isDisconnecting(account.id))
                        Spacer()
                        Button("View Mail") { model.setDemoMode(false); model.navigate(.account(account.id)) }
                    }.controlSize(.small)
                }.padding(.vertical, 7)
            }
            if !model.state.accounts.contains(where: \.isReadOnly) {
                Text("No real accounts connected. Add Gmail, Outlook or iCloud to retrieve a recent, bounded window of mail.").foregroundStyle(.secondary)
            }
            if let error = model.accountController.connectionError, !showingConnection { Text(error).font(.caption).foregroundStyle(.secondary) }
            Button("Add Account") {
                reconnecting = nil; model.accountController.clearConnectionError(); showingConnection = true
            }.disabled(model.accountController.connecting).accessibilityIdentifier("addMailAccount")
            Text("Credentials are kept in macOS Keychain. Disconnect removes local credentials and keeps cached mail available offline; it does not revoke consent at the provider.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Sync Limits") {
                Stepper("Recent window: \(syncSettings.recentDays) days", value: $syncSettings.recentDays, in: 1...365)
                Stepper("Messages per batch: \(syncSettings.maximumMessages)", value: $syncSettings.maximumMessages, in: 25...2_000, step: 25)
                Text("The initial sync retrieves recent mail first. Each Sync Now or Load Next Batch is bounded. New mail and provider changes use saved checkpoints; no background schedule runs.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save Sync Limits") { model.saveSyncSettings(syncSettings) }
                    .disabled(syncSettings == model.state.preferences.mailSyncSettings)
            }
        }
        .onAppear { syncSettings = model.state.preferences.mailSyncSettings }
        .sheet(isPresented: $showingConnection) { AddAccountView(existing: reconnecting).environment(model) }
        .confirmationDialog("Disconnect this account?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                if let account = disconnecting { Task { await model.accountController.disconnect(account.id) } }
                disconnecting = nil
            }
        } message: { Text("Cached messages remain on this Mac. Reconnecting requires sign-in again.") }
    }
}

struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: MailAccount?
    @State private var provider: MailProviderType = .gmail
    @State private var importingRegistration = false
    @State private var importError: String?
    @State private var clientID = ""
    @State private var email = ""
    @State private var password = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "Add an account" : "Reconnect account").font(.title2.weight(.semibold))
            Text("Read-only mail access").font(.subheadline).foregroundStyle(Color.floraAccent)
            Picker("Provider", selection: $provider) {
                Text("Google").tag(MailProviderType.gmail)
                Text("Microsoft Outlook").tag(MailProviderType.microsoft)
                Text("iCloud Mail").tag(MailProviderType.iCloud)
            }.pickerStyle(.segmented).disabled(existing != nil || model.accountController.connecting)
            if provider == .iCloud {
                TextField("iCloud email address", text: $email).textFieldStyle(.roundedBorder)
                    .disabled(existing != nil || model.accountController.connecting).accessibilityIdentifier("iCloudEmail")
                SecureField("App-specific password", text: $password).textFieldStyle(.roundedBorder)
                    .disabled(model.accountController.connecting).accessibilityIdentifier("iCloudAppPassword")
                Text("Use an app-specific password generated in your Apple Account, never your primary Apple Account password. It is stored only in Keychain. Incoming mail uses encrypted IMAP; SMTP is disabled.")
                    .font(.callout).foregroundStyle(.secondary)
                if let url = URL(string: "https://support.apple.com/102654") { Link("Create an app-specific password", destination: url) }
            } else {
                TextField("Public OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder)
                    .disabled(model.accountController.connecting).accessibilityIdentifier("oauthClientID")
                Button("Import Public App Registration…") { importingRegistration = true }.controlSize(.small).disabled(model.accountController.connecting)
                if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
                Text(provider == .gmail
                     ? "Use a Google OAuth Desktop app client ID with the Gmail API enabled. Testing apps require your account to be added as a test user. Flora requests gmail.readonly only."
                     : "Use a Microsoft public-client application ID with personal and work/school account support. Enable the desktop loopback redirect; Flora requests Mail.Read, User.Read for identity, and offline_access for refresh.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Your browser handles sign-in. Do not paste tokens, passwords or client secrets into the client ID field. App-registration instructions are in Docs/ProviderSetup.md in this project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Messages are retrieved into local storage. Flora cannot send, archive, delete, move or change flags on this account. Attachments download only when requested; email scripts and remote images are not loaded.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.accountController.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
            if let message = model.accountController.connectionMessage {
                HStack { if model.accountController.connecting { ProgressView().controlSize(.small) }; Text(message).font(.caption) }
            }
            Spacer(minLength: 0)
            HStack {
                Button(model.accountController.connecting ? "Cancel Sign-in" : "Cancel") {
                    task?.cancel(); model.accountController.cancelConnection(); password = ""
                    if !model.accountController.connecting { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect") { connect() }.buttonStyle(.borderedProminent)
                    .disabled(model.accountController.connecting || (provider == .iCloud ? email.isEmpty || password.isEmpty : clientID.isEmpty))
                    .accessibilityIdentifier("connectMailAccount")
            }
        }.padding(28).frame(width: 590, height: 600)
        .fileImporter(isPresented: $importingRegistration, allowedContentTypes: [.json]) { result in
            do {
                clientID = try OAuthRegistrationImport.clientID(from: result.get(), provider: provider)
                importError = nil
            } catch { importError = "This file does not contain a valid public app identifier for the selected provider." }
        }
        .interactiveDismissDisabled(model.accountController.connecting)
        .onAppear { provider = existing?.providerType ?? .gmail; clientID = existing?.oauthClientID ?? ""; email = existing?.address.email ?? "" }
        .onChange(of: provider) { _, _ in password = ""; clientID = existing?.oauthClientID ?? ""; model.accountController.clearConnectionError() }
        .onDisappear { task?.cancel(); model.accountController.cancelConnection(); password = "" }
    }
    private func connect() {
        let provider = provider, identifier = clientID, username = email
        let appPassword = password; password = ""
        task = Task { @MainActor in
            let connected: Bool
            if provider == .iCloud { connected = await model.accountController.connectICloud(email: username, appSpecificPassword: appPassword, existingAccount: existing) }
            else { connected = await model.accountController.connectOAuth(provider: provider, clientID: identifier, existingAccount: existing) }
            if connected { dismiss() }
        }
    }
}
