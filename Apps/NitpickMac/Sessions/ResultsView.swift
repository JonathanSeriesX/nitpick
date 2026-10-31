import Calibration
import SwiftUI

/// Results of a completed session: summary cards and charts for the before or after set, then the details.
struct ResultsView: View {
    enum Phase: String, CaseIterable, Identifiable {
        case before = "Before"
        case after = "After"
        var id: String { rawValue }
    }

    enum PatchGroup: String, CaseIterable, Identifiable {
        case primaries = "Primaries & secondaries"
        case sweeps = "Saturation sweeps"
        case verification = "Verification"
        var id: String { rawValue }
    }

    let session: CalibrationSession
    let result: SessionResult
    @State private var phase = Phase.after
    @State private var group = PatchGroup.verification

    init(session: CalibrationSession, result: SessionResult, phase: Phase = .after) {
        self.session = session
        self.result = result
        _phase = State(initialValue: phase)
    }

    var body: some View {
        let target = session.profile.target
        let tol = session.profile.tolerances
        let hdr = target.isHDR
        let set = phase == .after ? result.after : result.before
        let verification = phase == .after ? result.verification : result.before
        let gray = GrayRow.rows(set, target: target)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Results").font(.title2.weight(.semibold))
                Picker("Measurements", selection: $phase) {
                    ForEach(Phase.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .help("Show the measurements taken before or after calibration")
                Spacer()
            }
            if !result.passed {
                Banner(style: .warning, title: "Out of tolerance after calibration", message: result.failures.joined(separator: "\n"))
            }
            SummaryCards(
                metrics: SummaryCards.metrics(
                    set, verification: phase == .after ? result.verification : nil, target: target, tolerances: tol))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 16) {
                ChartCard(
                    title: "Grayscale error",
                    subtitle: hdr
                        ? "ΔE ITP per stimulus; grey bars (below 5 % or in roll-off) are not judged"
                        : "ΔE2000 per stimulus; grey bars (below 5 %) are not judged"
                ) {
                    GrayscaleDeltaEChart(rows: gray, hdr: hdr, tolerances: tol)
                }
                ChartCard(
                    title: "Luminance",
                    subtitle: hdr ? "Measured vs. expected PQ with roll-off" : "Measured vs. \(target.eotf.displayName) target"
                ) {
                    LuminanceChart(rows: gray, hdr: hdr)
                }
                ChartCard(title: "RGB balance", subtitle: "Channel deviation from the target white, ≥ 5 % stimulus") {
                    RGBBalanceChart(rows: gray)
                }
                ChartCard(title: "Chromaticity (CIE 1931 xy)", subtitle: "○ target · ● measured, primaries, secondaries and sweeps") {
                    CIEChart(patches: set.primariesSecondaries + set.saturationSweeps, target: target)
                }
            }
            patchCard(set: set, verification: verification, hdr: hdr, limit: tol.colorLimit(hdr: hdr))
            VerificationTable(rows: PatchRow.rows(verification.verificationPatches, hdr: hdr, limit: tol.colorLimit(hdr: hdr)), hdr: hdr)
            HStack(alignment: .top, spacing: 16) {
                AdjustmentsCard(steps: result.adjustments)
                GeneratedCard(session: session, result: result)
            }
            if !result.warnings.isEmpty {
                Card(title: "Warnings", symbol: "exclamationmark.triangle") {
                    ForEach(result.warnings.indices, id: \.self) { Text(result.warnings[$0]).font(.callout) }
                }
            }
        }
    }

    private func patchCard(set: MeasurementSet, verification: MeasurementSet, hdr: Bool, limit: Double) -> some View {
        let patches: [ColorPatchResult] =
            switch group {
            case .primaries: set.primariesSecondaries
            case .sweeps: set.saturationSweeps
            case .verification: verification.verificationPatches
            }
        return Card(
            title: "Colour patches",
            subtitle: hdr && group == .primaries
                ? "BT.2020 container limits: reported, not judged" : "ΔE per patch; the line is the colour tolerance"
        ) {
            Picker("Patch set", selection: $group) {
                ForEach(PatchGroup.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 440)
        } content: {
            if patches.isEmpty {
                Text("Not measured in this set.").foregroundStyle(.secondary)
            } else {
                PatchDeltaEChart(rows: PatchRow.rows(patches, hdr: hdr, limit: limit), hdr: hdr, limit: limit)
            }
        }
    }
}

/// Metric tiles with pass/fail colours from the session's tolerances.
struct SummaryCards: View {
    struct Metric: Identifiable {
        var id: String { title }
        let title: String
        let value: String
        let detail: String
        let verdict: Verdict
    }

    let metrics: [Metric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(metrics) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(m.verdict.color).frame(width: 8, height: 8)
                        Text(m.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(m.value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    Text(m.detail).font(.caption).foregroundStyle(m.verdict == .fail ? .red : .secondary).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(m.verdict.color.opacity(m.verdict == .info ? 0.06 : 0.1), in: .rect(cornerRadius: 10))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(m.title): \(m.value), \(m.verdict.title), \(m.detail)")
            }
        }
    }

    static func metrics(_ set: MeasurementSet, verification: MeasurementSet?, target: CalibrationTarget, tolerances t: Tolerances)
        -> [Metric]
    {
        let s = set.summary
        let hdr = target.isHDR
        let unit = hdr ? "ΔE ITP" : "ΔE2000"
        func limit(_ v: Double?) -> String { v.map { "limit \(Fmt.num($0, 1))" } ?? unit }
        func metric(_ title: String, _ value: Double, _ max: Double?, digits: Int = 2) -> Metric {
            Metric(title: title, value: Fmt.num(value, digits), detail: limit(max), verdict: Verdict(value, limit: max))
        }
        var out = [
            metric("Colour avg", s.averageDeltaE, nil),
            metric("Colour p95", s.p95DeltaE, hdr ? nil : t.colorP95),
            metric("Colour max", s.maxDeltaE, t.colorLimit(hdr: hdr)),
            metric("Grayscale avg", s.grayscaleAverageDeltaE, hdr ? nil : t.grayscaleAverage),
            metric("Grayscale max", s.grayscaleMaxDeltaE, t.grayMax(hdr: hdr)),
        ]
        if let gamma = s.averageGamma {
            let goal: String =
                if case .gamma(let g, _, _) = target.eotf { "target \(Fmt.num(g, 1))" } else { "target \(target.eotf.displayName)" }
            out.append(Metric(title: "Average gamma", value: Fmt.num(gamma), detail: goal, verdict: .info))
        }
        out.append(
            Metric(
                title: hdr ? "PQ tracking" : "EOTF tracking", value: "\(Fmt.num(s.eotfTrackingErrorPercent, 1)) %",
                detail: hdr
                    ? "mean |error|, max \(Fmt.num(s.maxLuminanceErrorPercent, 1)) %"
                    : "max \(Fmt.num(s.maxLuminanceErrorPercent, 1)) %, limit \(Fmt.num(t.luminanceErrorPercent, 0)) %",
                verdict: hdr ? .info : Verdict(s.maxLuminanceErrorPercent, limit: t.luminanceErrorPercent)))
        out.append(
            Metric(
                title: "Contrast", value: Fmt.contrast(s.contrastRatio),
                detail: s.contrastRatio == nil ? "black below meter floor" : "peak / black", verdict: .info))
        out.append(Metric(title: "White point", value: "\(Fmt.num(s.whitePointCCT, 0)) K", detail: "D65 ≈ 6504 K", verdict: .info))
        out.append(
            Metric(
                title: "Peak", value: Fmt.nits(set.peakLuminance),
                detail: hdr ? "measured, 10 % window" : "target \(Fmt.nits(target.peakWhite))", verdict: .info))
        if let v = verification?.summary {
            out.append(metric("Verification max", v.maxDeltaE, t.colorLimit(hdr: hdr)))
        }
        return out
    }
}
