import Calibration
import Charts
import ColorScience
import SwiftUI

/// (d) ΔE of each colour patch by name, with the tolerance line.
struct PatchDeltaEChart: View {
    let rows: [PatchRow]
    let hdr: Bool
    let limit: Double

    var body: some View {
        Chart {
            ForEach(rows) { row in
                BarMark(x: .value("Patch", row.name), y: .value("ΔE", row.deltaE), width: .ratio(0.7))
                    .foregroundStyle(row.pass ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
                    .annotation(position: .top, spacing: 2) {
                        Text(Fmt.num(row.deltaE, 1)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(row.name)
                    .accessibilityValue("ΔE \(Fmt.num(row.deltaE)), \(row.pass ? "pass" : "fail")")
            }
            RuleMark(y: .value("Limit", limit))
                .foregroundStyle(.red.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) { RuleLabel(text: "max \(Fmt.num(limit, 1))", color: .red) }
        }
        .chartXAxis {
            AxisMarks { AxisValueLabel(orientation: .verticalReversed, horizontalSpacing: 0).font(.caption2) }
        }
        .chartYAxisLabel(hdr ? "ΔE ITP" : "ΔE2000")
        .frame(height: 300)
    }
}

/// (e) CIE 1931 xy: spectral locus, target gamut (and the BT.2020 container for HDR), target and measured points.
struct CIEChart: View {
    let patches: [ColorPatchResult]
    let target: CalibrationTarget

    private struct XY: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    private static let locus: [XY] = {
        var points = CIEObserver.wavelengths.indices.compactMap { i -> Chromaticity? in
            let sum = CIEObserver.xbar[i] + CIEObserver.ybar[i] + CIEObserver.zbar[i]
            guard sum > 1e-4, CIEObserver.wavelengths[i] <= 700 else { return nil }
            return Chromaticity(x: CIEObserver.xbar[i] / sum, y: CIEObserver.ybar[i] / sum)
        }
        if let first = points.first { points.append(first) }  // purple line
        return points.enumerated().map { XY(id: $0.offset, x: $0.element.x, y: $0.element.y) }
    }()

    private static func triangle(_ p: ColorSpacePrimaries) -> [XY] {
        [p.red, p.green, p.blue, p.red].enumerated().map { XY(id: $0.offset, x: $0.element.x, y: $0.element.y) }
    }

    var body: some View {
        let gamut = target.isHDR ? (target.contentPrimaries ?? .dciP3D65) : target.primaries
        Chart {
            ForEach(Self.locus) { p in
                LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Line", "Spectral locus"))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if target.isHDR {
                ForEach(Self.triangle(.bt2020)) { p in
                    LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Line", "BT.2020 container"))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            ForEach(Self.triangle(gamut)) { p in
                LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Line", "Target gamut"))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(patches.indices, id: \.self) { i in
                let t = patches[i].error.reference.chromaticity
                let m = patches[i].error.measured.chromaticity
                LineMark(x: .value("x", t.x), y: .value("y", t.y), series: .value("Line", "pair \(i)"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                LineMark(x: .value("x", m.x), y: .value("y", m.y), series: .value("Line", "pair \(i)"))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                PointMark(x: .value("x", t.x), y: .value("y", t.y))
                    .symbol(Circle().strokeBorder(lineWidth: 1.5))
                    .symbolSize(40)
                    .foregroundStyle(Color.primary.opacity(0.9))
                PointMark(x: .value("x", m.x), y: .value("y", m.y))
                    .symbolSize(30)
                    .foregroundStyle(ChartColors.color(t))
                    .accessibilityLabel(patches[i].name)
                    .accessibilityValue("target \(Fmt.xy(t)), measured \(Fmt.xy(m))")
            }
        }
        .chartXScale(domain: 0...0.8)
        .chartYScale(domain: 0...0.9)
        .chartXAxisLabel("x")
        .chartYAxisLabel("y")
        .aspectRatio(0.8 / 0.9, contentMode: .fit)
        .frame(maxHeight: 420)
    }
}
