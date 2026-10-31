import ColorScience
import Foundation
import PatternLink
import Synchronization
import Testing

@testable import Calibration

final class Counter: Sendable {
    private let value = Mutex(0)
    /// Increments and returns the new value.
    func next() -> Int {
        value.withLock {
            $0 += 1
            return $0
        }
    }
}

@Suite struct RecoveryTests {
    @Test func cancelMidTwentyPointRestoresSnapshot() async throws {
        let rig = Rig(seed: 17)
        let store = try SessionStore(directory: temporaryDirectory())
        let runner = WorkflowRunner(store: store)
        let writes = Counter()
        rig.tv.onWrite { changes in
            if changes[PictureKey.twentyPoint] != nil, writes.next() == 5 { runner.cancel() }
        }
        let session = CalibrationSession(profile: .gameSDR)
        let events = try await runWorkflow(runner, .gameSDR, rig, session: session)
        #expect(events.wasCancelled)
        #expect(events.result == nil)
        #expect(events.contains { if case .adjustment(let step) = $0 { step.control.hasPrefix(PictureKey.twentyPoint) } else { false } })
        let saved = try store.load(id: session.id)
        #expect(saved.status == .cancelled)
        let snapshot = try #require(saved.restorePoint)
        let now = try await rig.tv.readPictureSettings(pictureMode: "game")
        #expect(now.values == snapshot.settings.values)
        #expect(events.warnings.contains { $0.contains("Restored") && $0.contains("LUT state not readable") })
    }

    @Test func meterFailureFailsAndRestores() async throws {
        let rig = Rig(seed: 18)
        let history = try MeasurementHistory(directory: temporaryDirectory())
        let runner = WorkflowRunner(history: history)
        let writes = Counter()
        rig.tv.onWrite { _ in
            if writes.next() == 3 { rig.meter.dropoutAfter(reads: 1) }
        }
        let session = CalibrationSession(profile: .gameSDR)
        let events = try await runWorkflow(runner, .gameSDR, rig, session: session)
        let failure = try #require(events.failure)
        #expect(failure.contains("Meter USB connection lost"))
        #expect(failure.contains("Restored"))
        let state = try #require(await runner.session)
        #expect(state.status == .failed)
        let now = try await rig.tv.readPictureSettings(pictureMode: "game")
        #expect(now.values == state.restorePoint?.settings.values)
        let records = try history.records(for: session.id)
        #expect(records.count > 50)
        #expect(Set(records.map(\.stage)).isSuperset(of: ["Pre-calibration", "Adjust"]))
    }

    @Test func tvTimeoutFailsWithinTheTimeout() async throws {
        let rig = Rig(seed: 19)
        rig.tv.latency = .seconds(5)
        let runner = WorkflowRunner(deviceTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        let events = try await runWorkflow(runner, .gameSDR, rig)
        let elapsed = ContinuousClock.now - start
        let failure = try #require(events.failure)
        #expect(failure.contains("TV did not respond in time"))
        #expect(failure.contains("Nothing on the TV was changed"))
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }

    /// A failed upload inside CAL_START…CAL_END: restore closes the session, then resets the LUTs of the mode.
    @Test func failedUploadClosesSessionAndResetsLUTs() async throws {
        let rig = Rig(seed: 24)
        var profile = SessionProfile.movieSDR
        profile.restoreLUTsOnCancel = true
        profile.cubeSize = 9  // the TV takes 17 or 33 only: the 3D LUT upload fails after the 1D LUT went in
        let events = try await runWorkflow(WorkflowRunner(), profile, rig)
        let failure = try #require(events.failure)
        #expect(failure.contains("3D LUT size") && failure.contains("Reset the internal calibration of expert1"))
        #expect(rig.panel.calibration(for: "expert1").isEmpty)
        let calls = rig.tv.commandLog.filter { $0.hasPrefix("sendCalibration") }
        #expect(
            calls.suffix(3) == [
                "sendCalibration upload3DLUT bt709 expert1", "sendCalibration end expert1", "sendCalibration resetCalibration expert1",
            ])
    }

    @Test func matchContentOffFailsWithInstructions() async throws {
        let rig = Rig(seed: 22)
        rig.source.matchingEnabled = false
        let events = try await runWorkflow(WorkflowRunner(), .movieHDR10, rig)
        #expect(try #require(events.failure).contains("Match Dynamic Range"))
    }

    @Test func interruptedSessionsAreDetectedOnLoad() throws {
        let directory = temporaryDirectory()
        let store = try SessionStore(directory: directory)
        var running = CalibrationSession(profile: .movieSDR)
        running.status = .running
        try store.save(running)
        var done = CalibrationSession(profile: .gameSDR)
        done.status = .completed
        try store.save(done)

        let reopened = try SessionStore(directory: directory)
        #expect(try reopened.markInterrupted() == [running.id])
        #expect(try reopened.load(id: running.id).status == .interrupted)
        #expect(try reopened.load(id: done.id).status == .completed)
        #expect(try reopened.list().count == 2)
        try reopened.delete(id: done.id)
        #expect(try reopened.list().map(\.id) == [running.id])
    }
}
