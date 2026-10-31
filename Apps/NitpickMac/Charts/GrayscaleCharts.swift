import Calibration
import Charts
import SwiftUI

/// (a) Grayscale ΔE per stimulus with the tolerance lines.
struct GrayscaleDeltaEChart: View {
    let rows: [GrayRow]
    let hdr: Bool
    let tolerances: Tolerances

    var body: some View {
        let limit = tolerances.grayMax(hdr: hdr)
        Chart {
            ForEach(rows) { row in
                BarMark(x: .value("Stimulus %", row.label), y: .value("ΔE", row.deltaE))
                    .foregroundStyle(row.judged ? Verdict(row.deltaE, limit: limit).color : Color.gray.opacity(0.5))
                    .accessibilityLabel("\(row.label) %")
                    .accessibilityValue("ΔE \(Fmt.num(row.deltaE))\(row.judged ? "" : ", not judged")")
            }
            RuleMark(y: .value("Max", limit))
                .foregroundStyle(.red.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) { RuleLabel(text: "max \(Fmt.num(limit, 1))", color: .red) }
            if !hdr {
                RuleMark(y: .value("Average", tolerances.grayscaleAverage))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        RuleLabel(text: "avg \(Fmt.num(tolerances.grayscaleAverage, 1))", color: .orange)
                    }
            }
        }
        .chartXAxisLabel("Stimulus %")
        .chartYAxisLabel(hdr ? "ΔE ITP" : "ΔE2000")
        .chartXAxis {
            AxisMarks(values: rows.map(\.label).filter { (Int($0) ?? 1) % 10 == 0 }) {
                AxisValueLabel()
            }
        }
        .frame(height: 220)
    }
}

/// (b) Measured luminance against the target on a log axis; HDR points in the expected roll-off are marked.
struct LuminanceChart: View {
    let rows: [GrayRow]
    let hdr: Bool

    var body: some View {
        let visible = rows.filter { $0.measured > 0 && $0.target > 0 }
        // Whole decades around the data, so the log axis neither clips nor wastes space.
        let values = visible.flatMap { [$0.measured, $0.target] }
        let low = pow(10, floor(log10(values.min() ?? 0.01)))
        let high = pow(10, ceil(log10(values.max() ?? 100)))
        let ticks = stride(from: log10(low), through: log10(high), by: 1).map { pow(10, $0) }
        let series = hdr ? ["Measured", "Target", "Roll-off"] : ["Measured", "Target"]
        let colors: [Color] = hdr ? [.cyan, Color.primary.opacity(0.6), .orange] : [.cyan, Color.primary.opacity(0.6)]
        Chart {
            ForEach(visible) { row in
                LineMark(x: .value("Stimulus %", row.stimulus), y: .value("cd/m²", row.measured), series: .value("Series", "Measured"))
                    .foregroundStyle(by: .value("Series", "Measured"))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .symbol(.circle)
                    .symbolSize(18)
            }
            ForEach(visible) { row in
                LineMark(x: .value("Stimulus %", row.stimulus), y: .value("cd/m²", row.target), series: .value("Series", "Target"))
                    .foregroundStyle(by: .value("Series", "Target"))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            }
            ForEach(visible.filter(\.inRollOff)) { row in
                PointMark(x: .value("Stimulus %", row.stimulus), y: .value("cd/m²", row.measured))
                    .foregroundStyle(by: .value("Series", "Roll-off"))
                    .symbol(.diamond)
                    .symbolSize(70)
            }
        }
        .chartForegroundStyleScale(domain: series, range: colors)
        .chartYScale(domain: low...high, type: .log)
        .chartYAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(v >= 1 ? Fmt.num(v, 0) : Fmt.num(v, v >= 0.1 ? 1 : v >= 0.01 ? 2 : 3)) }
                }
            }
        }
        .chartXScale(domain: 0...100)
        .chartXAxisLabel("Stimulus %")
        .chartYAxisLabel("cd/m² (log)")
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 220)
        .accessibilityLabel("Luminance against target")
    }
}

/// (c) RGB balance: each channel's deviation from the target white, per stimulus.
struct RGBBalanceChart: View {
    let rows: [GrayRow]

    private struct Point: Identifiable {
        let id: String
        let stimulus: Double
        let channel: String
        let value: Double
    }

    var body: some View {
        let points = rows.flatMap { row -> [Point] in
            guard let b = row.balance else { return [] }
            return [("Red", b.r), ("Green", b.g), ("Blue", b.b)].map {
                Point(id: "\($0.0)\(row.stimulus)", stimulus: row.stimulus, channel: $0.0, value: $0.1)
            }
        }
        let extent = max(5, (points.map { abs($0.value) }.max() ?? 0).rounded(.up))
        Chart {
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.6))
            ForEach(points) { p in
                LineMark(x: .value("Stimulus %", p.stimulus), y: .value("Deviation %", p.value), series: .value("Channel", p.channel))
                    .foregroundStyle(by: .value("Channel", p.channel))
                    .symbol(.circle)
                    .symbolSize(14)
            }
        }
        .chartForegroundStyleScale(["Red": Color.red, "Green": Color.green, "Blue": Color.blue])
        .chartYScale(domain: -extent...extent)
        .chartXScale(domain: 0...100)
        .chartXAxisLabel("Stimulus %")
        .chartYAxisLabel("Deviation %")
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 220)
    }
}

/// A tolerance-line label that stays readable over bars.
struct RuleLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 4)
            .background(.background.opacity(0.85), in: .rect(cornerRadius: 3))
    }
}
