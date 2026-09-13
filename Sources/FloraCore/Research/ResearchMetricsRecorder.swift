import Foundation

@MainActor
public protocol ResearchClock {
    /// Monotonic elapsed time, never an exported wall-clock date.
    func now() -> TimeInterval
}

@MainActor
public struct SystemResearchClock: ResearchClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Opt-in and content-free. Bounded synchronous commits match the app's native
/// repository boundary and leave no queued callback that can record after opt-out.
@MainActor
public final class ResearchMetricsRecorder {
    public private(set) var snapshot: ResearchMetricsSnapshot
    public private(set) var isEnabled = false
    public private(set) var mode: ResearchMode = .hybrid
    public var activeTask: ResearchTask? { taskContext?.task }
    public var elapsedTaskMilliseconds: Int? {
        guard isEnabled, let taskContext else { return nil }
        let now = clock.now()
        guard now.isFinite, now >= 0 else { return nil }
        return milliseconds(now - taskContext.started)
    }
    private struct Session { let id: UUID; let started: TimeInterval }
    private struct TaskContext { let task: ResearchTask; let started: TimeInterval }
    private let repository: any ResearchMetricsRepository
    private let clock: any ResearchClock
    private let maximumEvents: Int
    private var session: Session?
    private var taskContext: TaskContext?

    public init(repository: any ResearchMetricsRepository, clock: any ResearchClock = SystemResearchClock(),
                maximumEvents: Int = ResearchMetricsLimits.maximumEvents) throws {
        self.repository = repository; self.clock = clock
        self.maximumEvents = max(1, min(maximumEvents, ResearchMetricsLimits.maximumEvents))
        snapshot = try repository.load() ?? ResearchMetricsSnapshot()
        try ResearchMetricsValidation.validate(snapshot)
    }

    public func configure(mode: ResearchMode, enabled: Bool) throws {
        guard enabled else {
            // Consent removal accepts no final event, timer result or mode event.
            // A task without a terminal marker remains explicitly incomplete.
            stopRecording(); self.mode = mode; return
        }
        let now = try validNow()
        guard isEnabled, let session else {
            let session = Session(id: UUID(), started: now)
            var candidate = snapshot
            append(.sessionStarted, mode: mode, session: session, now: now, to: &candidate)
            try commit(candidate)
            self.mode = mode; self.session = session; isEnabled = true
            return
        }
        guard self.mode != mode else { return }
        var candidate = snapshot
        if let taskContext {
            append(.taskAbandoned, mode: self.mode, session: session, now: now, task: taskContext.task,
                   duration: milliseconds(now - taskContext.started), to: &candidate)
        }
        append(.modeChanged, mode: mode, session: session, now: now, to: &candidate)
        try commit(candidate)
        self.mode = mode; taskContext = nil
    }

    public func record(_ interaction: ResearchInteraction) throws {
        guard isEnabled, let session else { return }
        let now = try validNow()
        var candidate = snapshot
        append(.interaction, mode: mode, session: session, now: now, interaction: interaction,
               task: taskContext?.task, to: &candidate)
        try commit(candidate)
    }

    public func startTask(_ task: ResearchTask) throws {
        guard isEnabled, let session else { return }
        let now = try validNow()
        var candidate = snapshot
        if let previous = taskContext {
            append(.taskAbandoned, mode: mode, session: session, now: now, task: previous.task,
                   duration: milliseconds(now - previous.started), to: &candidate)
        }
        append(.taskStarted, mode: mode, session: session, now: now, task: task, to: &candidate)
        try commit(candidate)
        taskContext = TaskContext(task: task, started: now)
    }

    public func completeTask() throws { try finishTask(kind: .taskCompleted) }
    public func abandonTask() throws { try finishTask(kind: .taskAbandoned) }

    public func stopRecording() { isEnabled = false; session = nil; taskContext = nil }

    public func clear() throws {
        do { try repository.clear() }
        catch { stopRecording(); throw ResearchMetricsError.storageUnavailable }
        snapshot = ResearchMetricsSnapshot(); taskContext = nil
        // Clearing while opted in keeps consent, but starts a fresh anonymous
        // session context. The cleared data remains empty until a new interaction.
        if isEnabled { session = Session(id: UUID(), started: try validNow()) }
        else { session = nil }
    }

    public func exportData() throws -> Data { try ResearchMetricsValidation.encode(snapshot) }

    private func finishTask(kind: ResearchMetricKind) throws {
        guard isEnabled, let session, let taskContext else { return }
        let now = try validNow()
        var candidate = snapshot
        append(kind, mode: mode, session: session, now: now, task: taskContext.task,
               duration: milliseconds(now - taskContext.started), to: &candidate)
        try commit(candidate)
        self.taskContext = nil
    }

    private func validNow() throws -> TimeInterval {
        let value = clock.now()
        guard value.isFinite, value >= 0 else { stopRecording(); throw ResearchMetricsError.invalidClock }
        return value
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        let cap = Double(ResearchMetricsLimits.maximumDurationMilliseconds)
        return Int(max(0, min(cap, seconds * 1_000)).rounded(.down))
    }

    private func append(_ kind: ResearchMetricKind, mode: ResearchMode, session: Session, now: TimeInterval,
                        interaction: ResearchInteraction? = nil, task: ResearchTask? = nil, duration: Int? = nil,
                        to candidate: inout ResearchMetricsSnapshot) {
        let sequence = (candidate.events.last?.sequence ?? -1) + 1
        candidate.events.append(ResearchMetric(sequence: sequence, sessionID: session.id, mode: mode, kind: kind,
                                               sessionElapsedMilliseconds: milliseconds(now - session.started),
                                               interaction: interaction, task: task, durationMilliseconds: duration))
        if candidate.events.count > maximumEvents {
            let excess = candidate.events.count - maximumEvents
            candidate.events.removeFirst(excess)
            candidate.droppedEventCount = min(Int.max - maximumEvents, candidate.droppedEventCount + excess)
        }
    }

    private func commit(_ candidate: ResearchMetricsSnapshot) throws {
        do { try repository.save(candidate); snapshot = candidate }
        catch {
            stopRecording()
            throw (error as? ResearchMetricsError) ?? ResearchMetricsError.storageUnavailable
        }
    }
}
