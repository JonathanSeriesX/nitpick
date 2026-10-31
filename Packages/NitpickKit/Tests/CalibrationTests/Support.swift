import Foundation
import Testing
import ColorScience
import PatternLink
@testable import Calibration

/// A complete simulated setup on one virtual clock.
struct Rig {
    let clock = VirtualClock()
    let panel: SimulatedPanel
    let tv: SimulatedTVController
    let source: SimulatedPatternSource
    let meter: SimulatedMeter

    init(seed: UInt64 = 1) {
        panel = SimulatedPanel(clock: clock)
        tv = SimulatedTVController(panel: panel)
        source = SimulatedPatternSource(panel: panel)
        meter = SimulatedMeter(panel: panel, seed: seed)
    }

    var devices: WorkflowRunner.Devices { (meter, source, tv) }

    func connect() async throws {
        try await tv.connect()
        try await source.connect()
        try await meter.connect()
    }

    func measurer(_ settings: MeasurementSettings = .sdr) -> Measurer {
        Measurer(meter: meter, source: source, sleeper: clock, settings: settings)
    }

    /// Context for driving steps directly (tests of optimizers/builders).
    func context(_ target: CalibrationTarget, mode: String, settings: MeasurementSettings = .sdr) -> CalibrationContext {
        CalibrationContext(tv: tv, measurer: measurer(settings), target: target, pictureMode: mode)
    }

    /// Noise-free steady-state output for a window patch in the current state.
    func truth(_ signal: SignalRGB, format: SignalFormat = .sdr, metadata: HDR10StaticMetadata? = nil) -> XYZ {
        panel.steadyXYZ(for: .patch(signal, format: format, hdr10Metadata: metadata))
    }
}

/// Runs a workflow to its terminal event. `onEvent` may act on events (e.g. answer `.needsUser`).
@discardableResult
func runWorkflow(_ runner: WorkflowRunner, _ profile: SessionProfile, _ rig: Rig, session: CalibrationSession? = nil,
                 onEvent: (WorkflowEvent) throws -> Void = { _ in }) async throws -> [WorkflowEvent] {
    var events: [WorkflowEvent] = []
    for try await event in runner.run(profile: profile, devices: rig.devices, session: session ?? CalibrationSession(profile: profile), sleeper: rig.clock) {
        events.append(event)
        try onEvent(event)
    }
    return events
}

extension [WorkflowEvent] {
    var result: SessionResult? {
        for case .completed(let r) in self { return r }
        return nil
    }
    var failure: String? {
        for case .failed(let m) in self { return m }
        return nil
    }
    var wasCancelled: Bool { contains { if case .cancelled = $0 { true } else { false } } }
    var warnings: [String] { compactMap { if case .warning(let w) = $0 { w } else { nil } } }
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("NitpickCalibrationTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func describe(_ set: MeasurementSet) -> String {
    let s = set.summary
    return String(format: "gray max %.2f avg %.2f | colour max %.2f p95 %.2f avg %.2f | gamma %@ | track %.2f%% max %.2f%% | peak %.1f",
                  s.grayscaleMaxDeltaE, s.grayscaleAverageDeltaE, s.maxDeltaE, s.p95DeltaE, s.averageDeltaE,
                  s.averageGamma.map { String(format: "%.3f", $0) } ?? "-", s.eotfTrackingErrorPercent, s.maxLuminanceErrorPercent, set.peakLuminance)
}
