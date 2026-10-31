import Calibration
import ColorScience
import SwiftUI

/// The live run: stage progress, the user prompt, the latest readings, warnings and the outcome.
struct RunProgressView: View {
    @Environment(AppModel.self) private var model
    let run: SessionRun

    var body: some View {
        Card(
            title: run.isRunning ? "Running" : "Last run", symbol: "waveform.path.ecg",
            subtitle: "Stage \(run.stageIndex + 1) of \(run.stageCount) · \(run.stageName)"
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.elapsed((run.finishedAt ?? context.date).timeIntervalSince(run.startedAt)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed time")
            }
        } content: {
            ProgressView(value: run.fraction)
                .accessibilityLabel("Session progress")
                .accessibilityValue("\(Int(run.fraction * 100)) percent")
            StageStrip(current: run.stageIndex, count: run.stageCount, finished: run.outcome == .completed)
            Text(
                run.message.isEmpty
                    ? "\(run.totalReadings) readings" : "\(run.message) · \(run.totalReadings) readings · \(run.adjustments) adjustments"
            )
            .font(.callout).foregroundStyle(.secondary)
            if let prompt = run.prompt {
                Banner(style: .prompt, title: "Your turn", message: prompt) {
                    Button("Continue") { model.confirmPrompt() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            outcome
            if !run.feed.isEmpty { LiveFeed(feed: run.feed, hdr: run.profile.target.isHDR) }
            if !run.warnings.isEmpty {
                DisclosureGroup("Warnings (\(run.warnings.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(run.warnings.indices, id: \.self) {
                            Label(run.warnings[$0], systemImage: "exclamationmark.triangle").font(.callout)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        switch run.outcome {
        case .failed(let message)?:
            Banner(style: .error, title: "The run failed", message: message, nextStep: "Fix the cause, then run the session again.")
        case .cancelled?:
            Banner(style: .info, title: "Cancelled", message: run.warnings.last)
        case .completed?:
            Banner(style: .info, title: "Completed", message: "The results below were saved with the session.")
        case nil:
            EmptyView()
        }
    }
}

/// The seven stages as a row of segments.
private struct StageStrip: View {
    private static let names = ["Connect", "Signal path", "Snapshot", "Before", "Adjust", "After", "Verify"]
    let current: Int
    let count: Int
    let finished: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let done = finished || i < current
                VStack(spacing: 3) {
                    Capsule().fill(done ? Color.green : i == current ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                    Text(i < Self.names.count ? Self.names[i] : "\(i + 1)")
                        .font(.caption2)
                        .foregroundStyle(i == current && !finished ? .primary : .secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(Self.names[safe: i] ?? "Stage \(i + 1)"): \(done ? "done" : i == current ? "in progress" : "pending")")
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The latest reading large, then the ones before it.
private struct LiveFeed: View {
    let feed: [SessionRun.Reading]
    let hdr: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live measurements").font(.subheadline.weight(.semibold))
            if let latest = feed.first {
                HStack(spacing: 20) {
                    Swatch(signal: latest.stimulus, hdr: hdr).frame(width: 44, height: 44)
                    value("Stimulus", Self.describe(latest.stimulus))
                    value("x / y", Fmt.xy(latest.reading.chromaticity))
                    value("Y", Fmt.nits(latest.reading.luminance))
                    value(hdr ? "ΔE ITP" : "ΔE2000", Fmt.num(latest.deltaE))
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    ForEach(["Stage", "Stimulus", "x", "y", "Y (cd/m²)", "ΔE"], id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
                ForEach(feed.dropFirst()) { r in
                    GridRow {
                        Text(r.stage)
                        Text(Self.describe(r.stimulus))
                        Text(Fmt.num(r.reading.chromaticity.x, 4))
                        Text(Fmt.num(r.reading.chromaticity.y, 4))
                        Text(Fmt.num(r.reading.luminance, r.reading.luminance < 1 ? 4 : 2))
                        Text(Fmt.num(r.deltaE))
                    }
                    .monospacedDigit()
                }
            }
            .font(.caption)
        }
    }

    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    static func describe(_ s: SignalRGB) -> String {
        if s.isGray { return "Grey \(Fmt.stimulus(s.r))" }
        return "RGB \(Int((s.r * 100).rounded()))/\(Int((s.g * 100).rounded()))/\(Int((s.b * 100).rounded())) %"
    }
}

/// An approximate on-screen colour for a pattern signal (sRGB for SDR; PQ signals shown brighter so they stay visible).
struct Swatch: View {
    let signal: SignalRGB
    let hdr: Bool

    var body: some View {
        let lift = hdr ? 1.6 : 1.0
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(red: min(signal.r * lift, 1), green: min(signal.g * lift, 1), blue: min(signal.b * lift, 1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .accessibilityHidden(true)
    }
}
