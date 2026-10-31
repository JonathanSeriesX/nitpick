import ColorScience
import Foundation

/// Builds a 3D LUT (33³ default, 17³ selectable) from a sparse measured grid of the device with its 1D LUT active.
///
/// Forward model: XYZ of content signal v, trilinear on the measured `gridLevels`³ grid in linear light, i.e. the grid
/// axes are mapped through the target EOTF (relative) so an additive device that already tracks the target EOTF is
/// interpolated exactly. Each LUT node is inverted by damped Newton on that model with bounds [0, 1]. Gamut: a target
/// outside the device gamut is pulled toward the grey of the same luminance (luminance first scaled down if even that
/// grey is out of reach) until the linearised model can reach it.
///
/// The LUT is applied after the 1D LUT in the TV, so node u (1D-LUT output space) stores L1(v*) for v = L1⁻¹(u),
/// where v* is the content signal that makes the device show the target colour of v; nodes above the 1D LUT's range
/// continue with slope 1.
public struct CubeLUTBuilder: Sendable {
    public var size: Int
    public var gridLevels: Int

    public init(size: Int = 33, gridLevels: Int = 5) {
        self.size = size
        self.gridLevels = gridLevels
    }

    /// Patches to measure, red slowest, blue fastest.
    public func gridSignals() -> [SignalRGB] {
        let levels = (0..<gridLevels).map { Double($0) / Double(gridLevels - 1) }
        return levels.flatMap { r in levels.flatMap { g in levels.map { b in SignalRGB(r: r, g: g, b: b) } } }
    }

    /// - Parameter measurements: absolute XYZ for `gridSignals()`, same order.
    public func build(measurements: [XYZ], target: CalibrationTarget, lut1D: LUT1D?) throws -> (LUT3D, LUTReport) {
        let n = gridLevels
        guard n >= 2, size >= 2 else { throw CalibrationError.precondition("A 3D LUT needs at least 2 grid levels and 2 nodes per axis") }
        guard measurements.count == n * n * n else { throw CalibrationError.precondition("Expected \(n * n * n) grid measurements") }
        let eotf = target.eotf
        let l0 = eotf.luminance(forSignal: 0)
        let range = eotf.luminance(forSignal: 1) - l0
        func linear(_ v: Double) -> Double { (eotf.luminance(forSignal: v) - l0) / range }
        let model = TrilinearModel(levels: (0..<n).map { linear(Double($0) / Double(n - 1)) }, values: measurements)
        guard let linearInverse = model.cornerMatrix.inverse else { throw CalibrationError.precondition("The measured grid is degenerate") }

        // Content signal of every node, per channel (inverse of the 1D LUT).
        let nodes = (0..<size).map { Double($0) / Double(size - 1) }
        let content = (0..<3).map { c in nodes.map { u in lut1D.map { Self.invert($0.channel(c), u) } ?? u } }
        // Nodes beyond the 1D LUT's output range are never reached directly; continue them with slope 1 so the last
        // cell interpolates like the identity instead of compressing toward the edge.
        let excess = (0..<3).map { c in nodes.map { u in lut1D.map { max(0, u - $0.channel(c).last!) } ?? 0 } }
        let targetLinear = content.map { $0.map { eotf.luminance(forSignal: $0) - l0 } }
        let toXYZ = target.primaries.rgbToXYZ
        let blackXYZ = target.whitePoint.xyz(Y: l0)

        var out = [RGB](repeating: RGB(gray: 0), count: size * size * size)
        var worst = 0.0
        var clippedNodes = 0
        for ri in 0..<size {
            for gi in 0..<size {
                for bi in 0..<size {
                    let goal = toXYZ * XYZ(X: targetLinear[0][ri], Y: targetLinear[1][gi], Z: targetLinear[2][bi]) + blackXYZ
                    var (aim, clipped) = Self.reachable(goal, white: target.whitePoint, black: model.black, inverse: linearInverse)
                    let solution = model.solve(aim, start: linearInverse * (aim - model.black))
                    aim = model.evaluate(solution).xyz
                    if clipped { clippedNodes += 1 } else { worst = max(worst, Metrics.deltaE(aim, goal, target: target)) }
                    var drive = RGB(gray: 0)
                    for c in 0..<3 {
                        let v = eotf.signal(forLuminance: l0 + solution[c] * range)
                        drive[c] = (lut1D.map { LUT1D.sample($0.channel(c), at: v) } ?? v) + excess[c][[ri, gi, bi][c]]
                    }
                    out[(ri * size + gi) * size + bi] = drive
                }
            }
        }
        return (
            LUT3D(size: size, nodes: out),
            LUTReport(pointsUsed: measurements.count, maxPredictedError: worst, clippedRange: nil, clippedNodes: clippedNodes, warnings: [])
        )
    }

    /// Pulls `goal` toward the equal-luminance grey until the linear model reaches it inside [0, 1]³. Only moves beyond
    /// `slack` (0.5 % of a channel, i.e. measurement noise at the gamut surface) count as clipped.
    static let slack = 0.005

    static func reachable(_ goal: XYZ, white: Chromaticity, black: XYZ, inverse: Matrix3) -> (XYZ, clipped: Bool) {
        func amounts(_ xyz: XYZ) -> XYZ { inverse * (xyz - black) }
        var gray = white.xyz(Y: goal.Y)
        let g = amounts(gray)
        let top = max(g.X, g.Y, g.Z)
        var clipped = false
        if top > 1 {
            gray = black + (gray - black) / top
            clipped = top > 1 + slack
        }
        let a = amounts(gray)
        let t = amounts(goal)
        var alpha = 1.0
        for (from, to) in [(a.X, t.X), (a.Y, t.Y), (a.Z, t.Z)] {
            if to < 0, from > to { alpha = min(alpha, from / (from - to)) }
            if to > 1, to > from { alpha = min(alpha, (1 - from) / (to - from)) }
        }
        if alpha < 1, [t.X, t.Y, t.Z].contains(where: { $0 < -slack || $0 > 1 + slack }) { clipped = true }
        return (gray + (goal - gray) * max(alpha, 0), clipped)
    }

    /// Input v with table(v) = u for a non-decreasing table (first crossing; 0 / 1 outside its range).
    static func invert(_ table: [Double], _ u: Double) -> Double {
        if u <= table[0] { return 0 }
        if u >= table[table.count - 1] { return 1 }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if LUT1D.sample(table, at: mid) < u { lo = mid } else { hi = mid }
        }
        return hi
    }
}

/// Trilinear XYZ model on a grid with non-uniform (linear-light) axis positions `levels`.
struct TrilinearModel {
    let levels: [Double]
    let values: [XYZ]
    var n: Int { levels.count }
    var black: XYZ { values[0] }

    /// Columns: the full-red, full-green and full-blue corners minus black (linear model of an additive device).
    var cornerMatrix: Matrix3 {
        let last = n - 1
        let r = values[index(last, 0, 0)] - black
        let g = values[index(0, last, 0)] - black
        let b = values[index(0, 0, last)] - black
        return Matrix3(rows: (r.X, g.X, b.X), (r.Y, g.Y, b.Y), (r.Z, g.Z, b.Z))
    }

    func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (i * n + j) * n + k }

    func cell(_ l: Double) -> (Int, Double, Double) {
        var i = 0
        while i < n - 2, l > levels[i + 1] { i += 1 }
        let width = levels[i + 1] - levels[i]
        return (i, (l - levels[i]) / width, width)
    }

    /// XYZ at linear-light coordinates `l` and the Jacobian columns ∂XYZ/∂l_c.
    func evaluate(_ l: [Double]) -> (xyz: XYZ, d: [XYZ]) {
        let (i, tr, wr) = cell(l[0])
        let (j, tg, wg) = cell(l[1])
        let (k, tb, wb) = cell(l[2])
        let c000 = values[index(i, j, k)]
        let c100 = values[index(i + 1, j, k)]
        let c010 = values[index(i, j + 1, k)]
        let c110 = values[index(i + 1, j + 1, k)]
        let c001 = values[index(i, j, k + 1)]
        let c101 = values[index(i + 1, j, k + 1)]
        let c011 = values[index(i, j + 1, k + 1)]
        let c111 = values[index(i + 1, j + 1, k + 1)]
        func lerp(_ a: XYZ, _ b: XYZ, _ t: Double) -> XYZ { a + (b - a) * t }
        let x00 = lerp(c000, c100, tr)
        let x10 = lerp(c010, c110, tr)
        let x01 = lerp(c001, c101, tr)
        let x11 = lerp(c011, c111, tr)
        let y0 = lerp(x00, x10, tg)
        let y1 = lerp(x01, x11, tg)
        let dr0 = lerp(c100 - c000, c110 - c010, tg)
        let dr1 = lerp(c101 - c001, c111 - c011, tg)
        return (lerp(y0, y1, tb), [lerp(dr0, dr1, tb) / wr, lerp(x10 - x00, x11 - x01, tb) / wg, (y1 - y0) / wb])
    }

    /// Damped Newton with backtracking inside [0, 1]³.
    func solve(_ goal: XYZ, start: XYZ) -> [Double] {
        var l = [start.X, start.Y, start.Z].map { $0.clamped(0, 1) }
        var (f, d) = evaluate(l)
        func norm(_ v: XYZ) -> Double { (v.X * v.X + v.Y * v.Y + v.Z * v.Z).squareRoot() }
        var r = norm(f - goal)
        for _ in 0..<12 where r > 1e-7 * max(goal.Y, 1) {
            guard let inv = Matrix3(rows: (d[0].X, d[1].X, d[2].X), (d[0].Y, d[1].Y, d[2].Y), (d[0].Z, d[1].Z, d[2].Z)).inverse else {
                break
            }
            let step = inv * (f - goal)
            var lambda = 1.0
            var improved = false
            while lambda > 0.1 {
                let trial = [l[0] - lambda * step.X, l[1] - lambda * step.Y, l[2] - lambda * step.Z].map { $0.clamped(0, 1) }
                let (ft, dt) = evaluate(trial)
                let rt = norm(ft - goal)
                if rt < r {
                    l = trial
                    f = ft
                    d = dt
                    r = rt
                    improved = true
                    break
                }
                lambda /= 2
            }
            if !improved { break }
        }
        return l
    }
}
