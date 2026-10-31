import ColorScience
import Foundation
import PatternLink
import Synchronization

public enum WorkflowEvent: Sendable {
    case stage(name: String, index: Int, count: Int)
    case progress(fraction: Double, message: String)
    case measurement(stimulus: SignalRGB, reading: MeterReading, reference: XYZ?)
    case adjustment(AdjustmentStep)
    case warning(String)
    /// The workflow waits for `WorkflowRunner.confirmUser()` (e.g. "Set Apple TV Video Format to Dolby Vision").
    case needsUser(String)
    case completed(SessionResult)
    case cancelled
    case failed(String)
}

/// Runs one calibration session end to end:
/// 1 connectivity, 2 input / signal path / picture mode, 3 settings snapshot (`RestorePoint`, persisted at once),
/// 4 pre-calibration measurements, 5 per-mode adjustment, 6 post-calibration measurements, 7 verification patches.
///
/// Cancellation or failure after step 3 restores the snapshot best-effort (settings only; LUTs uploaded this session
/// are reset only when the profile says `restoreLUTsOnCancel`) and ends with `.cancelled` / `.failed`, preceded by a
/// `.warning` saying what was restored. Terminal outcomes are events; the stream itself finishes without throwing.
/// One run at a time per runner.
public actor WorkflowRunner {
    public typealias Devices = (meter: any Meter, patternSource: any PatternSource, tv: any TVController)

    public let store: SessionStore?
    public let history: MeasurementHistory?
    /// Wall-clock deadline for each TV and connection call.
    public let deviceTimeout: Duration
    /// Wall-clock deadline for each calibration command (see `CalibrationContext.calibrationTimeout`).
    public let calibrationTimeout: Duration
    /// The session as last persisted by the current or last run.
    public private(set) var session: CalibrationSession?

    private let control = Mutex(Control())

    struct Control {
        var task: Task<Void, Never>?
        var pending: CheckedContinuation<Void, any Error>?
        var confirmed = false
    }

    static let stages = ["Connect", "Signal path", "Settings snapshot", "Pre-calibration", "Adjust", "Post-calibration", "Verification"]

    public init(
        store: SessionStore? = nil, history: MeasurementHistory? = nil, deviceTimeout: Duration = .seconds(10),
        calibrationTimeout: Duration = .seconds(60)
    ) {
        self.store = store
        self.history = history
        self.deviceTimeout = deviceTimeout
        self.calibrationTimeout = calibrationTimeout
    }

    public nonisolated func run(
        profile: SessionProfile, devices: Devices, session: CalibrationSession,
        sleeper: any Sleeper
    ) -> AsyncThrowingStream<WorkflowEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: WorkflowEvent.self)
        control.withLock { $0.confirmed = false }
        let task = Task {
            await self.execute(profile: profile, devices: devices, session: session, sleeper: sleeper, continuation: continuation)
            continuation.finish()
        }
        control.withLock { $0.task = task }
        continuation.onTermination = { termination in if case .cancelled = termination { task.cancel() } }
        return stream
    }

    /// Cancels the running workflow (callable from any thread, takes effect at the next await).
    public nonisolated func cancel() { control.withLock { $0.task }?.cancel() }

    /// Answers the pending `.needsUser` (or the next one, if none is pending yet).
    public nonisolated func confirmUser() {
        let pending = control.withLock { c -> CheckedContinuation<Void, any Error>? in
            if let p = c.pending {
                c.pending = nil
                return p
            }
            c.confirmed = true
            return nil
        }
        pending?.resume()
    }

    private func waitForUser() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let now = control.withLock { s -> Bool in
                    if s.confirmed {
                        s.confirmed = false
                        return true
                    }
                    s.pending = c
                    return false
                }
                if now { c.resume() } else if Task.isCancelled { takePending()?.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            takePending()?.resume(throwing: CancellationError())
        }
    }

    private nonisolated func takePending() -> CheckedContinuation<Void, any Error>? {
        control.withLock { s in
            let p = s.pending
            s.pending = nil
            return p
        }
    }

    private func persist(_ s: inout CalibrationSession, _ now: Date, emit: (WorkflowEvent) -> Void) {
        s.updatedAt = now
        session = s
        do { try store?.save(s) } catch { emit(.warning("Could not save the session: \(error)")) }
    }

    private func execute(
        profile: SessionProfile, devices: Devices, session initial: CalibrationSession, sleeper: any Sleeper,
        continuation: AsyncThrowingStream<WorkflowEvent, any Error>.Continuation
    ) async {
        var s = initial
        s.profile = profile
        s.status = .running
        let log = RunLog()
        let history = self.history
        let sessionID = s.id
        let emit: @Sendable (WorkflowEvent) -> Void = { event in
            if case .measurement(let stimulus, let reading, let reference) = event {
                try? history?.append(
                    .init(sessionID: sessionID, stage: log.snapshot.stage, stimulus: stimulus, reading: reading, reference: reference))
            }
            continuation.yield(event)
        }
        persist(&s, sleeper.now, emit: emit)
        let measurer = Measurer(meter: devices.meter, source: devices.patternSource, sleeper: sleeper, settings: profile.measurement)
        // Reported sets average ≥ 3 reads so pass/fail is not decided by single-read noise.
        var reporter = measurer
        reporter.settings.minReads = max(reporter.settings.minReads, 3)
        var ctx = CalibrationContext(
            tv: devices.tv, measurer: measurer, target: profile.target, pictureMode: profile.pictureMode,
            bounds: profile.bounds, deviceTimeout: deviceTimeout, calibrationTimeout: calibrationTimeout, emit: emit, log: log)
        var restorePoint: RestorePoint?
        var durations: [String: Double] = [:]
        var stageStart = sleeper.now
        func stage(_ i: Int) {
            if i > 0 { durations[Self.stages[i - 1]] = sleeper.now.timeIntervalSince(stageStart) }
            stageStart = sleeper.now
            ctx.emit(.stage(name: Self.stages[i], index: i, count: Self.stages.count))
            ctx.emit(.progress(fraction: Double(i) / Double(Self.stages.count), message: Self.stages[i]))
        }
        let meter = devices.meter
        let source = devices.patternSource
        let timeout = deviceTimeout
        let contextEmit = ctx.emit
        let onReading: @Sendable (SignalRGB, MeterReading, XYZ?) -> Void = {
            contextEmit(.measurement(stimulus: $0, reading: $1, reference: $2))
        }

        do {
            stage(0)
            try await withTimeout(timeout, "Meter") { try await meter.connect() }
            let meterInfo = await meter.info
            try await ctx.tvCall { try await $0.connect() }
            guard let capabilities = await devices.tv.capabilities else { throw CalibrationError.notConnected("TV") }
            guard capabilities.inputs.contains(where: { $0.id == profile.inputID }) else {
                throw CalibrationError.precondition("The TV has no input \(profile.inputID)")
            }
            try await withTimeout(timeout, "Pattern generator") { try await source.connect() }
            guard await source.capabilities != nil else { throw CalibrationError.notConnected("Pattern generator") }
            s.tvModel = capabilities.modelName
            s.meterModel = meterInfo.model
            let dolbySource = profile.dynamicRange == .dolbyVision ? try dolbySourceSet(profile) : nil

            stage(1)
            try await ctx.tvCall { try await $0.switchInput(profile.inputID) }
            if profile.dynamicRange == .dolbyVision {
                ctx.emit(.needsUser("On the Apple TV choose Settings ▸ Video and Audio ▸ Format ▸ 4K Dolby Vision, then continue."))
                try await waitForUser()
            } else {
                let request = DisplayModeRequest(dynamicRange: profile.dynamicRange)
                let state = try await withTimeout(timeout + .seconds(30), "Pattern generator") { try await source.setDisplayMode(request) }
                guard state.matchingEnabled else {
                    throw CalibrationError.precondition(
                        "Match Dynamic Range is off on the Apple TV (Settings ▸ Video and Audio ▸ Match Content); turn it on and start again"
                    )
                }
            }
            try await ctx.tvCall { try await $0.setPictureMode(profile.pictureMode) }

            stage(2)
            let snapshot = try await ctx.tvCall { try await $0.readPictureSettings(pictureMode: profile.pictureMode) }
            restorePoint = RestorePoint(inputID: profile.inputID, settings: snapshot)
            s.restorePoint = restorePoint
            persist(&s, sleeper.now, emit: emit)

            stage(3)
            let before = try await reporter.measureSet(.full, target: profile.target, onReading: onReading)
            ctx.target = profile.target.withBlackLevel(before.blackLevel)

            stage(4)
            let outcome = try await ctx.adjust(profile, capabilities: capabilities, dolbySource: dolbySource)

            stage(5)
            let after = try await reporter.measureSet(.withoutVerification, target: ctx.target, onReading: onReading)

            stage(6)
            // The verification run measures no primaries, so it judges against the native gamut measured just before.
            let verification = try await reporter.measureSet(
                .verificationOnly, target: ctx.target, nativeGamut: after.nativeGamut(for: ctx.target), onReading: onReading)
            durations[Self.stages[6]] = sleeper.now.timeIntervalSince(stageStart)

            let failures = profile.tolerances.failures(after) + profile.tolerances.failures(verification)
            let record = log.snapshot
            let result = SessionResult(
                before: before, after: after, verification: verification, adjustments: record.adjustments,
                lutsUploaded: record.uploads, restorePoint: restorePoint, toneAnalysis: outcome.tone,
                durations: durations, warnings: record.warnings, passed: failures.isEmpty, failures: failures)
            s.result = result
            s.generatedLUT1D = outcome.lut1D
            s.generatedLUT3D = outcome.lut3D
            s.dolbyConfig = outcome.dolbyConfig
            s.status = .completed
            persist(&s, sleeper.now, emit: emit)
            emit(.completed(result))
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            var note = "Nothing on the TV was changed."
            if let restorePoint {
                let record = log.snapshot
                let tv = devices.tv
                let calibrationTimeout = calibrationTimeout
                // A fresh task: restoring must not inherit the cancellation that ended the run.
                note = await Task {
                    await Self.restore(
                        restorePoint, profile: profile, tv: tv, lutsUploaded: !record.uploads.isEmpty,
                        calibrationOpen: record.calibrationOpen, timeout: timeout, calibrationTimeout: calibrationTimeout)
                }.value
            }
            s.status = cancelled ? .cancelled : .failed
            s.notes += (s.notes.isEmpty ? "" : "\n") + note
            persist(&s, sleeper.now, emit: emit)
            if cancelled {
                ctx.emit(.warning(note))
                emit(.cancelled)
            } else {
                emit(.failed("\((error as? CalibrationError)?.description ?? "\(error)"). \(note)"))
            }
        }
    }

    private func dolbySourceSet(_ profile: SessionProfile) throws -> MeasurementSet {
        guard let id = profile.sourceSessionID, let store, let source = try? store.load(id: id), source.status == .completed,
            source.profile.dynamicRange == .hdr10, source.profile.usage == .movie, let set = source.result?.after
        else {
            throw CalibrationError.precondition(
                "Dolby Vision needs a completed HDR10 movie session to derive its config from; run one first")
        }
        return set
    }

    /// Writes back every snapshot setting that differs now; closes an open CAL session; optionally resets LUTs.
    static func restore(
        _ point: RestorePoint, profile: SessionProfile, tv: any TVController, lutsUploaded: Bool,
        calibrationOpen: Bool, timeout: Duration, calibrationTimeout: Duration
    ) async -> String {
        let mode = point.settings.pictureMode
        do {
            if calibrationOpen {
                try? await withTimeout(calibrationTimeout, "TV") { try await tv.sendCalibration(.end(pictureMode: mode)) }
            }
            let current = try await withTimeout(timeout, "TV") { try await tv.readPictureSettings(pictureMode: mode) }
            let changes = point.settings.values.filter { current.values[$0.key] != $0.value }
            if !changes.isEmpty { try await withTimeout(timeout, "TV") { try await tv.writePictureSettings(changes) } }
            var note = "Restored \(changes.count) picture setting(s) of \(mode) from the \(RestorePoint.label)."
            if lutsUploaded {
                if profile.restoreLUTsOnCancel {
                    // No start…end bracket here: a failed reset inside one would leave the TV in calibration mode.
                    try await withTimeout(calibrationTimeout, "TV") {
                        try await tv.sendCalibration(.resetCalibration(pictureMode: mode))
                    }
                    note += " Reset the internal calibration of \(mode) to defaults."
                } else {
                    note += " Calibration data uploaded this session stays on the TV."
                }
            }
            return note
        } catch {
            return
                "Restore failed (\((error as? CalibrationError)?.description ?? "\(error)")); the settings snapshot is saved in the session."
        }
    }
}
