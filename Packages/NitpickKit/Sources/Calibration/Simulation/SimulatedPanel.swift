import ColorScience
import Foundation
import PatternLink
import Synchronization

/// A parametric LG-WOLED-like TV panel driven by the simulated pattern source, TV controller and meter.
///
/// Picture modes are keyed by webOS ids: SDR "expert1" (Expert Dark), "expert2", "cinema", "filmMaker",
/// "game" (Game Optimizer); HDR10 "hdr_cinema", "hdr_filmMaker", "hdr_game"; Dolby Vision "dolby_cinema_dark",
/// "dolby_game". Each mode has its own synthetic error profile (see `ModeProfile` and `PanelPipeline` for the
/// processing order). Peaks: SDR 420 cd/m² at OLED light 100, HDR 800 cd/m², on a 10 % window.
///
/// Temporal model, evaluated against `clock.now`: after any change (pattern, setting, upload, input, signal path)
/// the output settles exponentially from the previous output with τ = 0.15 s. ABL limits frame energy to
/// 160 / area^0.8 cd/m² and follows with τ = 0.8 s.
public final class SimulatedPanel: Sendable {
    public static let nativePrimaries = PanelPipeline.native
    public static let sdrPeakLuminance = PanelPipeline.sdrPeak
    public static let hdrPeakLuminance = PanelPipeline.hdrPeak
    public static let blackLevel = PanelPipeline.black.Y
    /// The HDMI input the pattern source is plugged into.
    public static let sourceInput = "HDMI_1"
    public static let pictureModes = ModeProfile.list.map(\.id)

    public static func signalPath(of mode: String) -> DynamicRange? { ModeProfile.all[mode]?.path }
    public static func isGameMode(_ mode: String) -> Bool { ModeProfile.all[mode]?.isGame ?? false }
    /// White chromaticity the mode's factory white balance produces (Dolby Vision modes: the panel's DV white).
    public static func factoryWhite(of mode: String) -> Chromaticity? { ModeProfile.all[mode]?.white }

    public let clock: any Sleeper
    private let state: Mutex<State>

    struct State {
        var settings: [String: [String: JSONValue]]
        var calibration: [String: ModeCalibration] = [:]
        var path: DynamicRange = .sdr
        var modes: [DynamicRange: String] = [.sdr: "expert1", .hdr10: "hdr_cinema", .dolbyVision: "dolby_cinema_dark"]
        var input = SimulatedPanel.sourceInput
        var pattern: PatternSpec?
        var calibrating: String?
        var steady = PanelPipeline.black
        var steadyABL = 1.0
        var from = PanelPipeline.black
        var fromABL = 1.0
        var changedAt: Date

        var mode: String { modes[path] ?? "expert1" }

        func abl(at t: Date) -> Double {
            steadyABL + (fromABL - steadyABL) * exp(-max(0, t.timeIntervalSince(changedAt)) / 0.8)
        }

        func displayed(at t: Date) -> XYZ {
            let k = exp(-max(0, t.timeIntervalSince(changedAt)) / 0.15)
            return from * k + steady * (abl(at: t) * (1 - k))
        }

        func steadyState(for pattern: PatternSpec) -> XYZ {
            guard input == SimulatedPanel.sourceInput, let profile = ModeProfile.all[mode] else { return PanelPipeline.black }
            return PanelPipeline.xyz(
                signal: pattern.content.meteredColor, format: pattern.format, metadata: pattern.hdr10Metadata,
                path: path, profile: profile, controls: ModeControls(settings[mode] ?? profile.defaults),
                calibration: calibration[mode] ?? ModeCalibration())
        }

        mutating func recompute() {
            guard let pattern else {
                steady = PanelPipeline.black
                steadyABL = 1
                return
            }
            steady = steadyState(for: pattern)
            let limit = 160 / pow(max(pattern.content.lightArea, 0.001), 0.8)
            steadyABL = steady.Y > limit ? limit / steady.Y : 1
        }
    }

    public init(clock: any Sleeper) {
        self.clock = clock
        state = Mutex(State(settings: ModeProfile.all.mapValues(\.defaults), changedAt: clock.now))
    }

    /// Applies a change: freezes the current output as the start of a new settling transition, then recomputes.
    private func mutate<T>(_ body: (inout State) throws -> T) throws -> T {
        let now = clock.now
        return try state.withLock { s throws -> T in
            s.from = s.displayed(at: now)
            s.fromABL = s.abl(at: now)
            s.changedAt = now
            let result = try body(&s)
            s.recompute()
            return result
        }
    }

    // MARK: Observation

    /// What the screen centre emits at `date` (default: now), including settling and ABL. Absolute XYZ, cd/m².
    public func displayedXYZ(at date: Date? = nil) -> XYZ {
        let t = date ?? clock.now
        return state.withLock { $0.displayed(at: t) }
    }

    /// Noise-free steady-state output for `pattern` under the current state, without ABL or settling.
    public func steadyXYZ(for pattern: PatternSpec) -> XYZ { state.withLock { $0.steadyState(for: pattern) } }

    public var signalPath: DynamicRange { state.withLock { $0.path } }
    public var pictureMode: String { state.withLock { $0.mode } }
    public var input: String { state.withLock { $0.input } }

    /// Settings of `mode` (default: the current mode).
    public func settings(for mode: String? = nil) -> [String: JSONValue] {
        state.withLock { $0.settings[mode ?? $0.mode] ?? [:] }
    }

    /// Uploaded calibration data of `mode`.
    public func calibration(for mode: String) -> ModeCalibration { state.withLock { $0.calibration[mode] ?? ModeCalibration() } }

    // MARK: Control (used by the simulated devices)

    func show(_ pattern: PatternSpec) { try? mutate { $0.pattern = pattern } }

    /// Switches the signal type the TV receives. Each path remembers its own picture mode.
    func setSignalPath(_ path: DynamicRange) throws {
        guard path != .hlg else { throw CalibrationError.invalidState("The simulated panel has no HLG modes") }
        try mutate { $0.path = path }
    }

    func setInput(_ input: String) { try? mutate { $0.input = input } }

    func setPictureMode(_ mode: String) throws {
        try mutate { s in
            guard let profile = ModeProfile.all[mode] else { throw CalibrationError.outOfRange(key: "pictureMode", value: mode) }
            guard profile.path == s.path else {
                throw CalibrationError.invalidState(
                    "\(mode) is a \(profile.path.displayName) picture mode but the TV is receiving \(s.path.displayName)")
            }
            s.modes[s.path] = mode
        }
    }

    /// Merges already-validated settings into the current mode.
    func update(_ changes: [String: JSONValue]) {
        try? mutate { s in
            let mode = s.mode
            s.settings[mode, default: [:]].merge(changes) { $1 }
        }
    }

    /// Executes an externalpq command. Uploads need an open `.start` for the same mode; game modes refuse uploads
    /// unless `allowGameMode`.
    func calibrate(_ command: CalibrationCommand, allowGameMode: Bool) throws {
        try mutate { s in
            func profile(_ mode: String, upload: Bool, path: DynamicRange? = nil) throws -> ModeProfile {
                guard let p = ModeProfile.all[mode] else { throw CalibrationError.invalidState("Unknown picture mode \(mode)") }
                guard upload else { return p }
                guard s.calibrating == mode else {
                    throw CalibrationError.invalidState("CAL_START for \(mode) is required before uploading")
                }
                if p.isGame && !allowGameMode { throw CalibrationError.refused("\(mode) (Game Optimizer) refuses calibration uploads") }
                if let path, p.path != path { throw CalibrationError.invalidState("\(mode) does not accept this data") }
                if path == nil, p.path == .dolbyVision { throw CalibrationError.invalidState("Dolby Vision modes take only a DV config") }
                return p
            }
            switch command {
            case .start(let mode):
                _ = try profile(mode, upload: false)
                s.calibrating = mode
            case .end(let mode):
                guard s.calibrating == mode else { throw CalibrationError.invalidState("No calibration session is open for \(mode)") }
                s.calibrating = nil
            case .upload1DLUT(let lut, let mode):
                _ = try profile(mode, upload: true)
                guard lut.size == 1024 else { throw CalibrationError.outOfRange(key: "1D LUT size", value: "\(lut.size)") }
                s.calibration[mode, default: ModeCalibration()].lut1D = lut
            case .upload3DLUT(let lut, let colorimetry, let mode):
                _ = try profile(mode, upload: true)
                guard lut.size == 17 || lut.size == 33 else { throw CalibrationError.outOfRange(key: "3D LUT size", value: "\(lut.size)") }
                s.calibration[mode, default: ModeCalibration()].lut3D[colorimetry] = lut
            case .setGamutMatrix(let values, let colorimetry, let mode):
                _ = try profile(mode, upload: true)
                guard values.count == 9, values.allSatisfy({ $0.isFinite && abs($0) <= 4 }) else {
                    throw CalibrationError.outOfRange(key: "gamut matrix", value: "\(values)")
                }
                s.calibration[mode, default: ModeCalibration()].gamutMatrix[colorimetry] = Matrix3(values)
            case .setToneMap(let params, let mode):
                _ = try profile(mode, upload: true, path: .hdr10)
                guard (100...10000).contains(params.displayLuminance), (100...10000).contains(params.masteringPeak),
                    (0...100).contains(params.rolloffPoint)
                else { throw CalibrationError.outOfRange(key: "tonemap", value: "\(params)") }
                s.calibration[mode, default: ModeCalibration()].toneMap = params
            case .setDolbyVisionConfig(let config, let mode):
                _ = try profile(mode, upload: true, path: .dolbyVision)
                let area =
                    abs(
                        (config.green.x - config.red.x) * (config.blue.y - config.red.y)
                            - (config.blue.x - config.red.x) * (config.green.y - config.red.y)) / 2
                guard (100...10000).contains(config.whiteLevel), (0...1).contains(config.blackLevel),
                    (1.8...2.8).contains(config.gamma), area > 0.01, config.white.y > 0
                else {
                    throw CalibrationError.outOfRange(key: "Dolby Vision config", value: "\(config)")
                }
                s.calibration[mode, default: ModeCalibration()].dolbyVision = config
            case .resetCalibration(let mode):
                _ = try profile(mode, upload: false)
                s.calibration[mode] = nil
            }
        }
    }
}
