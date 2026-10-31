import ColorScience
import Foundation
import Synchronization

/// A `TVController` for `SimulatedPanel`, mirroring the webOS picture-settings and externalpq calibration API.
///
/// Settings are validated like the real TV would (`CalibrationError.outOfRange` / `.unsupportedSetting`): a key must
/// exist in the current picture mode (see `PictureKey` for value conventions). Faults for recovery tests:
/// `failNextCommand(_:)`, `latency` (real wall-clock delay per call, so timeouts are exercised for real) and
/// `disconnectAfter(_:)`.
public final class SimulatedTVController: TVController {
    public let panel: SimulatedPanel
    private let state = Mutex(State())

    struct State {
        var connected = false
        var nextError: (any Error)?
        var latency: Duration = .zero
        var callsUntilDisconnect: Int?
        var allowGameModeCalibration = false
        var commandLog: [String] = []
        var writeObserver: (@Sendable ([String: JSONValue]) -> Void)?
    }

    public init(panel: SimulatedPanel) { self.panel = panel }

    /// LG Game Optimizer is believed to reject externalpq uploads; flip only to model firmware that accepts them.
    public var allowGameModeCalibration: Bool {
        get { state.withLock { $0.allowGameModeCalibration } }
        set { state.withLock { $0.allowGameModeCalibration = newValue } }
    }

    /// Real (wall-clock) delay added to every call.
    public var latency: Duration {
        get { state.withLock { $0.latency } }
        set { state.withLock { $0.latency = newValue } }
    }

    /// Every call so far ("writePictureSettings", "sendCalibration upload1DLUT expert1", …).
    public var commandLog: [String] { state.withLock { $0.commandLog } }

    /// The next call throws `error` instead of executing.
    public func failNextCommand(_ error: any Error) { state.withLock { $0.nextError = error } }

    /// The `n`-th call from now fails and leaves the TV disconnected until `connect()`.
    public func disconnectAfter(_ n: Int) { state.withLock { $0.callsUntilDisconnect = max(1, n) } }

    /// Called synchronously with every accepted settings write (tests use it to act at a precise point).
    public func onWrite(_ observer: @escaping @Sendable ([String: JSONValue]) -> Void) { state.withLock { $0.writeObserver = observer } }

    public var capabilities: TVCapabilities? {
        get async {
            guard state.withLock({ $0.connected }) else { return nil }
            return TVCapabilities(
                modelName: "OLED55B4 (simulated)", firmwareVersion: "sim-1.0", webOSVersion: "webOS 24 (simulated)",
                inputs: (1...4).map {
                    TVInput(id: "HDMI_\($0)", label: "HDMI \($0)", isConnected: "HDMI_\($0)" == SimulatedPanel.sourceInput)
                },
                supportsCalibrationAPI: true, lut3DSize: 33, supportsGamutMatrix: true, isSimulated: true)
        }
    }

    public func connect() async throws {
        try await delay()
        state.withLock {
            $0.connected = true
            $0.commandLog.append("connect")
        }
    }

    public func disconnect() async { state.withLock { $0.connected = false } }

    public func readPictureSettings(pictureMode: String?) async throws -> PictureSettings {
        try await begin("readPictureSettings")
        let mode = pictureMode ?? panel.pictureMode
        guard SimulatedPanel.signalPath(of: mode) != nil else { throw CalibrationError.outOfRange(key: "pictureMode", value: mode) }
        return PictureSettings(pictureMode: mode, values: panel.settings(for: mode), capturedAt: panel.clock.now)
    }

    public func writePictureSettings(_ changes: [String: JSONValue]) async throws {
        try await begin("writePictureSettings \(changes.keys.sorted().joined(separator: ","))")
        let current = panel.settings()
        for (key, value) in changes { try Self.validate(key, value, current: current) }
        panel.update(changes)
        state.withLock { $0.writeObserver }?(changes)
    }

    public func setPictureMode(_ mode: String) async throws {
        try await begin("setPictureMode \(mode)")
        try panel.setPictureMode(mode)
    }

    public func switchInput(_ inputID: String) async throws {
        try await begin("switchInput \(inputID)")
        guard (1...4).map({ "HDMI_\($0)" }).contains(inputID) else { throw CalibrationError.outOfRange(key: "input", value: inputID) }
        panel.setInput(inputID)
    }

    public func sendCalibration(_ command: CalibrationCommand) async throws {
        try await begin("sendCalibration \(Self.describe(command))")
        try panel.calibrate(command, allowGameMode: allowGameModeCalibration)
    }

    // MARK: -

    private func delay() async throws {
        let latency = self.latency
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    /// Latency, connection check and injected faults, then logs the call.
    private func begin(_ call: String) async throws {
        try await delay()
        try state.withLock { s throws(any Error) in
            guard s.connected else { throw CalibrationError.notConnected("TV") }
            if let error = s.nextError {
                s.nextError = nil
                throw error
            }
            if let n = s.callsUntilDisconnect {
                s.callsUntilDisconnect = n - 1
                if n <= 1 {
                    s.callsUntilDisconnect = nil
                    s.connected = false
                    throw CalibrationError.notConnected("TV")
                }
            }
            s.commandLog.append(call)
        }
    }

    static let intRanges: [String: ClosedRange<Int>] = {
        var r: [String: ClosedRange<Int>] = [
            PictureKey.backlight: 0...100, PictureKey.contrast: 0...100,
            PictureKey.brightness: 0...100, PictureKey.color: 0...100,
        ]
        for key in PictureKey.gains + PictureKey.offsets { r[key] = -50...50 }
        return r
    }()

    static let choices: [String: Set<String>] = [
        PictureKey.gamma: Set(ModeControls.gammaValues.keys),
        PictureKey.hdrDynamicToneMapping: ["off", "on", "HGIG"],
        PictureKey.peakBrightness: ["off", "low", "medium", "high"],
    ]

    static func validate(_ key: String, _ value: JSONValue, current: [String: JSONValue]) throws {
        guard current[key] != nil else { throw CalibrationError.unsupportedSetting(key) }
        let bad = CalibrationError.outOfRange(key: key, value: "\(value)")
        if let range = intRanges[key] {
            guard let d = value.doubleValue, d == d.rounded(), range.contains(Int(d)) else { throw bad }
        } else if let allowed = choices[key] {
            guard let s = value.stringValue, allowed.contains(s) else { throw bad }
        } else if key == PictureKey.colorTemperature {
            guard value.stringValue.flatMap(ModeControls.warmth) != nil else { throw bad }
        } else if key == PictureKey.twentyPoint {
            guard let points = PictureKey.decodeTwentyPoint(value), points.joined().allSatisfy({ (-50...50).contains($0) }) else {
                throw bad
            }
        } else {
            throw CalibrationError.unsupportedSetting(key)
        }
    }

    static func describe(_ command: CalibrationCommand) -> String {
        switch command {
        case .start(let m): "start \(m)"
        case .end(let m): "end \(m)"
        case .upload1DLUT(_, let m): "upload1DLUT \(m)"
        case .upload3DLUT(_, let c, let m): "upload3DLUT \(c.rawValue) \(m)"
        case .setGamutMatrix(_, let c, let m): "setGamutMatrix \(c.rawValue) \(m)"
        case .setToneMap(_, let m): "setToneMap \(m)"
        case .setDolbyVisionConfig(_, let m): "setDolbyVisionConfig \(m)"
        case .resetCalibration(let m): "resetCalibration \(m)"
        }
    }
}
