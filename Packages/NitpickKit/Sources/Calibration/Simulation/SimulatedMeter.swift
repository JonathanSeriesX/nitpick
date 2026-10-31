import Foundation
import Synchronization
import ColorScience

/// A `Meter` that reads a `SimulatedPanel` (a Display Plus HL pointed at the screen centre).
///
/// Each read waits the integration time on the panel's clock, then samples the panel at `clock.now`.
/// Integration time (s) adapts to the light like the i1d3's adaptive mode: clamp(1 / √L, 0.2, 4).
/// Noise (1σ, seeded): luminance √((0.003·L)² + 0.002²) cd/m²; x and y each 0.0004 + 0.0015 / √max(L, 0.05).
/// Readings below 0.002 cd/m² carry the "belowFloor" flag. A `.matrix` correction is applied to the XYZ.
/// `noiseEstimate` is the per-channel relative 1σ (≥ the relative luminance σ), so averaging also tames xy noise.
public final class SimulatedMeter: Meter {
    public let panel: SimulatedPanel
    private let state: Mutex<State>

    struct State {
        var random: SeededRandom
        var connected = false
        var correction: Matrix3?
        var nextError: (any Error)?
        var readsUntilDropout: Int?
        var readCount = 0
        var noiseScale = 1.0
    }

    public init(panel: SimulatedPanel, seed: UInt64 = 1) {
        self.panel = panel
        state = Mutex(State(random: SeededRandom(seed: seed)))
    }

    public var info: MeterInfo {
        get async { MeterInfo(model: "Simulated Display Plus HL", serialNumber: "SIM-0001", firmware: "sim", maximumLuminance: 10_000, isSimulated: true) }
    }

    /// Multiplies all noise σ (1 = the documented model).
    public var noiseScale: Double {
        get { state.withLock { $0.noiseScale } }
        set { state.withLock { $0.noiseScale = newValue } }
    }

    public var readCount: Int { state.withLock { $0.readCount } }

    /// The next read throws `error`.
    public func failNextRead(_ error: any Error) { state.withLock { $0.nextError = error } }

    /// The `n`-th read from now fails like a USB dropout and the meter stays disconnected until `connect()`.
    public func dropoutAfter(reads n: Int) { state.withLock { $0.readsUntilDropout = max(1, n) } }

    public func connect() async throws { state.withLock { $0.connected = true } }
    public func disconnect() async { state.withLock { $0.connected = false } }

    public func setCorrection(_ correction: ColorimeterCorrection?) async throws {
        var matrix: Matrix3?
        switch correction?.kind {
        case .matrix(let m)?:
            guard m.count == 9 else { throw CalibrationError.outOfRange(key: "correction", value: "\(m.count) values") }
            matrix = Matrix3(m)
        case .spectral?: throw CalibrationError.unsupportedSetting("Spectral corrections need the hardware driver's sensor curves")
        case nil: matrix = nil
        }
        state.withLock { $0.correction = matrix }
    }

    public func measure(expectedLuminance: Double?) async throws -> MeterReading {
        try Task.checkCancellation()
        try state.withLock { s throws(any Error) in
            guard s.connected else { throw CalibrationError.notConnected("Meter") }
            if let error = s.nextError { s.nextError = nil; throw error }
            if let n = s.readsUntilDropout {
                s.readsUntilDropout = n - 1
                if n <= 1 {
                    s.readsUntilDropout = nil
                    s.connected = false
                    throw CalibrationError.deviceFailure("Meter USB connection lost")
                }
            }
        }
        let integration = (1 / max(panel.displayedXYZ().Y, 1e-6).squareRoot()).clamped(0.2, 4)
        try await panel.clock.sleep(for: .milliseconds(Int(integration * 1000)))
        let truth = panel.displayedXYZ()
        return state.withLock { s in
            s.readCount += 1
            let L = truth.Y
            let sigmaL = ((0.003 * L) * (0.003 * L) + 0.002 * 0.002).squareRoot() * s.noiseScale
            let sigmaXY = (0.0004 + 0.0015 / max(L, 0.05).squareRoot()) * s.noiseScale
            let c = truth.chromaticity
            let Y = max(0, L + sigmaL * s.random.gaussian())
            var xyz = Chromaticity(x: c.x + sigmaXY * s.random.gaussian(), y: c.y + sigmaXY * s.random.gaussian()).xyz(Y: Y)
            if let m = s.correction { xyz = m * xyz }
            var flags: [String] = []
            if L < 0.002 { flags.append("belowFloor") }
            if L > 10_000 { flags.append("saturated") }
            // Per-channel relative noise: luminance σ, or the xy σ expressed as tristimulus noise (∂x/∂ln X ≈ 0.21 near white),
            // whichever is larger — both come from the same three sensor channels.
            return MeterReading(xyz: xyz, timestamp: panel.clock.now, integrationTime: integration,
                                noiseEstimate: max(sigmaL / max(Y, 0.002), sigmaXY / 0.21), flags: flags)
        }
    }
}
