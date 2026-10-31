import ColorScience
import Foundation
import Synchronization

/// What calibration steps share: devices, the resolved target, bounds and the event sink.
/// Every TV write is clamped to `bounds`; every TV call runs under `deviceTimeout`, calibration commands under
/// `calibrationTimeout`.
public struct CalibrationContext: Sendable {
    public var tv: any TVController
    public var measurer: Measurer
    public var target: CalibrationTarget
    public var pictureMode: String
    public var bounds: ControlBounds
    public var deviceTimeout: Duration
    /// Deadline of one `sendCalibration` call. LG settles 3 s after each externalpq command, and a bank reset is nine.
    public var calibrationTimeout: Duration
    public var emit: @Sendable (WorkflowEvent) -> Void
    let runLog: RunLog

    public init(
        tv: any TVController, measurer: Measurer, target: CalibrationTarget, pictureMode: String,
        bounds: ControlBounds = ControlBounds(), deviceTimeout: Duration = .seconds(10),
        calibrationTimeout: Duration = .seconds(60), emit: @escaping @Sendable (WorkflowEvent) -> Void = { _ in }
    ) {
        self.init(
            tv: tv, measurer: measurer, target: target, pictureMode: pictureMode, bounds: bounds,
            deviceTimeout: deviceTimeout, calibrationTimeout: calibrationTimeout, emit: emit, log: RunLog())
    }

    init(
        tv: any TVController, measurer: Measurer, target: CalibrationTarget, pictureMode: String, bounds: ControlBounds,
        deviceTimeout: Duration, calibrationTimeout: Duration, emit: @escaping @Sendable (WorkflowEvent) -> Void, log: RunLog
    ) {
        self.tv = tv
        self.measurer = measurer
        self.target = target
        self.pictureMode = pictureMode
        self.bounds = bounds
        self.deviceTimeout = deviceTimeout
        self.calibrationTimeout = calibrationTimeout
        runLog = log
        self.emit = { event in
            log.record(event)
            emit(event)
        }
    }

    /// Runs a TV call under the device timeout.
    public func tvCall<T: Sendable>(_ body: @escaping @Sendable (any TVController) async throws -> T) async throws -> T {
        let tv = self.tv
        return try await withTimeout(deviceTimeout, "TV") { try await body(tv) }
    }

    /// Sends one calibration command under `calibrationTimeout`.
    func calibrationCall(_ command: CalibrationCommand) async throws {
        let tv = self.tv
        try await withTimeout(calibrationTimeout, "TV") { try await tv.sendCalibration(command) }
    }

    public func readSettings() async throws -> PictureSettings { try await tvCall { try await $0.readPictureSettings(pictureMode: nil) } }

    /// Writes integer controls (clamped to `bounds`); one `.adjustment` per changed key.
    public func write(keys: [String], values: [Int], previous: [Int]) async throws {
        var changes: [String: JSONValue] = [:]
        var steps: [AdjustmentStep] = []
        for (i, key) in keys.enumerated() {
            let value = bounds.clamp(key, values[i])
            if value != previous[i] {
                changes[key] = .number(Double(value))
                steps.append(AdjustmentStep(control: key, from: previous[i], to: value))
            }
        }
        guard !changes.isEmpty else { return }
        let written = changes
        try await tvCall { try await $0.writePictureSettings(written) }
        steps.forEach { emit(.adjustment($0)) }
    }

    /// Writes the whole 20-point table (clamped); one `.adjustment` per changed entry, e.g. "whiteBalance20pt[45].red".
    public func writeTwentyPoint(_ values: [[Int]], previous: [[Int]]) async throws {
        let clamped = values.map { $0.map { bounds.clamp(PictureKey.twentyPoint, $0) } }
        var steps: [AdjustmentStep] = []
        for (i, ire) in PictureKey.twentyPointIRE.enumerated() {
            for (c, name) in ["red", "green", "blue"].enumerated() where clamped[i][c] != previous[i][c] {
                steps.append(AdjustmentStep(control: "\(PictureKey.twentyPoint)[\(ire)].\(name)", from: previous[i][c], to: clamped[i][c]))
            }
        }
        guard !steps.isEmpty else { return }
        let json = PictureKey.encodeTwentyPoint(clamped)
        try await tvCall { try await $0.writePictureSettings([PictureKey.twentyPoint: json]) }
        steps.forEach { emit(.adjustment($0)) }
    }

    /// CAL_START → command → CAL_END for this picture mode; records the upload.
    public func upload(_ command: CalibrationCommand, _ description: String) async throws {
        let mode = pictureMode
        runLog.calibration(open: true)
        try await calibrationCall(.start(pictureMode: mode))
        try await calibrationCall(command)
        try await calibrationCall(.end(pictureMode: mode))
        runLog.calibration(open: false)
        if case .resetCalibration = command { return }
        runLog.upload(description)
    }

    /// Measures a patch and emits `.measurement`.
    public func measure(_ signal: SignalRGB, reference: XYZ?) async throws -> MeterReading {
        let reading = try await measurer.measure(
            signal, format: target.format, metadata: target.hdr10Metadata,
            expectedLuminance: reference?.Y)
        emit(.measurement(stimulus: signal, reading: reading, reference: reference))
        return reading
    }

    /// Measures grey `s` (quantised to the pattern format, like `grayReference`).
    public func measureGray(_ s: Double) async throws -> MeterReading {
        try await measure(.gray(target.quantizedGray(s)), reference: grayReference(s))
    }

    /// Target grey for the quantised level of `s`: target white at the target EOTF luminance (HDR: plain PQ).
    public func grayReference(_ s: Double) -> XYZ { target.whitePoint.xyz(Y: target.eotf.luminance(forSignal: target.quantizedGray(s))) }

    /// The judged ΔE for this target (ΔE ITP for HDR, ΔE2000 for SDR).
    public func deltaE(_ measured: XYZ, _ reference: XYZ) -> Double { Metrics.deltaE(measured, reference, target: target) }
}

/// Thread-safe record of what a run did, fed by the context's events.
final class RunLog: Sendable {
    struct State {
        var stage = ""
        var adjustments: [AdjustmentStep] = []
        var warnings: [String] = []
        var uploads: [String] = []
        var calibrationOpen = false
    }

    private let state = Mutex(State())

    var snapshot: State { state.withLock { $0 } }

    func record(_ event: WorkflowEvent) {
        state.withLock { s in
            switch event {
            case .stage(let name, _, _): s.stage = name
            case .adjustment(let step): s.adjustments.append(step)
            case .warning(let w): s.warnings.append(w)
            default: break
            }
        }
    }

    func upload(_ description: String) { state.withLock { $0.uploads.append(description) } }
    func calibration(open: Bool) { state.withLock { $0.calibrationOpen = open } }
}
