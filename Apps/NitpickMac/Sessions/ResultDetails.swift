import Calibration
import ColorScience
import SwiftUI

/// Verification patches: target and measured xyY, ΔE and pass/fail.
struct VerificationTable: View {
    let rows: [PatchRow]
    let hdr: Bool

    var body: some View {
        Card(title: "Verification", symbol: "tablecells", subtitle: "ColorChecker and seeded random patches, never used for corrections") {
            if rows.isEmpty {
                Text("No verification patches in this set.").foregroundStyle(.secondary)
            } else {
                Table(rows) {
                    TableColumn("Patch") { row in
                        HStack(spacing: 6) {
                            Swatch(signal: row.patch.signal, hdr: hdr).frame(width: 14, height: 14)
                            Text(row.name)
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Target x / y") { Text(Fmt.xy($0.patch.error.reference.chromaticity)).monospacedDigit() }
                    TableColumn("Target Y") { Text(Fmt.num($0.patch.error.reference.Y)).monospacedDigit() }
                    TableColumn("Measured x / y") { Text(Fmt.xy($0.patch.error.measured.chromaticity)).monospacedDigit() }
                    TableColumn("Measured Y") { Text(Fmt.num($0.patch.error.measured.Y)).monospacedDigit() }
                    TableColumn(hdr ? "ΔE ITP" : "ΔE2000") { Text(Fmt.num($0.deltaE)).monospacedDigit() }
                    TableColumn("") { row in
                        Image(systemName: row.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.pass ? .green : .red)
                            .accessibilityLabel(row.pass ? "Pass" : "Fail")
                    }
                    .width(24)
                }
                .frame(height: min(CGFloat(rows.count) * 24 + 32, 340))
            }
        }
    }
}

/// Every control the session changed, from → to.
struct AdjustmentsCard: View {
    let steps: [AdjustmentStep]

    var body: some View {
        Card(
            title: "Adjustments made", symbol: "slider.horizontal.3",
            subtitle: "\(steps.count) change\(steps.count == 1 ? "" : "s") to picture controls"
        ) {
            if steps.isEmpty {
                Text("No picture control was changed.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(steps.indices, id: \.self) { i in
                            GridRow {
                                Text(steps[i].control).lineLimit(1)
                                Text("\(steps[i].from) → \(steps[i].to)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
        }
    }
}

/// LUTs, uploads, tone analysis and the Dolby Vision configuration the session produced.
struct GeneratedCard: View {
    let session: CalibrationSession
    let result: SessionResult

    var body: some View {
        Card(title: "Generated", symbol: "cube.transparent", subtitle: "Calibration data written to the TV") {
            InfoRows(rows: rows)
        }
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = [
            ("1D LUT", session.generatedLUT1D.map { "\($0.size) entries per channel" } ?? "None"),
            ("3D LUT", session.generatedLUT3D.map { "\($0.size)³ nodes" } ?? "None"),
            ("Uploads", result.lutsUploaded.isEmpty ? "None (picture controls only)" : result.lutsUploaded.joined(separator: ", ")),
        ]
        if let tone = result.toneAnalysis {
            out.append(
                (
                    "Tone analysis",
                    "peak \(Fmt.nits(tone.peakLuminance)), knee \(Fmt.nits(tone.kneeLuminance))\(tone.isHardClip ? ", hard clip" : "")"
                ))
            out.append(
                (
                    "Proposed tone map",
                    "display \(tone.proposed.displayLuminance), mastering \(tone.proposed.masteringPeak), roll-off \(tone.proposed.rolloffPoint) %"
                ))
        }
        if let dv = session.dolbyConfig {
            out.append(("Dolby Vision white", "\(Fmt.nits(dv.whiteLevel)) at \(Fmt.xy(dv.white))"))
            out.append(("Dolby Vision black", "\(Fmt.num(dv.blackLevel, 4)) cd/m², gamma \(Fmt.num(dv.gamma, 1))"))
            out.append(("Dolby Vision primaries", "R \(Fmt.xy(dv.red))  G \(Fmt.xy(dv.green))  B \(Fmt.xy(dv.blue))"))
        }
        let measured = result.durations.values.reduce(0, +)
        out.append(("Session time", Fmt.elapsed(measured)))
        return out
    }
}
