import ColorScience
import Foundation

/// Limits the engine never writes past, whatever an optimizer asks for.
public struct ControlBounds: Codable, Hashable, Sendable {
    /// LG 2-point and 20-point white balance controls.
    public var whiteBalance: ClosedRange<Int> = -50...50
    public var oledLight: ClosedRange<Int> = 0...100
    /// Kept near the default 85 so the panel is not clipped or crushed.
    public var contrast: ClosedRange<Int> = 70...90
    public var brightness: ClosedRange<Int> = 48...52

    public init() {}

    /// The bound for a `PictureKey` (20-point entries use `whiteBalance`); nil for keys without one.
    public func range(for key: String) -> ClosedRange<Int>? {
        switch key {
        case PictureKey.backlight: oledLight
        case PictureKey.contrast: contrast
        case PictureKey.brightness: brightness
        default: (PictureKey.gains + PictureKey.offsets).contains(key) || key.hasPrefix(PictureKey.twentyPoint) ? whiteBalance : nil
        }
    }

    public func clamp(_ key: String, _ value: Int) -> Int {
        guard let r = range(for: key) else { return value }
        return min(max(value, r.lowerBound), r.upperBound)
    }
}

/// One control change written to the TV.
public struct AdjustmentStep: Codable, Hashable, Sendable {
    public var control: String
    public var from: Int
    public var to: Int
    public init(control: String, from: Int, to: Int) {
        self.control = control
        self.from = from
        self.to = to
    }
}

/// Drives three integer controls (R, G, B) until one grey stimulus hits a target chromaticity (and luminance).
///
/// Model: features φ = (x, y, ln Y); a 3×3 Jacobian ∂φ/∂control per control unit, estimated with `probeStep` probes
/// (or re-used from a neighbouring stimulus). Each iteration takes a damped Newton step (`damping`), rounded, limited
/// to ±`maxStep` and to `bounds`; it is kept only if the measured ΔE decreases, else the step is halved. Accepted
/// steps of ≥ 4 units refine the Jacobian (Broyden rank-1 update); a borrowed Jacobian that fails is re-probed once.
/// Steps are judged on one merit: ΔE / `tolerance`, or |ln(Y/Y_target)| / `luminanceTolerance` when that is set and
/// worse. Stops at merit ≤ 1, when the predicted improvement is below the measurement noise (σ_ΔE = ΔE between the
/// reading and the reading scaled by its relative `noiseEstimate`), when no step helps, or after `maxIterations`.
public struct WhiteBalanceOptimizer: Sendable {
    public var tolerance = 0.5
    public var maxIterations = 6
    public var probeStep = 4
    public var damping = 0.7
    public var maxStep = 12
    public var bounds: ClosedRange<Int> = -50...50
    /// Relative luminance error that must also be met when a target luminance is given (nil = ΔE only).
    public var luminanceTolerance: Double?

    public init(tolerance: Double = 0.5, maxIterations: Int = 6, bounds: ClosedRange<Int> = -50...50) {
        self.tolerance = tolerance
        self.maxIterations = maxIterations
        self.bounds = bounds
    }

    public enum StopReason: String, Codable, Sendable {
        case converged, belowNoise, maxIterations, noImprovement, singular, atBounds
    }

    public struct Result: Sendable {
        public var controls: [Int]
        public var reading: MeterReading
        public var deltaE: Double
        public var initialDeltaE: Double
        public var iterations: Int
        /// A control ended at a bound (±50 for LG white balance) or the last Newton step pointed beyond one:
        /// the target is out of reach with these controls.
        public var limitedByBounds: Bool
        public var jacobian: Matrix3?
        public var stopReason: StopReason
    }

    /// - Parameters:
    ///   - targetLuminance: cd/m²; nil keeps the luminance of the first reading (2-point white balance).
    ///   - deltaE: (measured, reference) → judged ΔE.
    ///   - apply: writes the three controls to the TV.
    ///   - measure: measures the stimulus with the controls as last applied.
    public func optimize(
        start: [Int], target: Chromaticity, targetLuminance: Double?,
        deltaE: (XYZ, XYZ) -> Double, jacobian initial: Matrix3? = nil,
        apply: ([Int]) async throws -> Void, measure: () async throws -> MeterReading
    ) async throws -> Result {
        var x = start.map(clamp)
        var applied = start
        if x != start {
            try await apply(x)
            applied = x
        }
        var m = try await measure()
        let reference = target.xyz(Y: targetLuminance ?? m.luminance)
        let goal = Self.features(reference)
        // Merit: ΔE in units of `tolerance`, or the luminance error in units of `luminanceTolerance` if that is worse.
        // Accepting and stopping on one merit keeps the (quiet) luminance term from being drowned by xy noise.
        let luminanceTolerance = targetLuminance == nil ? nil : self.luminanceTolerance
        func merit(_ xyz: XYZ) -> Double {
            let colour = deltaE(xyz, reference) / tolerance
            guard let luminanceTolerance else { return colour }
            return max(colour, abs(log(max(xyz.Y, 1e-9) / reference.Y)) / luminanceTolerance)
        }
        var e = merit(m.xyz)
        let e0 = deltaE(m.xyz, reference)
        var jacobian = initial
        var iterations = 0
        var reason = StopReason.maxIterations
        var wantsBeyond = false
        var probed = false

        while true {
            if e <= 1 {
                reason = .converged
                wantsBeyond = false
                break
            }
            if iterations >= maxIterations {
                reason = .maxIterations
                break
            }
            iterations += 1
            let f = Self.features(m.xyz)
            if jacobian == nil {
                var columns: [[Double]] = []
                for c in 0..<3 {
                    var probe = x
                    let step = x[c] + probeStep <= bounds.upperBound ? probeStep : -probeStep
                    probe[c] += step
                    try await apply(probe)
                    applied = probe
                    let fp = Self.features(try await measure().xyz)
                    columns.append((0..<3).map { (fp[$0] - f[$0]) / Double(step) })
                }
                jacobian = Matrix3(
                    rows: (columns[0][0], columns[1][0], columns[2][0]),
                    (columns[0][1], columns[1][1], columns[2][1]),
                    (columns[0][2], columns[1][2], columns[2][2]))
                probed = true
            }
            guard let j = jacobian, let inverse = j.inverse else {
                reason = .singular
                break
            }
            let newton = inverse * RGB(r: goal[0] - f[0], g: goal[1] - f[1], b: goal[2] - f[2])
            guard newton.components.allSatisfy(\.isFinite) else {
                reason = .singular
                break
            }
            let limits = Double(bounds.lowerBound) - 0.5...Double(bounds.upperBound) + 0.5
            wantsBeyond = (0..<3).contains { !limits.contains(Double(x[$0]) + newton[$0]) }
            var step = (0..<3).map { c in
                clamp(x[c] + Int((damping * newton[c]).clamped(Double(-maxStep), Double(maxStep)).rounded())) - x[c]
            }
            let atBounds = (0..<3).contains { x[$0] == bounds.lowerBound || x[$0] == bounds.upperBound }
            let relativeNoise = m.noiseEstimate ?? 0.003
            let sigma = max(deltaE(m.xyz, m.xyz * (1 + relativeNoise)) / tolerance, luminanceTolerance.map { relativeNoise / $0 } ?? 0)
            if step == [0, 0, 0] || e - merit(Self.predict(f, j, step)) < sigma {
                // A Jacobian borrowed from another stimulus may simply be wrong here: re-estimate it once.
                if !probed && !atBounds {
                    jacobian = nil
                    continue
                }
                reason = step == [0, 0, 0] && atBounds ? .atBounds : .belowNoise
                break
            }

            var accepted = false
            while step != [0, 0, 0] {
                let trial = (0..<3).map { x[$0] + step[$0] }
                try await apply(trial)
                applied = trial
                let mt = try await measure()
                let et = merit(mt.xyz)
                if et < e {
                    jacobian = Self.broyden(j, Self.features(mt.xyz).indices.map { Self.features(mt.xyz)[$0] - f[$0] }, step)
                    x = trial
                    m = mt
                    e = et
                    accepted = true
                    break
                }
                if step.allSatisfy({ abs($0) <= 1 }) { break }
                step = step.map { $0 / 2 }
            }
            if !accepted {
                if !probed {
                    jacobian = nil
                    continue
                }
                reason = .noImprovement
                break
            }
        }
        if applied != x { try await apply(x) }
        return Result(
            controls: x, reading: m, deltaE: deltaE(m.xyz, reference), initialDeltaE: e0, iterations: iterations,
            limitedByBounds: wantsBeyond || x.contains { $0 == bounds.lowerBound || $0 == bounds.upperBound },
            jacobian: jacobian, stopReason: reason)
    }

    private func clamp(_ v: Int) -> Int { min(max(v, bounds.lowerBound), bounds.upperBound) }

    static func features(_ xyz: XYZ) -> [Double] {
        let c = xyz.chromaticity
        return [c.x, c.y, log(max(xyz.Y, 1e-9))]
    }

    /// J + (Δf − J·Δx)·Δxᵀ / |Δx|², skipped for steps shorter than the probe step (noise-dominated).
    static func broyden(_ j: Matrix3, _ df: [Double], _ dx: [Int]) -> Matrix3 {
        let d = dx.map(Double.init)
        let norm = d.reduce(0) { $0 + $1 * $1 }
        guard norm >= 16 else { return j }
        let predicted = j * RGB(r: d[0], g: d[1], b: d[2])
        var m = j
        for r in 0..<3 { for c in 0..<3 { m[r, c] += (df[r] - predicted[r]) * d[c] / norm } }
        return m
    }

    static func predict(_ f: [Double], _ j: Matrix3, _ step: [Int]) -> XYZ {
        let d = j * RGB(r: Double(step[0]), g: Double(step[1]), b: Double(step[2]))
        return Chromaticity(x: f[0] + d.r, y: f[1] + d.g).xyz(Y: exp(f[2] + d.b))
    }
}
