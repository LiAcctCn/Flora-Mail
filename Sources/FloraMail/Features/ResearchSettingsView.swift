import SwiftUI
import UniformTypeIdentifiers
import FloraCore

struct ResearchSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var task: ResearchTask = .reviewBriefing
    @State private var exportDocument: ResearchMetricsDocument?
    @State private var exporting = false
    @State private var clearing = false
    @State private var exportNotice: String?

    var body: some View {
        Section("Research interaction mode") {
            Picker("Interface", selection: Binding(get: { model.state.preferences.researchMode }, set: { model.setResearchMode($0) })) {
                ForEach(ResearchMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            Text("Traditional hides AI assistance. Chat First opens the read-only assistant as the home view. Flora Hybrid combines the mail GUI, embedded assistance and optional assistant. Mail controls remain available in every mode.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Optional research metrics") {
            Toggle("Record content-free interactions on this Mac", isOn: Binding(get: { model.research.isEnabled }, set: { model.setResearchMetricsEnabled($0) }))
            Text("Off by default. Records fixed action types, counts, durations and interaction mode. Does not record messages, names, addresses, account IDs, queries or participant identities. Nothing is uploaded. This is instrumentation, not study results.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Recording", value: model.research.isEnabled ? "On · Local only" : "Off")
            if model.researchOptOutSavePending {
                Text("Recording is off for this session. Save the opt-out before restarting Flora Mail.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry Saving Opt-Out") { model.setResearchMetricsEnabled(false) }
            }
            if !model.research.isEnabled, model.research.errorMessage != nil {
                Button("Retry Recording") { model.setResearchMetricsEnabled(true) }
                Text("Retries local recording and keeps previously saved metrics.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Retained events", value: "\(model.research.eventCount) / 1,000")
            LabeledContent("User-marked task completions", value: "\(model.research.completedTaskCount)")
            if model.research.droppedEventCount > 0 {
                Text("\(model.research.droppedEventCount) older events were removed by the retention limit. Counts describe retained events only.").font(.caption).foregroundStyle(.secondary)
            }
            if let active = model.research.activeTask {
                Text("Active task: \(active.label)").font(.callout)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Elapsed: \((model.research.elapsedTaskMilliseconds ?? 0) / 1_000) seconds").font(.caption).monospacedDigit()
                }
                HStack {
                    Button("Mark Task Complete") { model.research.completeTask() }
                    Button("Abandon Task") { model.research.abandonTask() }
                }
            } else {
                Picker("Task to time", selection: $task) {
                    ForEach(ResearchTask.allCases) { task in Text(task.label).tag(task) }
                }
                Button("Start Task Timer") { model.research.startTask(task) }.disabled(!model.research.isEnabled)
            }
            HStack {
                Button("Export Metrics…") {
                    do { exportDocument = ResearchMetricsDocument(data: try model.research.exportData()); exporting = true }
                    catch { exportNotice = error.localizedDescription }
                }
                Button("Clear Metrics…") { clearing = true }
            }
            if let error = model.research.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let exportNotice { Text(exportNotice).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Clear all recorded research metrics?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear Metrics", role: .destructive) { model.research.clear() }
        } message: { Text("This deletes only the local metrics file. Mail, drafts and categories are kept.") }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Flora-Research-Metrics") { result in
            switch result {
            case .success: exportNotice = "Metrics exported to the location you selected."
            case .failure(let error): exportNotice = error.localizedDescription
            }
        }
    }
}

private struct ResearchMetricsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
