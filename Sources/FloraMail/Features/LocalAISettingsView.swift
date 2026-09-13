import SwiftUI
import FloraCore

/// Edits a local configuration draft. Saving and connection checks are routed
/// through AppModel; this view never starts a runtime or downloads a model.
@MainActor
struct LocalAISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var configuration = AIModelConfiguration()
    @State private var validationError: String?
    @State private var connectionTask: Task<Void, Never>?

    private var hasChanges: Bool { configuration != model.state.preferences.localAI }

    var body: some View {
        Section("Local AI") {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    if model.checkingLocalConnection { ProgressView().controlSize(.small) }
                    Text(model.localConnectionState)
                        .foregroundStyle(model.localConnectionState == "Connected" ? Color.floraAccent : .secondary)
                }
                .accessibilityIdentifier("localAIStatus")
            }
            LabeledContent("Runtime", value: "Ollama · Local service")
            TextField("Model", text: $configuration.model, prompt: Text("Installed model name"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("localAIModel")
            Text("Use Ollama 0.34 or later with a model installed on this Mac. Flora Mail does not install or download models.")
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup("Advanced Configuration") {
                TextField("Endpoint", text: $configuration.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("localAIEndpoint")
                HStack {
                    Text("Request timeout")
                    Spacer()
                    TextField("Seconds", value: $configuration.timeoutSeconds, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 72)
                        .accessibilityLabel("Local AI request timeout in seconds")
                    Text("seconds").foregroundStyle(.secondary)
                }
                Text("Only loopback endpoints are accepted. Remote endpoints, cloud models and redirects are blocked. Timeout must be between 5 and 180 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if let message = model.localConnectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Save Configuration") { saveConfiguration() }
                    .disabled(!hasChanges || model.checkingLocalConnection)
                    .accessibilityIdentifier("saveLocalAIConfiguration")
                Button("Test Connection") {
                    validationError = nil
                    connectionTask?.cancel()
                    connectionTask = Task { await model.testLocalConnection() }
                }
                .disabled(hasChanges || model.checkingLocalConnection)
                .help(hasChanges ? "Save configuration before testing it." : "Check the local service and installed model without sending email content.")
                .accessibilityIdentifier("testLocalAIConnection")
                if model.checkingLocalConnection {
                    Button("Cancel") {
                        connectionTask?.cancel()
                        model.cancelLocalConnectionTest()
                    }
                }
            }
            if hasChanges {
                Text("Unsaved configuration. Save before testing or using these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Local AI receives only the message or draft needed for the selected task. Mail and generated results stay on this Mac; there is no cloud fallback. Choose Demo AI above to use the prototype without a local model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { configuration = model.state.preferences.localAI }
        .onChange(of: model.state.preferences.localAI) { previous, updated in
            if configuration == previous { configuration = updated }
        }
        .onDisappear {
            connectionTask?.cancel()
            if model.checkingLocalConnection { model.cancelLocalConnectionTest() }
        }
    }

    private func saveConfiguration() {
        validationError = nil
        if model.saveLocalConfiguration(configuration) {
            configuration = model.state.preferences.localAI
        } else {
            validationError = model.errorMessage ?? "The local configuration could not be saved."
            model.errorMessage = nil
        }
    }
}
