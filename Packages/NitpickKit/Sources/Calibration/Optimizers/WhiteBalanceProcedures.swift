import Foundation
import ColorScience

/// LG 2-point white balance: gains at a high stimulus, offsets at a low one, alternating passes (they interact),
/// then a 10-point grayscale check. Luminance is left free (the target is chromaticity only).
public struct TwoPointWhiteBalance: Sendable {
    public var highStimulus = 0.8
    public var lowStimulus = 0.25
    public var passes = 2
    public var optimizer = WhiteBalanceOptimizer()
    public var verificationStimuli: [Double] = (1...10).map { Double($0) / 10 }

    public init(highStimulus: Double = 0.8, lowStimulus: Double = 0.25, optimizer: WhiteBalanceOptimizer = WhiteBalanceOptimizer()) {
        self.highStimulus = highStimulus; self.lowStimulus = lowStimulus; self.optimizer = optimizer
    }

    public struct Result: Sendable {
        public var gains: [Int]
        public var offsets: [Int]
        public var limitedByBounds: Bool
        /// Judged ΔE at each verification stimulus after the last pass.
        public var verification: [(stimulus: Double, deltaE: Double)]
    }

    public func run(_ ctx: CalibrationContext) async throws -> Result {
        let settings = try await ctx.readSettings()
        var controls = [PictureKey.gains.map { settings.int($0) ?? 0 }, PictureKey.offsets.map { settings.int($0) ?? 0 }]
        var jacobians: [Matrix3?] = [nil, nil]
        var limited = false
        for _ in 0..<passes {
            for (k, keys) in [PictureKey.gains, PictureKey.offsets].enumerated() {
                let stimulus = k == 0 ? highStimulus : lowStimulus
                var opt = optimizer
                opt.bounds = ctx.bounds.whiteBalance
                let r = try await opt.optimize(
                    start: controls[k], target: ctx.target.whitePoint, targetLuminance: nil, deltaE: ctx.deltaE, jacobian: jacobians[k],
                    apply: { new in
                        try await ctx.write(keys: keys, values: new, previous: controls[k])
                        controls[k] = new
                    },
                    measure: { try await ctx.measureGray(stimulus) })
                controls[k] = r.controls
                jacobians[k] = r.jacobian
                limited = limited || r.limitedByBounds
            }
        }
        var verification: [(Double, Double)] = []
        for s in verificationStimuli {
            let reading = try await ctx.measureGray(s)
            verification.append((s, ctx.deltaE(reading.xyz, ctx.grayReference(s))))
        }
        return Result(gains: controls[0], offsets: controls[1], limitedByBounds: limited, verification: verification)
    }
}

/// LG 20-point white balance, from 100 % down to 5 %, one `WhiteBalanceOptimizer` run per point (target chromaticity
/// and target-EOTF luminance, `luminanceTolerance` from 10 % up), re-using the Jacobian of the previous point.
/// Afterwards all points are re-measured (neighbouring points interact) and the worst `secondPassCount` points beyond
/// tolerance get a second run.
///
/// Near-black rule: at ≤ 10 % stimulus the tolerance is multiplied by min(4, max(1, 1/√L)), L = target luminance in
/// cd/m². Below ~1 cd/m² the meter's xy noise exceeds what one control step changes, so chromaticity is not chased
/// there; ΔE2000 relative to white already weights those points down for SDR.
public struct TwentyPointWhiteBalance: Sendable {
    public var optimizer = WhiteBalanceOptimizer()
    /// Highest stimulus adjusted (HDR: below the tone-mapping knee). Points above keep their values.
    public var maxStimulus = 1.0
    public var secondPassCount = 3
    /// Relative luminance error each point ≥ 10 % must also meet (EOTF tracking).
    public var luminanceTolerance = 0.02

    public init(optimizer: WhiteBalanceOptimizer = WhiteBalanceOptimizer(), maxStimulus: Double = 1.0) {
        self.optimizer = optimizer; self.maxStimulus = maxStimulus
    }

    public struct PointResult: Codable, Hashable, Sendable {
        public var ire: Int
        public var deltaE: Double
        public var luminanceErrorPercent: Double
        /// ΔE tolerance after the near-black rule.
        public var tolerance: Double
        public var controls: [Int]
    }

    public struct Result: Sendable {
        /// 20 × [red, green, blue].
        public var values: [[Int]]
        /// Every adjusted point after the final re-measurement / second pass.
        public var points: [PointResult]
        public var secondPass: [Int]
        public var limitedByBounds: Bool
    }

    func tolerance(stimulus: Double, luminance: Double) -> Double {
        stimulus <= 0.1 ? optimizer.tolerance * min(4, max(1, 1 / max(luminance, 1e-6).squareRoot())) : optimizer.tolerance
    }

    /// max(ΔE / tolerance, |ln(Y / Y_target)| / luminanceTolerance for points ≥ 10 %): above 1 = out of tolerance.
    func excess(_ xyz: XYZ, stimulus s: Double, _ ctx: CalibrationContext) -> Double {
        let reference = ctx.grayReference(s)
        let colour = ctx.deltaE(xyz, reference) / tolerance(stimulus: s, luminance: reference.Y)
        return s >= 0.1 ? max(colour, abs(log(max(xyz.Y, 1e-9) / reference.Y)) / luminanceTolerance) : colour
    }

    public func run(_ ctx: CalibrationContext) async throws -> Result {
        let settings = try await ctx.readSettings()
        var values = PictureKey.decodeTwentyPoint(settings.values[PictureKey.twentyPoint]) ?? PictureKey.zeroTwentyPoint
        let active = PictureKey.twentyPointIRE.filter { Double($0) / 100 <= maxStimulus + 1e-9 }.reversed()
        var jacobian: Matrix3?
        var limited = Set<Int>()
        var readings: [Int: XYZ] = [:]

        func adjust(_ ire: Int) async throws {
            let i = ire / 5 - 1, s = Double(ire) / 100
            let reference = ctx.grayReference(s)
            var opt = optimizer
            opt.bounds = ctx.bounds.whiteBalance
            opt.tolerance = tolerance(stimulus: s, luminance: reference.Y)
            if s >= 0.1 { opt.luminanceTolerance = luminanceTolerance }
            let r = try await opt.optimize(
                start: values[i], target: ctx.target.whitePoint, targetLuminance: reference.Y, deltaE: ctx.deltaE, jacobian: jacobian,
                apply: { new in
                    var next = values
                    next[i] = new
                    try await ctx.writeTwentyPoint(next, previous: values)
                    values = next
                },
                measure: { try await ctx.measureGray(s) })
            values[i] = r.controls
            if let j = r.jacobian { jacobian = j }
            if r.limitedByBounds { limited.insert(ire) } else { limited.remove(ire) }
            readings[ire] = r.reading.xyz
        }

        for ire in active { try await adjust(ire) }
        for ire in active { readings[ire] = try await ctx.measureGray(Double(ire) / 100).xyz }
        let excesses = Dictionary(uniqueKeysWithValues: active.map { ($0, excess(readings[$0]!, stimulus: Double($0) / 100, ctx)) })
        let worst = active.filter { excesses[$0]! > 1 }.sorted { excesses[$0]! > excesses[$1]! }.prefix(secondPassCount)
        for ire in worst { try await adjust(ire) }

        let points = active.reversed().map { ire in
            let s = Double(ire) / 100, reference = ctx.grayReference(s), xyz = readings[ire]!
            return PointResult(ire: ire, deltaE: ctx.deltaE(xyz, reference), luminanceErrorPercent: (xyz.Y / reference.Y - 1) * 100,
                               tolerance: tolerance(stimulus: s, luminance: reference.Y), controls: values[ire / 5 - 1])
        }
        return Result(values: values, points: points, secondPass: Array(worst), limitedByBounds: !limited.isEmpty)
    }
}
