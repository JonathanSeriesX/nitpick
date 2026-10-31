import Foundation
import ColorScience

/// What a LUT builder predicts about its result.
public struct LUTReport: Codable, Hashable, Sendable {
    public var pointsUsed: Int
    /// Largest judged ΔE the fitted model predicts at the measured stimuli (3D: over all nodes inside the gamut).
    public var maxPredictedError: Double
    /// Input signal range where a channel had to be clamped; nil when nothing clipped.
    public var clippedRange: ClosedRange<Double>?
    /// 3D only: nodes pulled toward grey because the target lies outside the device gamut.
    public var clippedNodes: Int
    public var warnings: [String]
}

/// Builds the 1024-entry per-channel grayscale LUT (LG "1D LUT") from a measured grayscale.
///
/// Method: subtract the measured black; decompose every grey XYZ into per-channel linear contributions with the
/// measured 100 % primaries (M = [R − K, G − K, B − K]); fit a monotone cubic (PCHIP) per channel through those
/// contributions in the R^(1/2.2) domain (nearly linear in the drive, so interpolation is accurate; flat
/// extrapolation); then for each LUT input v find the drive that gives the channel amount M⁻¹·(XYZ_target(v) − K),
/// i.e. grey on the target EOTF luminance at the target white. Requests above a channel's maximum are clamped and
/// reported ("white too dark"). The device must be roughly additive, which the 100 % primaries check implicitly.
public struct GrayscaleLUTBuilder: Sendable {
    public var size = 1024

    public init(size: Int = 1024) { self.size = size }

    /// - Parameters:
    ///   - grayscale: averaged grey readings (stimulus 0…1, absolute XYZ); must include 0 and 1 and ≥ 21 points.
    ///   - primaries: 100 % red, green and blue readings.
    public func build(grayscale: [(stimulus: Double, xyz: XYZ)], primaries: (red: XYZ, green: XYZ, blue: XYZ),
                      target: CalibrationTarget) throws -> (LUT1D, LUTReport) {
        let gray = grayscale.sorted { $0.stimulus < $1.stimulus }
        guard gray.count >= 21, gray.first?.stimulus == 0, gray.last?.stimulus == 1 else {
            throw CalibrationError.precondition("The 1D LUT needs a grayscale of at least 21 points from 0 to 100 %")
        }
        let black = gray[0].xyz
        let r = primaries.red - black, g = primaries.green - black, b = primaries.blue - black
        guard let inverse = Matrix3(rows: (r.X, g.X, b.X), (r.Y, g.Y, b.Y), (r.Z, g.Z, b.Z)).inverse else {
            throw CalibrationError.precondition("The measured primaries are degenerate")
        }
        let amounts = gray.map { p in inverse * RGB(r: p.xyz.X - black.X, g: p.xyz.Y - black.Y, b: p.xyz.Z - black.Z) }
        let curves = (0..<3).map { c -> MonotoneCubic in
            var running = 0.0
            let ys = amounts.map { a -> Double in running = max(running, pow(max(a[c], 0), 1 / 2.2)); return running }
            return MonotoneCubic(x: gray.map(\.stimulus), y: ys)
        }
        func needed(_ v: Double) -> RGB {
            let t = target.whitePoint.xyz(Y: target.eotf.luminance(forSignal: v))
            return inverse * RGB(r: t.X - black.X, g: t.Y - black.Y, b: t.Z - black.Z)
        }
        var tables = [[Double]](repeating: [Double](repeating: 0, count: size), count: 3)
        var clipped: [Double] = []
        for j in 0..<size {
            let v = Double(j) / Double(size - 1)
            let need = needed(v)
            for c in 0..<3 {
                let y = pow(max(need[c], 0), 1 / 2.2)
                if y >= curves[c](1) { tables[c][j] = 1; if j > 0 { clipped.append(v) }; continue }
                var lo = 0.0, hi = 1.0
                for _ in 0..<40 { let mid = (lo + hi) / 2; if curves[c](mid) < y { lo = mid } else { hi = mid } }
                tables[c][j] = hi
            }
        }
        for c in 0..<3 { for j in 1..<size { tables[c][j] = max(tables[c][j], tables[c][j - 1]) } }
        let lut = LUT1D(red: tables[0], green: tables[1], blue: tables[2])

        let scale = needed(1)
        var warnings: [String] = []
        if !clipped.isEmpty {
            warnings.append("Cannot reach the target white from \(Int(clipped[0] * 100)) %: white too dark → raise OLED light or contrast")
        } else if scale.max < 0.6 {
            warnings.append("White is far brighter than the target: lower OLED light to keep LUT precision")
        }
        var worst = 0.0
        for p in gray where p.stimulus >= 0.049 {
            let drive = lut.apply(RGB(gray: p.stimulus))
            let model = RGB(r: pow(curves[0](drive.r), 2.2), g: pow(curves[1](drive.g), 2.2), b: pow(curves[2](drive.b), 2.2))
            let predicted = black + ColorSpaceMatrix.columns(r, g, b, model)
            worst = max(worst, Metrics.deltaE(predicted, target.reference(.gray(p.stimulus)), target: target))
        }
        return (lut, LUTReport(pointsUsed: gray.count, maxPredictedError: worst,
                               clippedRange: clipped.isEmpty ? nil : clipped.min()!...clipped.max()!, clippedNodes: 0, warnings: warnings))
    }
}

enum ColorSpaceMatrix {
    /// r·a.r + g·a.g + b·a.b for column vectors r, g, b.
    static func columns(_ r: XYZ, _ g: XYZ, _ b: XYZ, _ a: RGB) -> XYZ { r * a.r + g * a.g + b * a.b }
}

/// Monotone piecewise-cubic Hermite interpolation (Fritsch–Carlson / PCHIP) with flat extrapolation.
/// `x` must be strictly increasing and `y` non-decreasing.
struct MonotoneCubic: Sendable {
    let x: [Double], y: [Double], slopes: [Double]

    init(x: [Double], y: [Double]) {
        self.x = x; self.y = y
        let n = x.count
        let d = (0..<(n - 1)).map { (y[$0 + 1] - y[$0]) / (x[$0 + 1] - x[$0]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for k in 1..<(n - 1) where d[k - 1] * d[k] > 0 {
            let h0 = x[k] - x[k - 1], h1 = x[k + 1] - x[k]
            let w1 = 2 * h1 + h0, w2 = h1 + 2 * h0
            m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        }
        slopes = m
    }

    func callAsFunction(_ t: Double) -> Double {
        if t <= x[0] { return y[0] }
        if t >= x[x.count - 1] { return y[y.count - 1] }
        var lo = 0, hi = x.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if x[mid] <= t { lo = mid } else { hi = mid } }
        let h = x[hi] - x[lo], s = (t - x[lo]) / h
        let h00 = (1 + 2 * s) * (1 - s) * (1 - s), h10 = s * (1 - s) * (1 - s), h01 = s * s * (3 - 2 * s), h11 = s * s * (s - 1)
        return h00 * y[lo] + h10 * h * slopes[lo] + h01 * y[hi] + h11 * h * slopes[hi]
    }
}
