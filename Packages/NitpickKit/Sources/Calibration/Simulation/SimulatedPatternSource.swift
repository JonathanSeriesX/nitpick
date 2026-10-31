import ColorScience
import Foundation
import PatternLink
import Synchronization

/// A `PatternSource` that puts patterns straight onto a `SimulatedPanel` (an Apple TV on `SimulatedPanel.sourceInput`).
///
/// Patterns are quantised to the format's code values before display. `setDisplayMode` switches the panel between
/// SDR and HDR10 after `switchDelay` (virtual time). With `matchingEnabled == false` (Match Content off) nothing
/// changes and the returned state says so. Dolby Vision cannot be requested by an app: use
/// `simulateUserSelectsOutput(_:)` to model the user changing the Apple TV video format.
public final class SimulatedPatternSource: PatternSource {
    public let panel: SimulatedPanel
    private let state = Mutex(State())

    struct State {
        var connected = false
        var sequence: UInt32 = 0
        var matchingEnabled = true
        var switchDelay: Duration = .seconds(2)
        var mode = DisplayModeState(requested: DisplayModeRequest(dynamicRange: .sdr), matchingEnabled: true)
    }

    public init(panel: SimulatedPanel) { self.panel = panel }

    /// tvOS "Match Content → Match Dynamic Range".
    public var matchingEnabled: Bool {
        get { state.withLock { $0.matchingEnabled } }
        set { state.withLock { $0.matchingEnabled = newValue } }
    }

    /// Virtual time an HDMI mode switch takes.
    public var switchDelay: Duration {
        get { state.withLock { $0.switchDelay } }
        set { state.withLock { $0.switchDelay = newValue } }
    }

    public var capabilities: DeviceCapabilities? {
        get async {
            state.withLock { s in
                guard s.connected else { return nil }
                return DeviceCapabilities(
                    deviceName: "Simulated Apple TV 4K", model: "AppleTV14,1", systemVersion: "tvOS (simulated)",
                    frameWidth: 3840, frameHeight: 2160, supportsDisplayCriteria: true, displayMode: s.mode)
            }
        }
    }

    public func connect() async throws { state.withLock { $0.connected = true } }
    public func disconnect() async { state.withLock { $0.connected = false } }

    public func show(_ pattern: PatternSpec) async throws -> ShowAck {
        let sequence = try state.withLock { s throws(CalibrationError) -> UInt32 in
            guard s.connected else { throw CalibrationError.notConnected("Pattern generator") }
            s.sequence &+= 1
            return s.sequence
        }
        var shown = pattern
        shown.content = Self.quantized(pattern.content, pattern.format)
        panel.show(shown)
        let codes = pattern.content.centerColor.map { c -> [Int] in
            let q = c.codes(in: pattern.format)
            return [q.r, q.g, q.b]
        }
        return ShowAck(sequence: sequence, enqueuedAt: panel.clock.now, centerCodes: codes)
    }

    public func setDisplayMode(_ request: DisplayModeRequest) async throws -> DisplayModeState {
        let (matching, delay) = try state.withLock { s throws(CalibrationError) in
            guard s.connected else { throw CalibrationError.notConnected("Pattern generator") }
            return (s.matchingEnabled, s.switchDelay)
        }
        guard matching else {
            return state.withLock { s in
                s.mode = DisplayModeState(
                    requested: request, matchingEnabled: false, currentEDRHeadroom: s.mode.currentEDRHeadroom,
                    note: "Match Dynamic Range is off; output unchanged")
                return s.mode
            }
        }
        guard request.dynamicRange == .sdr || request.dynamicRange == .hdr10 else {
            return state.withLock { s in
                s.mode = DisplayModeState(
                    requested: request, matchingEnabled: true, currentEDRHeadroom: s.mode.currentEDRHeadroom,
                    note: "\(request.dynamicRange.displayName) output must be selected in the Apple TV settings")
                return s.mode
            }
        }
        if panel.signalPath != request.dynamicRange {
            try await panel.clock.sleep(for: delay)
            try panel.setSignalPath(request.dynamicRange)
        }
        return state.withLock { s in
            s.mode = DisplayModeState(
                requested: request, matchingEnabled: true, currentEDRHeadroom: request.dynamicRange == .sdr ? 1 : 8,
                potentialEDRHeadroom: 8)
            return s.mode
        }
    }

    public func blank() async throws { _ = try await show(.black(format: .sdr)) }

    /// Models the user picking an output format in the Apple TV settings (the only way to get Dolby Vision).
    public func simulateUserSelectsOutput(_ dynamicRange: DynamicRange) throws {
        try panel.setSignalPath(dynamicRange)
        state.withLock { s in
            s.mode = DisplayModeState(
                requested: DisplayModeRequest(dynamicRange: dynamicRange), matchingEnabled: s.matchingEnabled,
                currentEDRHeadroom: dynamicRange == .sdr ? 1 : 8, potentialEDRHeadroom: 8)
        }
    }

    static func quantized(_ content: PatternContent, _ format: SignalFormat) -> PatternContent {
        func q(_ c: SignalRGB) -> SignalRGB { c.quantized(in: format) }
        switch content {
        case .window(let patch, let window, let background): return .window(patch: q(patch), window: window, background: q(background))
        case .fullField(let c): return .fullField(q(c))
        case .ramp(let steps, let from, let to, let horizontal):
            return .ramp(steps: steps, from: q(from), to: q(to), horizontal: horizontal)
        case .bars(let bars, let background): return .bars(bars.map(q), background: q(background))
        case .black: return .black
        }
    }
}
