import Calibration
import ColorScience
import SwiftUI

/// One grayscale point prepared for the charts.
struct GrayRow: Identifiable {
    var id: Double { stimulus }
    /// Stimulus in percent.
    let stimulus: Double
    let deltaE: Double
    let measured: Double
    let target: Double
    let inRollOff: Bool
    /// RGB balance: % deviation of each linear channel from the target white at the measured luminance (nil below 5 %).
    let balance: (r: Double, g: Double, b: Double)?

    /// Stimuli are quantised to code values (5 % → 5.02 %), so labels round to whole percent.
    /// Judged like the summary: ≥ 5 % stimulus and not in the expected roll-off (lower points are meter noise).
    var judged: Bool { stimulus >= 4.9 && !inRollOff }

    var label: String { "\(Int(stimulus.rounded()))" }

    static func rows(_ set: MeasurementSet, target: CalibrationTarget) -> [GrayRow] {
        let hdr = set.dynamicRange != .sdr
        let primaries = target.primaries
        return set.grayscale.map { p in
            let m = p.error.measured
            var balance: (Double, Double, Double)?
            if p.stimulus >= 0.049, m.Y > 0 {
                let rgb = primaries.linearRGB(from: m)
                let ref = primaries.linearRGB(from: target.whitePoint.xyz(Y: m.Y))
                balance = ((rgb.r / ref.r - 1) * 100, (rgb.g / ref.g - 1) * 100, (rgb.b / ref.b - 1) * 100)
            }
            return GrayRow(
                stimulus: p.stimulus * 100, deltaE: p.error.value(hdr: hdr), measured: m.Y, target: p.error.reference.Y,
                inRollOff: p.error.inRollOff, balance: balance)
        }
    }
}

/// One colour patch prepared for the charts and the verification table.
struct PatchRow: Identifiable {
    let id: Int
    let patch: ColorPatchResult
    let deltaE: Double
    let pass: Bool

    var name: String { patch.name }

    static func rows(_ patches: [ColorPatchResult], hdr: Bool, limit: Double) -> [PatchRow] {
        patches.enumerated().map { i, p in
            let de = p.error.value(hdr: hdr)
            return PatchRow(id: i, patch: p, deltaE: de, pass: de <= limit)
        }
    }
}

extension Tolerances {
    func grayMax(hdr: Bool) -> Double { hdr ? hdrGrayscaleMaxITP : grayscaleMax }
    func colorLimit(hdr: Bool) -> Double { hdr ? hdrColorMaxITP : colorMax }
}

/// Pass/fail/neutral colours used by charts and summary cards.
enum Verdict {
    case pass, fail, info

    init(_ value: Double, limit: Double?) {
        guard let limit else {
            self = .info
            return
        }
        self = value <= limit ? .pass : .fail
    }

    var color: Color {
        switch self {
        case .pass: .green
        case .fail: .red
        case .info: .secondary
        }
    }

    var title: String {
        switch self {
        case .pass: "pass"
        case .fail: "fail"
        case .info: "information"
        }
    }
}

enum ChartColors {
    /// A saturated on-screen colour for a chromaticity (BT.709 / sRGB, normalised to its brightest channel).
    static func color(_ c: Chromaticity) -> Color {
        let rgb = ColorSpacePrimaries.bt709.linearRGB(from: c.xyz(Y: 1))
        let r = max(rgb.r, 0)
        let g = max(rgb.g, 0)
        let b = max(rgb.b, 0)
        let top = max(r, g, b, 1e-6)
        return Color(red: SRGB.encode(r / top), green: SRGB.encode(g / top), blue: SRGB.encode(b / top))
    }
}

/// A chart with a title and a short explanation.
struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        Card(title: title, subtitle: subtitle) { content }
    }
}
