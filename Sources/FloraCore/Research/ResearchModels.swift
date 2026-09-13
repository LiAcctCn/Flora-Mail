import Foundation

public enum ResearchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case traditional, chatFirst, hybrid
    public var id: String { rawValue }
    public var label: String {
        switch self { case .traditional: "Traditional"; case .chatFirst: "Chat First"; case .hybrid: "Flora Hybrid" }
    }
}

/// Fixed tasks only: task names cannot carry participant notes or mail contents.
public enum ResearchTask: String, Codable, CaseIterable, Sendable, Identifiable {
    case reviewBriefing, findMessage, readMessage, classifyMessage, archiveAndUndo, composeAndRewrite, askAssistant
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .reviewBriefing: "Review the daily briefing"
        case .findMessage: "Find a message"
        case .readMessage: "Read and compare a message"
        case .classifyMessage: "Review a category suggestion"
        case .archiveAndUndo: "Archive and undo"
        case .composeAndRewrite: "Compose and review a rewrite"
        case .askAssistant: "Ask the mail assistant"
        }
    }
}

/// The recording API accepts this enum, never an arbitrary name, error string,
/// query, URL, account/message ID, source text, provider payload or user metadata.
public enum ResearchInteraction: String, Codable, CaseIterable, Sendable {
    case messageOpened, navigation, search, compose, actionExecuted
    case aiRequested, aiAccepted, aiRejected, correction, undo, error, errorRecovery
    case originalShown
}

public enum ResearchMetricKind: String, Codable, Sendable {
    case sessionStarted, modeChanged, interaction, taskStarted, taskCompleted, taskAbandoned
}

public struct ResearchMetric: Codable, Equatable, Sendable {
    public let sequence: Int
    public let sessionID: UUID
    public let mode: ResearchMode
    public let kind: ResearchMetricKind
    public let sessionElapsedMilliseconds: Int
    public let interaction: ResearchInteraction?
    public let task: ResearchTask?
    public let durationMilliseconds: Int?

    init(sequence: Int, sessionID: UUID, mode: ResearchMode, kind: ResearchMetricKind,
         sessionElapsedMilliseconds: Int, interaction: ResearchInteraction? = nil,
         task: ResearchTask? = nil, durationMilliseconds: Int? = nil) {
        self.sequence = sequence; self.sessionID = sessionID; self.mode = mode; self.kind = kind
        self.sessionElapsedMilliseconds = sessionElapsedMilliseconds; self.interaction = interaction
        self.task = task; self.durationMilliseconds = durationMilliseconds
    }
}

public struct ResearchMetricsSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var droppedEventCount: Int
    public var events: [ResearchMetric]
    public init(schemaVersion: Int = 1, droppedEventCount: Int = 0, events: [ResearchMetric] = []) {
        self.schemaVersion = schemaVersion; self.droppedEventCount = droppedEventCount; self.events = events
    }
    public var completedTaskCount: Int { events.filter { $0.kind == .taskCompleted }.count }
    public var abandonedTaskCount: Int { events.filter { $0.kind == .taskAbandoned }.count }
    public func count(_ interaction: ResearchInteraction) -> Int { events.filter { $0.interaction == interaction }.count }
}

public enum ResearchMetricsLimits {
    public static let maximumEvents = 1_000
    public static let maximumFileBytes = 1_048_576
    /// Timers are intended for short user-started tasks; long intervals are capped.
    public static let maximumDurationMilliseconds = 86_400_000
}

public enum ResearchMetricsError: LocalizedError, Equatable {
    case unreadable, unsupportedVersion, invalidData, tooLarge, storageUnavailable, invalidClock
    public var errorDescription: String? {
        switch self {
        case .unreadable: "Research metrics could not be read. Existing data was preserved. Clear the metrics to start again."
        case .unsupportedVersion: "This research metrics file uses an unsupported version. Existing data was preserved."
        case .invalidData: "Research metrics did not match the content-free format. Existing data was preserved."
        case .tooLarge: "Research metrics exceeded the local storage limit. Existing data was preserved."
        case .storageUnavailable: "Research metrics could not be saved locally. Recording has stopped; mail remains usable."
        case .invalidClock: "The task timer was unavailable. Recording has stopped; mail remains usable."
        }
    }
}
