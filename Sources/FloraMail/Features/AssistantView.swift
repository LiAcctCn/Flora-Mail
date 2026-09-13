import SwiftUI
import FloraCore

/// Optional, scoped access to the same cached mail. It has no execution controls.
struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var query = ""
    @State private var result: MailAssistantResult?
    @State private var busy = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    @State private var revision = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Mail assistant", systemImage: "sparkle.magnifyingglass").font(.title2.weight(.semibold))
                Spacer()
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            Text("Ask about cached mail in \(model.intelligenceScopeLabel). Answers cite original messages. Calendar and Contacts are not included in model requests.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("What changed about the project meeting?", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button(model.aiEnabled ? "Ask" : "Find", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                if busy { Button("Cancel", action: cancel) }
            }
            HStack {
                ForEach(["Reply", "Assignment deadline", "Project meeting"], id: \.self) { prompt in
                    Button(prompt) { query = prompt; search() }.controlSize(.small).disabled(busy)
                }
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("Searching scoped mail…").font(.caption) } }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result {
                        if let notice = result.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if let answer = result.answer {
                            Label("\(answer.provider) · Generated answer", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(answer.claims.enumerated()), id: \.offset) { _, claim in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(claim.text).textSelection(.enabled)
                                    ForEach(Array(claim.citations.enumerated()), id: \.offset) { _, citation in
                                        Button {
                                            model.openMessage(citation.messageID)
                                            if !embedded { dismiss() }
                                        } label: {
                                            Label("“\(citation.quote)”", systemImage: "doc.text.magnifyingglass")
                                                .font(.caption).multilineTextAlignment(.leading)
                                        }.buttonStyle(.link)
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        if result.sources.isEmpty {
                            EmptyMailView(title: "No matching messages", message: "Try a sender, subject or topic in this account scope.", icon: "magnifyingglass")
                        } else {
                            Text("Original sources").font(.headline)
                            ForEach(result.sources, id: \.messageID) { source in
                                Button {
                                    model.openMessage(source.messageID)
                                    if !embedded { dismiss() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(source.subject).font(.headline)
                                        Text(source.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Read-only · Model output is a suggestion. Verify claims in the cited original.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
            .frame(minWidth: 550, idealWidth: 680, maxWidth: .infinity, minHeight: 500, idealHeight: 620, maxHeight: .infinity)
            .onDisappear { cancel() }
            .onChange(of: model.aiRequestIdentity) { _, _ in cancel(); result = nil }
    }

    private func cancel() {
        revision = UUID(); request?.cancel(); busy = false
    }
    private func search() {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let token = UUID(); revision = token
        busy = true; result = nil; error = nil
        request = Task { @MainActor in
            do {
                let value = try await model.assistantAnswer(text)
                try Task.checkCancellation()
                guard revision == token else { return }
                result = value
            } catch is CancellationError { return } catch {
                guard revision == token else { return }
                self.error = error.localizedDescription
            }
            if revision == token { busy = false }
        }
    }
}
