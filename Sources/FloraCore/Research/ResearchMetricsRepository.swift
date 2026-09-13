import Foundation

@MainActor
public protocol ResearchMetricsRepository {
    func load() throws -> ResearchMetricsSnapshot?
    func save(_ snapshot: ResearchMetricsSnapshot) throws
    func clear() throws
}

/// A bounded local file distinct from mail, settings and credentials. No network
/// dependency or automatic upload/export. Unknown JSON fields are rejected.
@MainActor
public final class JSONResearchMetricsRepository: ResearchMetricsRepository {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ResearchMetricsSnapshot? {
        try validateLocation()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= ResearchMetricsLimits.maximumFileBytes else {
                throw ResearchMetricsError.tooLarge
            }
            let data = try Data(contentsOf: url)
            guard data.count <= ResearchMetricsLimits.maximumFileBytes else { throw ResearchMetricsError.tooLarge }
            try ResearchMetricsValidation.validateJSON(data)
            let snapshot = try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: data)
            try ResearchMetricsValidation.validate(snapshot)
            return snapshot
        } catch let error as ResearchMetricsError { throw error }
        catch { throw ResearchMetricsError.unreadable }
    }

    public func save(_ snapshot: ResearchMetricsSnapshot) throws {
        try validateLocation()
        let data = try ResearchMetricsValidation.encode(snapshot)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw ResearchMetricsError.storageUnavailable }
    }

    public func clear() throws {
        try validateLocation()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw ResearchMetricsError.storageUnavailable }
    }

    private func validateLocation() throws {
        guard url.isFileURL, !url.hasDirectoryPath else { throw ResearchMetricsError.storageUnavailable }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw ResearchMetricsError.storageUnavailable
        }
    }
}

@MainActor
public final class MemoryResearchMetricsRepository: ResearchMetricsRepository {
    public private(set) var snapshot: ResearchMetricsSnapshot?
    public init(snapshot: ResearchMetricsSnapshot? = nil) { self.snapshot = snapshot }
    public func load() throws -> ResearchMetricsSnapshot? { snapshot }
    public func save(_ snapshot: ResearchMetricsSnapshot) throws {
        try ResearchMetricsValidation.validate(snapshot); self.snapshot = snapshot
    }
    public func clear() throws { snapshot = nil }
}

enum ResearchMetricsValidation {
    static func validate(_ snapshot: ResearchMetricsSnapshot) throws {
        guard snapshot.schemaVersion == 1 else { throw ResearchMetricsError.unsupportedVersion }
        guard snapshot.droppedEventCount >= 0, snapshot.droppedEventCount <= Int.max - ResearchMetricsLimits.maximumEvents,
              snapshot.events.count <= ResearchMetricsLimits.maximumEvents else {
            throw ResearchMetricsError.tooLarge
        }
        var previousSequence = -1
        for event in snapshot.events {
            guard event.sequence > previousSequence, event.sequence < Int.max - ResearchMetricsLimits.maximumEvents,
                  (0...ResearchMetricsLimits.maximumDurationMilliseconds).contains(event.sessionElapsedMilliseconds) else {
                throw ResearchMetricsError.invalidData
            }
            previousSequence = event.sequence
            switch event.kind {
            case .sessionStarted, .modeChanged:
                guard event.interaction == nil, event.task == nil, event.durationMilliseconds == nil else { throw ResearchMetricsError.invalidData }
            case .interaction:
                guard event.interaction != nil, event.durationMilliseconds == nil else { throw ResearchMetricsError.invalidData }
            case .taskStarted:
                guard event.task != nil, event.interaction == nil, event.durationMilliseconds == nil else { throw ResearchMetricsError.invalidData }
            case .taskCompleted, .taskAbandoned:
                guard event.task != nil, event.interaction == nil, let duration = event.durationMilliseconds,
                      (0...ResearchMetricsLimits.maximumDurationMilliseconds).contains(duration) else { throw ResearchMetricsError.invalidData }
            }
        }
    }

    static func encode(_ snapshot: ResearchMetricsSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= ResearchMetricsLimits.maximumFileBytes else { throw ResearchMetricsError.tooLarge }
        return data
    }

    static func validateJSON(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "droppedEventCount", "events"],
              let events = root["events"] as? [[String: Any]] else { throw ResearchMetricsError.invalidData }
        let allowed: Set<String> = ["sequence", "sessionID", "mode", "kind", "sessionElapsedMilliseconds", "interaction", "task", "durationMilliseconds"]
        let required: Set<String> = ["sequence", "sessionID", "mode", "kind", "sessionElapsedMilliseconds"]
        for event in events {
            guard Set(event.keys).isSubset(of: allowed), required.isSubset(of: Set(event.keys)) else { throw ResearchMetricsError.invalidData }
        }
    }
}
