import Foundation
import XCTest
import FloraCore
@testable import FloraMail

@MainActor
private final class ControllerResearchClock: ResearchClock {
    var value: TimeInterval = 100
    func now() -> TimeInterval { value }
}
@MainActor
private final class ControllerResearchRepository: ResearchMetricsRepository {
    var snapshot: ResearchMetricsSnapshot?
    var saves = 0
    var fail = false
    var unreadable = false
    func load() throws -> ResearchMetricsSnapshot? {
        if unreadable { throw ResearchMetricsError.unreadable }
        return snapshot
    }
    func save(_ snapshot: ResearchMetricsSnapshot) throws {
        saves += 1
        if fail { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/FICTIONAL_PRIVATE_PATH"]) }
        self.snapshot = snapshot
    }
    func clear() throws { snapshot = nil; unreadable = false }
}

@MainActor
final class ResearchControllerTests: XCTestCase {
    func testDefaultOffNeverPersistsInteractionsAndExportDoesNotOptIn() throws {
        let repository = ControllerResearchRepository()
        let controller = ResearchController(repository: repository)
        controller.record(.messageOpened); controller.startTask(.readMessage); controller.completeTask()
        _ = try controller.exportData()
        XCTAssertFalse(controller.isEnabled); XCTAssertEqual(controller.eventCount, 0); XCTAssertEqual(repository.saves, 0)
    }
    func testTaskControlsAndModeSwitchExposeTruthfulCompletionCounts() {
        let clock = ControllerResearchClock()
        let controller = ResearchController(repository: MemoryResearchMetricsRepository(), clock: clock)
        controller.configure(mode: .hybrid, enabled: true)
        controller.startTask(.readMessage); clock.value += 2; controller.completeTask()
        XCTAssertEqual(controller.completedTaskCount, 1); XCTAssertNil(controller.activeTask)
        controller.startTask(.findMessage); clock.value += 3
        XCTAssertEqual(controller.elapsedTaskMilliseconds, 3_000)
        controller.configure(mode: .chatFirst, enabled: true)
        XCTAssertEqual(controller.mode, .chatFirst); XCTAssertEqual(controller.abandonedTaskCount, 1); XCTAssertNil(controller.activeTask)
    }
    func testOptOutImmediatelyDropsTimerAndIgnoresAllLaterInteractionHooks() {
        let repository = ControllerResearchRepository()
        let controller = ResearchController(repository: repository)
        controller.configure(mode: .hybrid, enabled: true); controller.startTask(.readMessage)
        let saved = repository.snapshot
        controller.configure(mode: .hybrid, enabled: false)
        for event in ResearchInteraction.allCases { controller.record(event) }
        controller.completeTask()
        XCTAssertFalse(controller.isEnabled); XCTAssertNil(controller.activeTask); XCTAssertEqual(repository.snapshot, saved)
    }
    func testStorageFailureShowsNoPrivateErrorPathAndDoesNotSilentlyResume() {
        let repository = ControllerResearchRepository()
        let controller = ResearchController(repository: repository)
        controller.configure(mode: .hybrid, enabled: true)
        repository.fail = true; controller.record(.search)
        XCTAssertFalse(controller.isEnabled); XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.errorMessage?.contains("FICTIONAL_PRIVATE_PATH") ?? true)
        let attemptedWrites = repository.saves
        repository.fail = false
        controller.configure(mode: .hybrid, enabled: true); controller.record(.search)
        XCTAssertEqual(repository.saves, attemptedWrites)
        controller.configure(mode: .hybrid, enabled: false)
        controller.configure(mode: .hybrid, enabled: true)
        XCTAssertTrue(controller.isEnabled); XCTAssertNil(controller.errorMessage)
    }
    func testExplicitRetryKeepsCommittedMetricsAndStartsANewRecordingEpoch() throws {
        let repository = ControllerResearchRepository()
        let controller = ResearchController(repository: repository)
        controller.configure(mode: .hybrid, enabled: true)
        controller.record(.navigation)
        let committed = try XCTUnwrap(repository.snapshot)
        let previousEpoch = controller.recordingEpoch
        repository.fail = true; controller.record(.search)
        XCTAssertFalse(controller.isEnabled)
        repository.fail = false
        controller.retryRecording(mode: .hybrid)
        XCTAssertTrue(controller.isEnabled); XCTAssertNil(controller.errorMessage)
        XCTAssertNotEqual(controller.recordingEpoch, previousEpoch)
        let resumed = try XCTUnwrap(repository.snapshot)
        XCTAssertEqual(Array(resumed.events.prefix(committed.events.count)), committed.events)
        XCTAssertEqual(resumed.events.count, committed.events.count + 1)
        XCTAssertEqual(resumed.events.last?.kind, .sessionStarted)
    }
    func testModeChangesClearAndOptOutInvalidatePresentationRecordingEpoch() {
        let controller = ResearchController(repository: MemoryResearchMetricsRepository())
        controller.configure(mode: .hybrid, enabled: true)
        let enabledEpoch = controller.recordingEpoch
        controller.record(.search)
        XCTAssertEqual(controller.recordingEpoch, enabledEpoch)
        controller.configure(mode: .traditional, enabled: true)
        XCTAssertNotEqual(controller.recordingEpoch, enabledEpoch)
        let modeEpoch = controller.recordingEpoch
        controller.clear()
        XCTAssertNotEqual(controller.recordingEpoch, modeEpoch)
        let clearedEpoch = controller.recordingEpoch
        controller.configure(mode: .traditional, enabled: false)
        XCTAssertNotEqual(controller.recordingEpoch, clearedEpoch)
    }
    func testUnreadableStoreCannotBeOverwrittenUntilExplicitClear() throws {
        let repository = ControllerResearchRepository(); repository.unreadable = true
        let controller = ResearchController(repository: repository)
        controller.configure(mode: .hybrid, enabled: true); controller.record(.search)
        XCTAssertEqual(repository.saves, 0); XCTAssertFalse(controller.isEnabled); XCTAssertNotNil(controller.errorMessage)
        XCTAssertThrowsError(try controller.exportData())
        controller.configure(mode: .hybrid, enabled: false); controller.clear()
        XCTAssertNil(controller.errorMessage); XCTAssertEqual(controller.eventCount, 0)
        controller.configure(mode: .traditional, enabled: true)
        XCTAssertTrue(controller.isEnabled)
    }
    func testClearResetsCountersAndTaskWithoutInventingCompletion() throws {
        let controller = ResearchController(repository: MemoryResearchMetricsRepository())
        controller.configure(mode: .hybrid, enabled: true); controller.startTask(.readMessage); controller.completeTask()
        controller.startTask(.findMessage); controller.clear()
        XCTAssertEqual(controller.eventCount, 0); XCTAssertEqual(controller.completedTaskCount, 0); XCTAssertEqual(controller.abandonedTaskCount, 0)
        XCTAssertNil(controller.activeTask); XCTAssertTrue(controller.isEnabled)
        let snapshot = try JSONDecoder().decode(ResearchMetricsSnapshot.self, from: controller.exportData())
        XCTAssertTrue(snapshot.events.isEmpty)
    }
}
