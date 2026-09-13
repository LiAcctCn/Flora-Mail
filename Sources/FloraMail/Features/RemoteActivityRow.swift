import SwiftUI
import FloraCore

struct RemoteActivityRow: View {
    @Environment(AppModel.self) private var model
    let record: RemoteActionRecord
    @State private var undoPreview: RemoteMailProposal?
    @State private var resolving = false
    @State private var error: String?
    private var status: String {
        switch record.status {
        case .prepared: "In progress"
        case .completed: record.resolution == nil ? "Confirmed by mail service" : "Confirmed by you"
        case .failed: record.resolution == nil ? "Not completed" : "Confirmed by you: not applied"
        case .outcomeUnknown: "Outcome unknown · Review required"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(record.proposal.explanation).font(.callout)
            Text(model.state.accounts.first { $0.id == record.proposal.accountID }?.address.email ?? "Account unavailable").font(.caption).foregroundStyle(.secondary)
            Text("\(status) · \(record.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            if let message = record.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if record.canUndo {
                    Button("Preview Undo") {
                        do { undoPreview = try model.accountController.proposeUndo(recordID: record.id) }
                        catch { self.error = error.localizedDescription }
                    }.controlSize(.small)
                }
                if record.status == .outcomeUnknown {
                    Button("Review Outcome…") { resolving = true }.controlSize(.small)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 7)
        .sheet(item: $undoPreview) { proposal in RemoteActionPreview(proposal: proposal).environment(model) }
        .sheet(isPresented: $resolving) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Check the account before continuing").font(.title3.weight(.semibold))
                Text("Flora lost confirmation of this operation. Check the message, Drafts or Sent in the provider’s app or website. Do not retry a send until you have verified that it was not delivered.")
                Text(record.proposal.explanation).font(.callout)
                Text("Your choice records a manual resolution. It does not contact the mail service or reverse an action.").font(.caption).foregroundStyle(.secondary)
                Button("I checked: the action was applied") { resolve(.confirmedApplied) }
                Button("I checked: the action was not applied") { resolve(.confirmedNotApplied) }
                Button("Keep unresolved") { resolving = false }.keyboardShortcut(.cancelAction)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(24).frame(width: 530)
        }
    }
    private func resolve(_ resolution: RemoteOutcomeResolution) {
        do { try model.accountController.resolveUnknown(recordID: record.id, resolution: resolution); resolving = false }
        catch { self.error = error.localizedDescription }
    }
}
