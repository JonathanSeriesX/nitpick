import ColorScience
import PatternLink
import SwiftUI

/// A pattern the Apple TV can show without the Mac (App Review 4.2.3: the app works on its own with the Siri Remote).
struct BuiltInPattern: Identifiable, Hashable {
    let section: String
    let title: String
    let dynamicRange: DynamicRange
    let spec: PatternSpec
    var id: String { "\(section) \(title)" }

    static let sections: [(title: String, patterns: [BuiltInPattern])] = {
        let sdrWindows = (0...10).map { step in
            BuiltInPattern(
                section: "SDR grey windows (10 %)", title: "\(step * 10) %", dynamicRange: .sdr,
                spec: .patch(.gray(Double(step) / 10), format: .sdr))
        }
        let sdrFields = [
            BuiltInPattern(
                section: "SDR fields", title: "White", dynamicRange: .sdr,
                spec: PatternSpec(content: .fullField(.white), format: .sdr)),
            BuiltInPattern(
                section: "SDR fields", title: "Black", dynamicRange: .sdr, spec: .black(format: .sdr)),
            BuiltInPattern(
                section: "SDR fields", title: "Ramp 0–100 %", dynamicRange: .sdr,
                spec: PatternSpec(
                    content: .ramp(steps: 21, from: .black, to: .white, horizontal: true), format: .sdr)),
            BuiltInPattern(
                section: "SDR fields", title: "Clipping 90–109 %", dynamicRange: .sdr,
                spec: PatternSpec(
                    content: .bars((0..<8).map { .gray(0.90 + 0.19 * Double($0) / 7) }, background: .black),
                    format: .sdr)),
        ]
        let hdrWindows = [100.0, 200, 400, 600, 1000].map { nits in
            BuiltInPattern(
                section: "HDR10 grey windows (10 %)", title: "\(Int(nits)) nits", dynamicRange: .hdr10,
                spec: .patch(.gray(PQ.inverseEOTF(nits)), format: .hdr10, hdr10Metadata: .p3D65_1000))
        }
        let hdrClipping = BuiltInPattern(
            section: "HDR10 clipping", title: "1000–10 000 nits", dynamicRange: .hdr10,
            spec: PatternSpec(
                content: .bars(
                    [1000.0, 1500, 2000, 3000, 4000, 5000, 7500, 10000].map { .gray(PQ.inverseEOTF($0)) },
                    background: .black),
                format: .hdr10, hdr10Metadata: .bt2020_10000))
        return [
            ("SDR grey windows (10 %)", sdrWindows), ("SDR fields", sdrFields),
            ("HDR10 grey windows (10 %)", hdrWindows), ("HDR10 clipping", [hdrClipping]),
        ]
    }()
}

/// Focusable grid of built-in patterns. Menu goes back to the pairing screen.
struct StandaloneMenu: View {
    let lastSelected: BuiltInPattern.ID?
    let select: (BuiltInPattern) -> Void
    let back: () -> Void
    @FocusState private var focused: BuiltInPattern.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Patterns").font(.largeTitle.bold())
                    Text(
                        "HDR10 patterns switch the output only when Match Dynamic Range is on. Press Menu to return."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(BuiltInPattern.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 24) {
                        Text(section.title).font(.title3.weight(.semibold))
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 6), spacing: 40
                        ) {
                            ForEach(section.patterns) { pattern in
                                Button {
                                    select(pattern)
                                } label: {
                                    Text(pattern.title)
                                        .font(.headline)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity, minHeight: 110)
                                        .padding(.horizontal, 12)
                                }
                                .buttonStyle(.card)
                                .focused($focused, equals: pattern.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .defaultFocus($focused, lastSelected)
        .onExitCommand(perform: back)
        .background(Color(white: 0.06).ignoresSafeArea())
    }
}
