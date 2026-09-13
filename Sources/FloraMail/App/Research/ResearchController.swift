import Foundation
import Observation
import FloraCore

/// Presentation facade with no mail, AI or account dependencies. All event
/// entry points use fixed enums and storage failures never escape into mail flows.
@MainActor @Observable
final class ResearchController {
    private(set) var isEnabled = false
    private(set) var mode: ResearchMode = .hybrid
    private(set) var activeTask: ResearchTask?
    private(set) var eventCount = 0
    private(set) var completedTaskCount = 0
    private(set) var abandonedTaskCount = 0
    private(set) var droppedEventCount = 0
    private(set) var errorMessage: String?
    /// Ephemeral boundary for presentation bookkeeping; never exported.
    private(set) var recordingEpoch = UUID()
    var elapsedTaskMilliseconds: Int? { recorder?.elapsedTaskMilliseconds }
    private let repository: any ResearchMetricsRepository
    private let clock: any ResearchClock
    private var recorder: ResearchMetricsRecorder?
    private var requestedEnabled = false
    private var recordingFailed = false

    init(repository: any ResearchMetricsRepository, clock: any ResearchClock = SystemResearchClock()) {
        self.repository = repository; self.clock = clock
        do { recorder = try ResearchMetricsRecorder(repository: repository, clock: clock); refresh() }
        catch { show(error) }
    }

    func configure(mode: ResearchMode, enabled: Bool) {
        if self.mode != mode { recordingEpoch = UUID() }
        self.mode = mode; requestedEnabled = enabled
        if !enabled { recordingFailed = false }
        guard !recordingFailed, let recorder else { isEnabled = false; return }
        perform { try recorder.configure(mode: mode, enabled: enabled) }
        if recorder.isEnabled { errorMessage = nil }
    }
    /// Explicit user retry only. Reload the last committed file and retain its
    /// records; normal configure calls cannot silently resume after failure.
    func retryRecording(mode: ResearchMode) {
        guard !isEnabled else { configure(mode: mode, enabled: true); return }
        requestedEnabled = true
        do {
            let recovered = try ResearchMetricsRecorder(repository: repository, clock: clock)
            recorder = recovered
            recordingFailed = false
            if self.mode != mode { recordingEpoch = UUID() }
            self.mode = mode
            try recovered.configure(mode: mode, enabled: true)
            errorMessage = nil; refresh()
        } catch { recorder?.stopRecording(); show(error); refresh() }
    }
    func record(_ interaction: ResearchInteraction) { perform { try recorder?.record(interaction) } }
    func startTask(_ task: ResearchTask) { perform { try recorder?.startTask(task) } }
    func completeTask() { perform { try recorder?.completeTask() } }
    func abandonTask() { perform { try recorder?.abandonTask() } }

    func clear() {
        do {
            if let recorder { try recorder.clear() }
            else {
                try repository.clear()
                let recovered = try ResearchMetricsRecorder(repository: repository, clock: clock)
                self.recorder = recovered
                try recovered.configure(mode: mode, enabled: requestedEnabled)
            }
            errorMessage = nil; recordingFailed = false; recordingEpoch = UUID(); refresh()
        } catch { show(error); refresh() }
    }

    /// Returns only the typed export; native fileExporter owns the user-selected
    /// destination. Exporting does not enable recording or record an export event.
    func exportData() throws -> Data {
        guard let recorder else { throw ResearchMetricsError.unreadable }
        return try recorder.exportData()
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); refresh() }
        catch { recorder?.stopRecording(); show(error); refresh() }
    }
    private func show(_ error: any Error) {
        // Never surface a filesystem path or arbitrary provider error text.
        recordingFailed = true
        errorMessage = ((error as? ResearchMetricsError) ?? .storageUnavailable).localizedDescription
    }
    private func refresh() {
        guard let recorder else { isEnabled = false; activeTask = nil; return }
        if isEnabled != recorder.isEnabled || mode != recorder.mode { recordingEpoch = UUID() }
        isEnabled = recorder.isEnabled; mode = recorder.mode; activeTask = recorder.activeTask
        eventCount = recorder.snapshot.events.count
        completedTaskCount = recorder.snapshot.completedTaskCount
        abandonedTaskCount = recorder.snapshot.abandonedTaskCount
        droppedEventCount = recorder.snapshot.droppedEventCount
    }
}
