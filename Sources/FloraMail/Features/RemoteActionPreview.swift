import SwiftUI
import FloraCore

/// Human confirmation is bound to an immutable proposal and its source version.
struct RemoteActionPreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let proposal: RemoteMailProposal
    var onCompleted: (() -> Void)?
    @State private var executing = false
    @State private var failure: String?

    private var draft: Draft? {
        switch proposal.action {
        case .sendDraft(let id), .syncDraft(let id): model.state.drafts.first { $0.id == id }
        default: nil
        }
    }
    private var messageIDs: [UUID] {
        switch proposal.action {
        case .markRead(let ids, _), .flag(let ids, _), .archive(let ids), .move(let ids, _): ids
        default: []
        }
    }
    private var title: String {
        switch proposal.action {
        case .sendDraft: "Send this message?"
        case .syncDraft: "Save this draft to your mail account?"
        case .archive: "Archive these messages?"
        case .move: "Move these messages?"
        case .markRead: "Change read status?"
        case .flag: "Change message flags?"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "envelope").font(.title3.weight(.semibold))
            Text(model.state.accounts.first { $0.id == proposal.accountID }?.address.email ?? "Account unavailable").font(.headline)
            Text("This action applies to your real mail account. AI suggestions do not execute without your confirmation.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let draft {
                        LabeledContent("To", value: draft.to)
                        if !draft.cc.isEmpty { LabeledContent("Cc", value: draft.cc) }
                        if !draft.bcc.isEmpty { LabeledContent("Bcc", value: draft.bcc) }
                        LabeledContent("Subject", value: draft.subject)
                        ForEach(draft.attachments) { file in
                            Label("\(file.name) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))", systemImage: "paperclip").font(.caption)
                        }
                        Divider()
                        Text(draft.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(messageIDs, id: \.self) { id in
                            if let message = model.state.messages.first(where: { $0.id == id && $0.accountID == proposal.accountID }) {
                                Text(message.subject).font(.headline)
                                Text(message.from.email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if case .move(_, let folder) = proposal.action { LabeledContent("Destination", value: folder.name) }
                        if case .markRead(_, let read) = proposal.action { Text(read ? "Mark as read" : "Mark as unread") }
                        if case .flag(_, let flag) = proposal.action { Text(flag ? "Add flag" : "Remove flag") }
                    }
                }
            }.frame(minHeight: 150, maxHeight: 300)
            Text("Remote actions are recorded in Activity. Send cannot be undone. Read and flag changes can offer a confirmed Undo when still valid.").font(.caption).foregroundStyle(.secondary)
            if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            if executing { HStack { ProgressView().controlSize(.small); Text("Waiting for the mail service…").font(.caption) } }
            HStack {
                Button(failure == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(executing)
                Spacer()
                Button("Confirm") {
                    executing = true
                    Task { @MainActor in
                        failure = await model.executeRemote(proposal)
                        executing = false
                        if failure == nil { dismiss(); onCompleted?() }
                    }
                }.buttonStyle(.borderedProminent).disabled(executing || failure != nil)
                // A failed proposal is never automatically retried. New proposals
                // go through current-state checks; uncertain sends need recovery.
            }
        }.padding(24).frame(width: 610)
        .interactiveDismissDisabled(executing)
        .accessibilityIdentifier("remoteActionPreview")
    }
}
