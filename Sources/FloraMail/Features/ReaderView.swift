import SwiftUI
import FloraCore

@MainActor
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let message: MailMessage

    @State private var summary: MessageSummary?
    @State private var classification: ClassificationSuggestion?
    @State private var actionItems: [ActionItem] = []
    @State private var suggestedReplies: [SuggestedReply] = []
    @State private var summaryError: String?
    @State private var summaryUnavailable = false
    @State private var assistanceErrors: [String] = []
    @State private var isLoading = false
    @State private var loadingStage = "Preparing summary…"
    @State private var assistanceTask: Task<Void, Never>?
    @State private var activeRequestID = UUID()
    @State private var activeSourceIdentity = ""
    @State private var wasCancelled = false
    @State private var showOriginal = false
    @State private var showHTML = false
    @State private var originalVisibilityWasChosen = false
    @State private var showSources = false
    @State private var ignoredClassification = false
    @State private var retryID = UUID()

    private var currentMessage: MailMessage {
        model.state.messages.first(where: { $0.id == message.id }) ?? message
    }

    private var requestID: String {
        let categories = model.state.categories.map { "\($0.id):\($0.name)" }.joined(separator: ",")
        let assignedCategory = currentMessage.categoryID?.uuidString ?? "uncategorized"
        // Keep the task tied to the source content as well as its ID. A cached
        // message can be refreshed in place without changing the selection.
        return "\(message.id)-\(currentMessage.from.name)-\(currentMessage.from.email)-\(currentMessage.subject)-\(currentMessage.body)-\(assignedCategory)-\(model.aiRequestIdentity)-\(categories)-\(retryID)"
    }

    private var account: MailAccount? {
        model.state.accounts.first { $0.id == currentMessage.accountID }
    }

    private var isReadOnly: Bool { model.isReadOnly(currentMessage) }
    private var isRemote: Bool { account?.isRemote == true }

    private var canDownloadAttachments: Bool {
        account?.credentialReference != nil && account?.status != .disconnected && account?.status != .reauthenticationRequired
    }

    private var threadMessages: [MailMessage] {
        model.state.messages.filter {
            $0.accountID == currentMessage.accountID && $0.threadID == currentMessage.threadID
        }.sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                messageHeader
                Divider()
                if model.embeddedAIEnabled {
                    summarySection
                    classificationSection
                }
                originalSection
                if model.embeddedAIEnabled { PersonalContextView(message: currentMessage) }
                if model.embeddedAIEnabled {
                    actionSection
                    replySection
                    if !assistanceErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(assistanceErrors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Retry AI Assistance") { retryID = UUID() }
                                .controlSize(.small)
                                .disabled(isLoading)
                        }
                    }
                }
                if threadMessages.count > 1 || isRemote { threadSection }
                Divider()
                HStack(spacing: 12) {
                    Button { model.compose(replyTo: currentMessage) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    Button { model.compose(replyTo: currentMessage, replyAll: true) } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    Button { model.compose(replyTo: currentMessage, forward: true) } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Spacer()
                    Text(isRemote ? "Cached on this Mac · Mail actions require confirmation" : "Demo mailbox · Stored on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: requestID) {
            let task = Task { await loadAssistance() }
            assistanceTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onChange(of: message.id) { _, _ in
            showOriginal = !model.embeddedAIEnabled
            showHTML = false
            originalVisibilityWasChosen = false
            showSources = false
        }
        .onDisappear { assistanceTask?.cancel() }
        .accessibilityIdentifier("messageReader")
    }

    private var messageHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(account?.address.email ?? "Account unavailable", systemImage: isRemote ? "envelope" : "tray")
                    .lineLimit(1).textSelection(.enabled)
                Spacer(minLength: 8)
                Label(isRemote ? (isReadOnly ? "Read-only account" : "Connected account") : "Demo account", systemImage: isRemote ? "envelope" : "externaldrive")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("readerAccountIdentity")
            Text(currentMessage.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 12) {
                Text(String(currentMessage.from.name.prefix(1)))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.floraAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.floraAccent.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentMessage.from.name).fontWeight(.semibold)
                    Text(currentMessage.from.email).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("To: " + currentMessage.to.map { $0.email }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !currentMessage.cc.isEmpty {
                        Text("Cc: " + currentMessage.cc.map(\.email).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Text(currentMessage.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                categoryMenu
                if currentMessage.isFlagged {
                    Label("Flagged", systemImage: "flag.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Menu {
                    Button(currentMessage.isRead ? "Mark as Unread" : "Mark as Read") {
                        perform(.markRead(messageIDs: [message.id], isRead: !currentMessage.isRead),
                                explanation: currentMessage.isRead ? "Marked message as unread." : "Marked message as read.")
                    }
                    Button(currentMessage.isFlagged ? "Remove Flag" : "Flag Message") {
                        perform(.flag(messageIDs: [message.id], isFlagged: !currentMessage.isFlagged),
                                explanation: currentMessage.isFlagged ? "Removed message flag." : "Flagged message.")
                    }
                    Divider()
                    Button("Archive") {
                        perform(.archive(messageIDs: [message.id]), explanation: "Archived “\(currentMessage.subject)”.")
                    }
                    .disabled(currentMessage.folder == .archive)
                    Button("Move to Trash") {
                        perform(.move(messageIDs: [message.id], folder: .trash), explanation: "Moved “\(currentMessage.subject)” to Trash.")
                    }
                    .disabled(currentMessage.folder == .trash)
                    Button("Move to Inbox") {
                        perform(.move(messageIDs: [message.id], folder: .inbox), explanation: "Moved “\(currentMessage.subject)” to Inbox.")
                    }
                    .disabled(currentMessage.folder == .inbox)
                    if isRemote {
                        Menu("Move to Folder") {
                            ForEach(model.state.remoteFolders.filter { folder in
                                folder.accountID == currentMessage.accountID &&
                                !(account?.providerType == .gmail && (folder.role == .sent || folder.role == .drafts))
                            }) { folder in
                                Button(folder.name) { model.previewMove(currentMessage, to: folder) }
                            }
                        }
                    }
                } label: {
                    Label("Message Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isReadOnly)
                .help(isReadOnly ? "Enable mailbox actions in Accounts settings. Local categories remain available." : "Preview a message action")
            }
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("Uncategorized") {
                perform(.classify(messageID: message.id, categoryID: nil), explanation: "Removed local category from “\(currentMessage.subject)”.")
            }
            Divider()
            ForEach(model.state.categories) { category in
                Button(category.name) {
                    perform(.classify(messageID: message.id, categoryID: category.id), explanation: "Set local category to \(category.name) for “\(currentMessage.subject)”.")
                }
            }
        } label: {
            Label(model.state.categories.first(where: { $0.id == currentMessage.categoryID })?.name ?? "Uncategorized", systemImage: "tag")
                .font(.caption)
        }
        .fixedSize()
        .help("Change this message’s category on this Mac")
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("At a glance", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                if let summary {
                    Text("\(summary.provider) · Generated")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                else { Text(model.aiLabel).font(.caption2).foregroundStyle(.secondary) }
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loadingStage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel AI") { cancelAssistance() }.controlSize(.small)
                }
                .accessibilityIdentifier("aiProcessing")
            }
            if let summary {
                Text(summary.headline).font(.body.weight(.medium)).textSelection(.enabled)
                ForEach(summary.facts) { fact in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(fact.text, systemImage: "smallcircle.filled.circle")
                            .labelStyle(.titleAndIcon)
                            .textSelection(.enabled)
                        if showSources {
                            Text("“\(fact.sourceQuote)”")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.leading, 22).textSelection(.enabled)
                            Button("View Source Email") {
                                if fact.sourceMessageID != message.id { model.openMessage(fact.sourceMessageID) }
                                showOriginal = true
                            }
                            .buttonStyle(.link).font(.caption).padding(.leading, 22)
                        }
                    }
                }
                if !summary.facts.isEmpty {
                    Button(showSources ? "Hide Supporting Quotes" : "Show Supporting Quotes") {
                        showSources.toggle()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            } else if let summaryError {
                Label(summaryUnavailable ? "Local AI Unavailable" : "Summary unavailable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(summaryError).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Retry Summary") { retryID = UUID() }.controlSize(.small)
                        .disabled(isLoading)
                    if model.state.preferences.aiMode == .local {
                        SettingsLink { Text("Configure Local AI") }.controlSize(.small)
                    }
                }
            }
            if wasCancelled {
                HStack {
                    Text("AI request cancelled. Your original email is available.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry AI") { retryID = UUID() }.controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.floraAccent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("aiSummary")
    }

    @ViewBuilder
    private var classificationSection: some View {
        if let suggestion = classification,
           let category = model.state.categories.first(where: { $0.id == suggestion.categoryID }),
           (model.state.classifications.contains(suggestion) || currentMessage.categoryID == suggestion.categoryID),
           !ignoredClassification {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Suggested category: \(category.name)", systemImage: "tag")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if currentMessage.categoryID == category.id {
                        Label("Accepted", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Color.floraAccent)
                    }
                }
                Text(suggestion.explanation).font(.callout).foregroundStyle(.secondary)
                if let learned = model.learnedCategory(for: currentMessage), learned.classification.id == suggestion.id {
                    Text("Based on \(learned.supportCount) confirmed choices in this account").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Supporting choices") {
                        ForEach(learned.supportingMessageIDs, id: \.self) { id in
                            if let source = model.state.messages.first(where: { $0.id == id }) {
                                Button(source.subject) { model.openMessage(id) }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }.font(.caption)
                } else {
                    Text("\(model.state.preferences.aiMode == .local ? "Model" : "Demo") confidence: \(suggestion.confidence, format: .percent.precision(.fractionLength(0)))")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("The model’s own estimate; this is a suggestion for your review.")
                }
                HStack(spacing: 10) {
                    if currentMessage.categoryID != category.id {
                        Button("Accept \(category.name)") { _ = model.acceptClassification(suggestion) }
                            .accessibilityIdentifier("acceptClassification")
                            .disabled(!model.canAcceptAISuggestions)
                        Button("Ignore") { ignoredClassification = true; model.recordResearch(.aiRejected) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Text(model.canAcceptAISuggestions ? "Local category only · Server folders unchanged" : "Level 1 previews only · Change assistance level to accept AI suggestions")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    originalVisibilityWasChosen = true
                    showOriginal.toggle()
                    if showOriginal { model.recordResearch(.originalShown) }
                } label: {
                    Label(showOriginal || !model.embeddedAIEnabled ? "Original Email" : "Show Original Email",
                          systemImage: showOriginal || !model.embeddedAIEnabled ? "chevron.down" : "chevron.right")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .disabled(!model.embeddedAIEnabled)
                .accessibilityIdentifier("showOriginalEmail")
                Spacer()
                Text(currentMessage.htmlBody == nil ? "Original content" : "Safe text from original HTML").font(.caption).foregroundStyle(.secondary)
            }
            if showOriginal || !model.embeddedAIEnabled {
                ForEach(currentMessage.contentWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                }
                if let html = currentMessage.htmlBody {
                    Toggle("Formatted HTML", isOn: $showHTML).toggleStyle(.switch).controlSize(.small)
                    if showHTML {
                        let inline = Dictionary(currentMessage.attachments.compactMap { attachment -> (String, Data)? in
                            guard let cid = attachment.contentID, let image = model.accountController.imagePreviews[attachment.id] else { return nil }
                            return (cid, image)
                        }, uniquingKeysWith: { first, _ in first })
                        SafeHTMLView(html: html, inlineImages: inline).frame(minHeight: 300, idealHeight: 450, maxHeight: 600)
                        Text("Scripts, links and remote resources are blocked. Download an inline image and select Preview Image to include it.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(currentMessage.body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("originalMessageBody")
                if let html = currentMessage.htmlBody {
                    Text("The plain-text original stays available. Scripts and remote images are blocked in formatted HTML.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Show HTML Source") {
                        // Text renders markup literally; this disclosure never
                        // creates a browser or interprets email HTML.
                        Text(html)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("originalHTMLSource")
                }
                if !currentMessage.attachments.isEmpty { attachmentSection }
            }
        }
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attachments").font(.subheadline.weight(.medium))
            ForEach(currentMessage.attachments) { attachment in
                attachmentRow(attachment)
            }
            if !isRemote {
                Text("Demo attachment metadata; files are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Attachments download only when requested and remain in Flora’s local storage.")
                    .font(.caption).foregroundStyle(.secondary)
                if !canDownloadAttachments {
                    HStack {
                        Text("Reconnect this account to download attachments.")
                            .font(.caption).foregroundStyle(.secondary)
                        SettingsLink { Text("Accounts Settings") }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.top, 4)
        .accessibilityIdentifier("messageAttachments")
    }

    private func attachmentRow(_ attachment: MailAttachment) -> some View {
        let downloading = model.accountController.downloading.contains(attachment.id)
        let downloaded = attachment.downloadState == .downloaded && attachment.localRelativePath != nil
        let error = model.accountController.attachmentErrors[attachment.id]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "paperclip").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name).font(.callout).textSelection(.enabled)
                    Text(attachment.mimeType + " · " + ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) + (attachment.isInline ? " · Inline" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if isRemote {
                        Text(downloading ? "Downloading…" : downloaded ? "Downloaded on this Mac" : "Not downloaded")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isRemote {
                    if downloading {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.accountController.cancelDownload(attachment.id) }
                            .controlSize(.small)
                            .accessibilityLabel("Cancel download of \(attachment.name)")
                    } else {
                        if downloaded {
                            if attachment.mimeType.lowercased().hasPrefix("image/") {
                                Button("Preview Image") { Task { await model.accountController.previewImage(attachment) } }.controlSize(.small)
                            }
                            Button("Show in Finder") {
                                Task { await model.accountController.reveal(attachment) }
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Show \(attachment.name) in Finder")
                        }
                        if !downloaded || error != nil {
                            Button(error == nil ? "Download" : "Retry Download") {
                                model.accountController.download(attachment, message: currentMessage)
                            }
                            .controlSize(.small)
                            .disabled(!canDownloadAttachments || model.accountController.connecting)
                            .accessibilityLabel("Download \(attachment.name)")
                        }
                    }
                }
            }
            if let png = model.accountController.imagePreviews[attachment.id], let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 450, maxHeight: 280).accessibilityLabel(attachment.name)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionSection: some View {
        if !actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Suggested next steps").font(.headline)
                    Spacer()
                    generatedLabel
                }
                ForEach(actionItems) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(item.title, systemImage: "checklist")
                        if !item.sourceQuote.isEmpty {
                            Text("Source: “\(item.sourceQuote)”")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Button("Draft a Reply") { model.compose(replyTo: currentMessage) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var replySection: some View {
        if !suggestedReplies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Quick reply ideas").font(.headline)
                    Spacer()
                    generatedLabel
                }
                Text("Choose an idea to review and edit in the composer.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(suggestedReplies.prefix(3)) { reply in
                    Button {
                        model.compose(replyTo: currentMessage, suggestedText: reply.text)
                    } label: {
                        HStack(alignment: .top) {
                            Text(reply.text).multilineTextAlignment(.leading)
                            Spacer(minLength: 12)
                            Image(systemName: "square.and.pencil").accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.floraAccent)
                    .padding(.vertical, 5)
                    .help("Open this suggestion in the composer")
                    .disabled(!model.canAcceptAISuggestions)
                }
            }
        }
    }

    private var threadSection: some View {
        DisclosureGroup("\(isRemote ? "Cached conversation" : "Conversation") · \(threadMessages.count) messages") {
            VStack(alignment: .leading, spacing: 8) {
                if isRemote {
                    HStack {
                        if model.accountController.loadingThreads.contains(currentMessage.id) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { model.accountController.cancelConversation(currentMessage.id) }
                        } else {
                            Button("Load Full Conversation") { model.accountController.loadConversation(currentMessage) }.disabled(!canDownloadAttachments)
                        }
                        Text("Up to 500 messages; cached messages stay available offline.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.accountController.threadErrors[currentMessage.id] { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(threadMessages) { related in
                    Button { model.openMessage(related.id) } label: {
                        HStack {
                            Text(related.from.name).fontWeight(related.id == message.id ? .semibold : .regular)
                            Text(related.subject).lineLimit(1)
                            Spacer()
                            Text(related.date, format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .disabled(related.id == message.id)
                    .padding(.vertical, 3)
                }
            }
            .padding(.top, 8)
        }
    }

    private var generatedLabel: some View {
        Text("\(model.aiLabel) · Generated")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func perform(_ type: ActionType, explanation: String) {
        if model.perform(ProposedAction(type: type, explanation: explanation)) {
            switch type {
            case .archive, .move: model.selectedMessageID = nil
            default: break
            }
        }
    }

    private func loadAssistance() async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        activeRequestID = token
        activeSourceIdentity = requestID
        summary = nil
        classification = nil
        actionItems = []
        suggestedReplies = []
        summaryError = nil
        summaryUnavailable = false
        assistanceErrors = []
        ignoredClassification = false
        wasCancelled = false
        guard model.embeddedAIEnabled else { isLoading = false; showOriginal = true; return }
        isLoading = true
        loadingStage = "Preparing summary…"
        if model.state.preferences.aiMode == .local && !originalVisibilityWasChosen {
            showOriginal = true
        }
        let source = currentMessage
        do {
            let result = try await model.summary(for: source)
            guard requestIsCurrent(token) else { return }
            summary = result
        } catch {
            guard requestIsCurrent(token) else { return }
            summaryError = error.localizedDescription
            showOriginal = true
            if isUnavailable(error) {
                summaryUnavailable = true
                isLoading = false
                return
            }
        }
        if source.categoryID == nil {
            loadingStage = "Checking available categories…"
            do {
                let result = try await model.classification(for: source)
                guard requestIsCurrent(token) else { return }
                // A prediction is actionable only while the executor retains this
                // exact proposal. Manual assignments take precedence immediately.
                classification = result.flatMap { model.state.classifications.contains($0) ? $0 : nil }
            } catch {
                guard requestIsCurrent(token) else { return }
                assistanceErrors.append("Classification unavailable: \(error.localizedDescription)")
            }
        }
        loadingStage = "Finding possible action items…"
        do {
            let result = try await model.actions(for: source)
            guard requestIsCurrent(token) else { return }
            actionItems = result
        } catch {
            guard requestIsCurrent(token) else { return }
            assistanceErrors.append("Action suggestions unavailable: \(error.localizedDescription)")
        }
        loadingStage = "Preparing reply ideas…"
        do {
            let result = try await model.replies(for: source)
            guard requestIsCurrent(token) else { return }
            suggestedReplies = result
        } catch {
            guard requestIsCurrent(token) else { return }
            assistanceErrors.append("Reply ideas unavailable: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func requestIsCurrent(_ token: UUID) -> Bool {
        !Task.isCancelled && activeRequestID == token && activeSourceIdentity == requestID
    }

    private func isUnavailable(_ error: Error) -> Bool {
        guard let aiError = error as? AIError else { return false }
        switch aiError {
        case .runtimeUnavailable, .modelUnavailable, .unsupportedRuntime, .invalidConfiguration: return true
        default: return false
        }
    }

    private func cancelAssistance() {
        assistanceTask?.cancel()
        activeRequestID = UUID()
        isLoading = false
        wasCancelled = true
        showOriginal = true
    }
}
