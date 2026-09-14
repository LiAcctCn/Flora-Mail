import SwiftUI
import AppKit
import FloraCore

extension View {
    /// SwiftUI otherwise blocks Quit while a sheet is presented, before the
    /// application delegate can offer Save / Discard / Keep Editing.
    @ViewBuilder
    func useApplicationTerminationPolicy() -> some View {
        if #available(macOS 15.4, *) {
            presentationPreventsAppTermination(false)
        } else {
            self
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let draft = model.editorDraft else { return .terminateNow }
        if !model.editorIsDirty { return finishDraftTermination(.discard) }
        let alert = NSAlert()
        alert.messageText = "Save your draft before quitting?"
        alert.informativeText = "Your current edits have not been saved."
        alert.addButton(withTitle: "Save Draft")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return finishDraftTermination(.save)
        case .alertSecondButtonReturn: return finishDraftTermination(.discard)
        default:
            model.restoreEditorAfterCancelledTermination(draft)
            return .terminateCancel
        }
    }

    /// Kept separate from NSAlert so tests exercise the same decision path,
    /// including the editor state available after an early sheet disappearance.
    @MainActor
    func finishDraftTermination(_ decision: EditorCloseDecision) -> NSApplication.TerminateReply {
        guard let model, let draft = model.editorDraft else { return .terminateNow }
        if model.finishEditorClose(draft, decision: decision) { return .terminateNow }
        let error = model.errorMessage ?? "The draft could not be closed safely. Your text is still available here."
        model.errorMessage = nil
        model.restoreEditorAfterCancelledTermination(draft, recoveryError: error)
        return .terminateCancel
    }
}

@main
struct FloraMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Flora Mail", id: "main") {
            AppShell().environment(model).tint(.floraAccent)
                .frame(minWidth: 1040, minHeight: 680)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { model.compose() }.keyboardShortcut("n").disabled(!model.canCompose)
            }
            CommandMenu("Message") {
                Button("Reply") { if let message = model.selectedMessage { model.compose(replyTo: message) } }
                    .keyboardShortcut("r").disabled(model.selectedMessage == nil)
                Button("Forward") { if let message = model.selectedMessage { model.compose(replyTo: message, forward: true) } }
                    .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.selectedMessage == nil)
                Divider()
                Button("Archive") { if let message = model.selectedMessage { model.archive(message) } }
                    .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!model.canMutateSelection)
                Button("Move to Trash") { if let message = model.selectedMessage { model.trash(message) } }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(!model.canMutateSelection)
                Button("Toggle Read / Unread") { if let message = model.selectedMessage { model.toggleRead(message) } }
                    .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!model.canMutateSelection)
                Divider()
                Button("Undo Last Mail Action") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .option]).disabled(!model.canUndo)
            }
            CommandGroup(after: .sidebar) {
                Button("Today") { model.navigate(.today) }.keyboardShortcut("1")
                Button("Inbox") { model.navigate(.folder(.inbox)) }.keyboardShortcut("2")
                Button("Activity") { model.showingHistory = true }
            }
        }
        Settings { SettingsView().environment(model).tint(.floraAccent) }
    }
}
