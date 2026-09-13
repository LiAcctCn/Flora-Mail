import SwiftUI
import FloraCore

@MainActor
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: Draft

    @State private var recipient: String
    @State private var subject: String
    @State private var bodyText: String
    @State private var selectedTool: WritingTool = .proofread
    @State private var rewritePreview: RewritePreview?
    @State private var rewriteError: String?
    @State private var isRewriting = false
    @State private var rewriteCancelled = false
    @State private var rewriteTask: Task<Void, Never>?
    @State private var rewriteRequestID = UUID()
    @State private var acceptedRewrite: AcceptedRewrite?
    @State private var showDiscardConfirmation = false
    @State private var sendPreview: Draft?
    @State private var actionError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case recipient, subject, body }
    private struct RewritePreview {
        let source: String
        let text: String
        let tool: WritingTool
        let providerLabel: String
        let providerIdentity: String
    }
    private struct AcceptedRewrite {
        let before: String
        let after: String
    }

    init(draft: Draft) {
        self.draft = draft
        _recipient = State(initialValue: draft.to)
        _subject = State(initialValue: draft.subject)
        _bodyText = State(initialValue: draft.body)
    }

    private var editedDraft: Draft {
        Draft(id: draft.id, to: recipient.trimmingCharacters(in: .whitespacesAndNewlines),
              subject: subject, body: bodyText, replyToMessageID: draft.replyToMessageID, accountID: draft.accountID)
    }

    private var isDirty: Bool {
        model.draftHasUnsavedChanges(editedDraft)
    }

    private var recipientIsValid: Bool {
        let recipients = recipient.split(separator: ",", omittingEmptySubsequences: false)
        return !recipients.isEmpty && recipients.allSatisfy { part in
            let address = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
            return pieces.count == 2 && !pieces[0].isEmpty && pieces[1].contains(".")
                && !address.contains(where: { $0.isWhitespace })
        }
    }

    private var canSend: Bool {
        model.canSendDemo(editedDraft) && recipientIsValid && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("To").foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    TextField("alex@example.com", text: $recipient)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .recipient)
                        .accessibilityLabel("To")
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    TextField("Subject", text: $subject)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .subject)
                        .accessibilityLabel("Subject")
                }
            }
            .padding(20)
            Divider()
            TextEditor(text: $bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(minHeight: 160, maxHeight: .infinity)
                .focused($focusedField, equals: .body)
                .accessibilityLabel("Message body")
                .accessibilityIdentifier("composerBody")
            Divider()
            writingTools
            if isRewriting {
                Text(model.state.preferences.aiMode == .local ? "Generating a preview on this Mac. You can keep editing." : "Preparing a Demo AI preview. You can keep editing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let preview = rewritePreview {
                previewSection(preview)
            } else if let rewriteError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(rewriteError, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { generateRewrite() }.controlSize(.small)
                        if model.state.preferences.aiMode == .local {
                            SettingsLink { Text("Configure Local AI") }.controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 14)
            } else if rewriteCancelled {
                Text("Writing request cancelled. Your draft is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 580, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isDirty)
        .useApplicationTerminationPolicy()
        .alert("Save changes to this draft?", isPresented: $showDiscardConfirmation) {
            Button("Save Draft") { saveAndClose() }
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits have not been saved. Any previously saved version will remain in Drafts.")
        }
        .sheet(item: $sendPreview) { preview in
            DemoSendConfirmation(draft: preview) {
                if model.sendDraft(preview) {
                    sendPreview = nil
                    dismiss()
                    return nil
                }
                return takeActionError()
            }
        }
        .onAppear {
            focusedField = recipient.isEmpty ? .recipient : .body
            actionError = model.editorRecoveryError
            model.updateEditorDraft(editedDraft, isDirty: isDirty)
        }
        .onChange(of: [recipient, subject, bodyText]) { _, _ in
            // Keep the current text available to the app's close/quit policy.
            // It remains an unsaved edit until the user chooses Save Draft.
            model.updateEditorDraft(editedDraft, isDirty: isDirty)
        }
        .onDisappear {
            rewriteTask?.cancel()
            model.clearEditorDraft(id: draft.id)
        }
        .onChange(of: model.aiRequestIdentity) { _, _ in
            rewriteTask?.cancel()
            rewriteRequestID = UUID()
            isRewriting = false
            rewritePreview = nil
            rewriteError = nil
            rewriteCancelled = false
        }
        .accessibilityIdentifier("mailComposer")
    }

    private var header: some View {
        HStack {
            Text(draft.replyToMessageID == nil ? "New Message" : "Reply")
                .font(.headline)
            Spacer()
            Text(model.state.accounts.first { $0.id == draft.accountID }?.address.email ?? "Local draft").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var writingTools: some View {
        HStack(spacing: 10) {
            Label("Writing Tools", systemImage: "pencil.line")
                .font(.subheadline.weight(.medium))
            Picker("Writing style", selection: $selectedTool) {
                ForEach(WritingTool.allCases) { tool in Text(tool.rawValue).tag(tool) }
            }
            .labelsHidden().frame(width: 136)
            .disabled(!model.aiEnabled || isRewriting)
            Button("Preview") { generateRewrite() }
                .disabled(!model.aiEnabled || isRewriting || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("previewRewrite")
            if isRewriting {
                ProgressView().controlSize(.small)
                Button("Cancel") {
                    rewriteTask?.cancel()
                    rewriteRequestID = UUID()
                    isRewriting = false
                    rewriteCancelled = true
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            if let acceptedRewrite, bodyText == acceptedRewrite.after {
                Button("Undo Rewrite") {
                    bodyText = acceptedRewrite.before
                    self.acceptedRewrite = nil
                }
                .controlSize(.small)
            }
            if !model.aiEnabled {
                Text("AI is off").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func previewSection(_ preview: RewritePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(preview.tool.rawValue) preview").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(preview.providerLabel) · Generated")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(preview.text)
                    .font(.body).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, idealHeight: 130, maxHeight: 180)
            .background(Color.floraAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 10) {
                Button("Replace") { acceptRewrite(preview, insert: false) }
                    .disabled(!canAccept(preview))
                    .accessibilityIdentifier("acceptRewrite")
                Button("Insert Below") { acceptRewrite(preview, insert: true) }
                    .disabled(!canAccept(preview))
                Button("Cancel") { rewritePreview = nil }
                Spacer()
                if bodyText != preview.source {
                    Text("Message changed. Generate a new preview.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Review before applying.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .accessibilityIdentifier("rewritePreview")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Cancel") {
                    if isDirty { showDiscardConfirmation = true } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Draft") { saveAndClose() }
                    .keyboardShortcut("s", modifiers: .command)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.canSendDemo(editedDraft) ? "Nothing leaves this Mac." : "Read-only account · Draft saved locally.").font(.caption).foregroundStyle(.secondary)
                    if !recipient.isEmpty && !recipientIsValid {
                        Text("Enter valid email addresses, separated by commas.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Add a subject to send.").font(.caption2).foregroundStyle(.secondary)
                    } else if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Add a message body to send.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button(model.canSendDemo(editedDraft) ? "Send Demo" : "Sending Disabled") { actionError = nil; sendPreview = editedDraft }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.floraAccent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .padding(20)
    }

    private func generateRewrite() {
        rewriteTask?.cancel()
        let source = bodyText
        let tool = selectedTool
        let providerLabel = model.aiLabel
        let providerIdentity = model.aiRequestIdentity
        let requestID = UUID()
        rewriteRequestID = requestID
        rewritePreview = nil
        rewriteError = nil
        rewriteCancelled = false
        isRewriting = true
        rewriteTask = Task { @MainActor in
            do {
                let result = try await model.rewrite(source, tool: tool, replyToMessageID: draft.replyToMessageID, accountID: draft.accountID)
                guard !Task.isCancelled, rewriteRequestID == requestID,
                      providerIdentity == model.aiRequestIdentity else { return }
                rewritePreview = RewritePreview(source: source, text: result, tool: tool,
                                                providerLabel: providerLabel, providerIdentity: providerIdentity)
            } catch {
                guard !Task.isCancelled, rewriteRequestID == requestID,
                      providerIdentity == model.aiRequestIdentity else { return }
                rewriteError = "Writing assistance unavailable: \(error.localizedDescription)"
            }
            isRewriting = false
        }
    }

    private func acceptRewrite(_ preview: RewritePreview, insert: Bool) {
        guard canAccept(preview) else { return }
        let replacement = insert ? bodyText + "\n\n" + preview.text : preview.text
        acceptedRewrite = AcceptedRewrite(before: bodyText, after: replacement)
        bodyText = replacement
        rewritePreview = nil
        focusedField = .body
    }

    private func canAccept(_ preview: RewritePreview) -> Bool {
        bodyText == preview.source && preview.providerIdentity == model.aiRequestIdentity
    }

    private func saveAndClose() {
        actionError = nil
        if model.saveDraft(editedDraft) { dismiss() }
        else { actionError = takeActionError() }
    }

    private func takeActionError() -> String {
        let message = model.errorMessage ?? "The operation could not be completed. Your text is still available here."
        // Present write failures in the active sheet, where the user can act on
        // them, instead of asking the obscured main window to present an alert.
        model.errorMessage = nil
        return message
    }
}

@MainActor
private struct DemoSendConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let draft: Draft
    let onSend: () -> String?
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Send this demo message?", systemImage: "paperplane")
                .font(.title3.weight(.semibold))
            Text("This adds a message to the local Sent folder. No email is delivered and nothing leaves this app.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("To").foregroundStyle(.secondary); Text(draft.to).textSelection(.enabled) }
                GridRow { Text("Subject").foregroundStyle(.secondary); Text(draft.subject.isEmpty ? "(No subject)" : draft.subject).textSelection(.enabled) }
            }
            Divider()
            ScrollView {
                Text(draft.body).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 150, idealHeight: 240, maxHeight: 320)
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Keep Editing") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSending)
                Spacer()
                Button("Confirm Demo Send") {
                    guard !isSending else { return }
                    isSending = true
                    sendError = onSend()
                    if sendError != nil { isSending = false }
                }
                    .buttonStyle(.borderedProminent).tint(Color.floraAccent)
                    .disabled(isSending)
                    .accessibilityIdentifier("confirmDemoSend")
            }
        }
        .padding(24)
        .frame(width: 540)
        .useApplicationTerminationPolicy()
    }
}
