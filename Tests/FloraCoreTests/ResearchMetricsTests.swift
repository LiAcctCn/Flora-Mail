import Foundation
import Testing
@testable import FloraCore

@MainActor
private final class ResearchFixtureClock: ResearchClock {
    var value: TimeInterval = 100
    func now() -> TimeInterval { value }
}

@MainActor
private final class ResearchRepositorySpy: ResearchMetricsRepository {
    var snapshot: ResearchMetricsSnapshot?
    var saves = 0
    var clears = 0
    var failure = false
    func load() throws -> ResearchMetricsSnapshot? { snapshot }
    func save(_ snapshot: ResearchMetricsSnapshot) throws {
        saves += 1
        if failure { throw ResearchMetricsError.storageUnavailable }
        self.snapshot = snapshot
    }
    func clear() throws { clears += 1; snapshot = nil }
}

@MainActor
struct ResearchMetricsTests {
    @Test func defaultOffAndOptOutDoNotRecordOrFinishTimers() throws {
        let repository = ResearchRepositorySpy(), clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: repository, clock: clock)
        try recorder.record(.messageOpened); try recorder.startTask(.readMessage); try recorder.completeTask()
        #expect(repository.saves == 0)
        #expect(!recorder.isEnabled)
        try recorder.configure(mode: .hybrid, enabled: true)
        try recorder.startTask(.readMessage)
        let before = recorder.snapshot
        try recorder.configure(mode: .traditional, enabled: false)
        clock.value += 10
        for event in ResearchInteraction.allCases { try recorder.record(event) }
        try recorder.completeTask(); try recorder.abandonTask(); try recorder.startTask(.findMessage)
        #expect(recorder.snapshot == before)
        #expect(recorder.activeTask == nil)
        #expect(recorder.elapsedTaskMilliseconds == nil)
        #expect(!recorder.isEnabled)
        #expect(recorder.mode == .traditional)
        #expect(repository.saves == 2)
    }

    @Test func explicitTaskTimingRecordsCompletionAndAbandonment() throws {
        let clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(), clock: clock)
        try recorder.configure(mode: .hybrid, enabled: true)
        try recorder.startTask(.readMessage)
        clock.value += 1.25
        try recorder.record(.originalShown)
        #expect(recorder.elapsedTaskMilliseconds == 1_250)
        clock.value += 0.75
        try recorder.completeTask()
        #expect(recorder.snapshot.events.last?.durationMilliseconds == 2_000)
        #expect(recorder.snapshot.events.last?.task == .readMessage)
        #expect(recorder.snapshot.completedTaskCount == 1)
        #expect(recorder.activeTask == nil)
        try recorder.startTask(.composeAndRewrite)
        clock.value += 3
        try recorder.abandonTask()
        #expect(recorder.snapshot.abandonedTaskCount == 1)
        #expect(recorder.snapshot.events.last?.durationMilliseconds == 3_000)
        #expect(recorder.snapshot.count(.originalShown) == 1)
        #expect(recorder.snapshot.events.first(where: { $0.interaction == .originalShown })?.task == .readMessage)
    }

    @Test func startingAnotherTaskExplicitlyAbandonsThePreviousAttempt() throws {
        let clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(), clock: clock)
        try recorder.configure(mode: .chatFirst, enabled: true)
        try recorder.startTask(.findMessage)
        clock.value += 5
        try recorder.startTask(.askAssistant)
        let tail = recorder.snapshot.events.suffix(2)
        #expect(tail.map(\.kind) == [.taskAbandoned, .taskStarted])
        #expect(tail.first?.task == .findMessage)
        #expect(tail.first?.durationMilliseconds == 5_000)
        #expect(recorder.activeTask == .askAssistant)
    }

    @Test func modeChangeAbandonsOldConditionTaskAndLabelsFutureEvents() throws {
        let clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(), clock: clock)
        try recorder.configure(mode: .hybrid, enabled: true)
        try recorder.startTask(.classifyMessage)
        clock.value += 2
        try recorder.configure(mode: .traditional, enabled: true)
        let tail = recorder.snapshot.events.suffix(2)
        #expect(tail.map(\.kind) == [.taskAbandoned, .modeChanged])
        #expect(tail.first?.mode == .hybrid)
        #expect(tail.last?.mode == .traditional)
        #expect(tail.first?.durationMilliseconds == 2_000)
        #expect(recorder.activeTask == nil)
        try recorder.record(.navigation)
        #expect(recorder.snapshot.events.last?.mode == .traditional)
        let count = recorder.snapshot.events.count
        try recorder.configure(mode: .traditional, enabled: true)
        #expect(recorder.snapshot.events.count == count)
    }

    @Test func sessionsAreRandomAndActiveTimersNeverResumeAfterRestart() throws {
        let repository = MemoryResearchMetricsRepository(), clock = ResearchFixtureClock()
        let first = try ResearchMetricsRecorder(repository: repository, clock: clock)
        try first.configure(mode: .hybrid, enabled: true)
        try first.startTask(.readMessage)
        let sessionID = first.snapshot.events.first?.sessionID
        let reloaded = try ResearchMetricsRecorder(repository: repository, clock: clock)
        #expect(!reloaded.isEnabled)
        #expect(reloaded.activeTask == nil)
        #expect(reloaded.snapshot == first.snapshot)
        try reloaded.configure(mode: .hybrid, enabled: true)
        #expect(reloaded.snapshot.events.last?.sessionID != sessionID)
        #expect(reloaded.snapshot.events.last?.sessionElapsedMilliseconds == 0)
        #expect(reloaded.snapshot.completedTaskCount == 0)
        #expect(reloaded.snapshot.abandonedTaskCount == 0)
    }

    @Test func retentionIsBoundedAndTruncationIsDisclosed() throws {
        let recorder = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(), maximumEvents: 4)
        try recorder.configure(mode: .hybrid, enabled: true)
        for _ in 0..<10 { try recorder.record(.navigation) }
        #expect(recorder.snapshot.events.count == 4)
        #expect(recorder.snapshot.droppedEventCount == 7)
        #expect(recorder.snapshot.events.map(\.sequence) == [7, 8, 9, 10])
        #expect(try recorder.exportData().count < ResearchMetricsLimits.maximumFileBytes)
    }

    @Test func clearingRemovesEventsAndTimersButDoesNotChangeExistingConsent() throws {
        let repository = ResearchRepositorySpy(), clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: repository, clock: clock)
        try recorder.configure(mode: .hybrid, enabled: true)
        let previousSession = recorder.snapshot.events.first?.sessionID
        try recorder.startTask(.readMessage)
        try recorder.clear()
        #expect(repository.snapshot == nil)
        #expect(repository.clears == 1)
        #expect(recorder.snapshot.events.isEmpty)
        #expect(recorder.activeTask == nil)
        #expect(recorder.isEnabled)
        clock.value += 2
        try recorder.completeTask()
        #expect(recorder.snapshot.events.isEmpty)
        try recorder.record(.navigation)
        #expect(recorder.snapshot.events.first?.sessionID != previousSession)
        #expect(recorder.snapshot.events.first?.sessionElapsedMilliseconds == 2_000)
        #expect(recorder.snapshot.events.first?.sequence == 0)
    }

    @Test func exportHasOnlyTheFixedContentFreeSchemaAndDoesNotRecordAnEvent() throws {
        let repository = ResearchRepositorySpy(), clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: repository, clock: clock)
        try recorder.configure(mode: .hybrid, enabled: true)
        try recorder.startTask(.readMessage)
        for event in ResearchInteraction.allCases { try recorder.record(event) }
        try recorder.completeTask()
        let before = recorder.snapshot
        let data = try recorder.exportData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "droppedEventCount", "events"])
        let events = try #require(object["events"] as? [[String: Any]])
        let allowed: Set<String> = ["sequence", "sessionID", "mode", "kind", "sessionElapsedMilliseconds", "interaction", "task", "durationMilliseconds"]
        #expect(events.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["messageID", "accountID", "subject", "sender", "email", "prompt", "path", "token", "participant", "timestamp"] {
            #expect(!text.contains(forbidden))
        }
        #expect(recorder.snapshot == before)
        #expect(try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: data) == before)
    }

    @Test func writeFailurePreservesLastCommittedSnapshotAndStopsRecording() throws {
        let repository = ResearchRepositorySpy()
        let recorder = try ResearchMetricsRecorder(repository: repository)
        try recorder.configure(mode: .hybrid, enabled: true)
        let committed = recorder.snapshot
        repository.failure = true
        #expect(throws: ResearchMetricsError.storageUnavailable) { try recorder.startTask(.readMessage) }
        #expect(recorder.snapshot == committed)
        #expect(repository.snapshot == committed)
        #expect(!recorder.isEnabled)
        #expect(recorder.activeTask == nil)
        let attemptedWrites = repository.saves
        try recorder.record(.search)
        #expect(repository.saves == attemptedWrites)
    }

    @Test func clocksAreBoundedAndInvalidClockStopsWithoutRecording() throws {
        let clock = ResearchFixtureClock()
        let recorder = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(), clock: clock)
        try recorder.configure(mode: .hybrid, enabled: true)
        try recorder.startTask(.readMessage)
        clock.value += 200_000
        try recorder.completeTask()
        #expect(recorder.snapshot.events.last?.durationMilliseconds == ResearchMetricsLimits.maximumDurationMilliseconds)
        let before = recorder.snapshot
        clock.value = .nan
        #expect(throws: ResearchMetricsError.invalidClock) { try recorder.record(.navigation) }
        #expect(recorder.snapshot == before)
        #expect(!recorder.isEnabled)
    }

    @Test func atomicJSONRoundTripAndFilePermissionsPreserveLocalState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("research-metrics.json")
        let repository = JSONResearchMetricsRepository(url: url)
        let recorder = try ResearchMetricsRecorder(repository: repository)
        try recorder.configure(mode: .traditional, enabled: true)
        try recorder.record(.undo)
        let reloaded = try ResearchMetricsRecorder(repository: JSONResearchMetricsRepository(url: url))
        #expect(reloaded.snapshot == recorder.snapshot)
        #expect(!reloaded.isEnabled)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let parent = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((parent[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func unknownPrivateFieldsAndMalformedStoresArePreservedAndRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("research-metrics.json")
        for contents in [
            #"{"schemaVersion":1,"droppedEventCount":0,"events":[],"prompt":"FICTIONAL_PRIVATE_MARKER"}"#,
            #"{"schemaVersion":999,"droppedEventCount":0,"events":[]}"#,
            "not JSON"
        ] {
            let original = Data(contents.utf8); try original.write(to: url)
            #expect(throws: ResearchMetricsError.self) { _ = try ResearchMetricsRecorder(repository: JSONResearchMetricsRepository(url: url)) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func oversizedFileAndSymlinkAreRejectedBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: ResearchMetricsLimits.maximumFileBytes + 1).write(to: target)
        #expect(throws: ResearchMetricsError.tooLarge) { _ = try JSONResearchMetricsRepository(url: target).load() }
        let link = directory.appendingPathComponent("metrics-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ResearchMetricsError.storageUnavailable) { _ = try JSONResearchMetricsRepository(url: link).load() }
    }

    @Test func invalidEventShapesAndOverflowCountsCannotEnterTheRecorder() throws {
        let invalid = ResearchMetric(sequence: 0, sessionID: UUID(), mode: .hybrid, kind: .taskCompleted,
                                     sessionElapsedMilliseconds: 1, task: .readMessage)
        #expect(throws: ResearchMetricsError.invalidData) {
            _ = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(snapshot: ResearchMetricsSnapshot(events: [invalid])))
        }
        #expect(throws: ResearchMetricsError.tooLarge) {
            _ = try ResearchMetricsRecorder(repository: MemoryResearchMetricsRepository(snapshot: ResearchMetricsSnapshot(droppedEventCount: Int.max)))
        }
    }
}
