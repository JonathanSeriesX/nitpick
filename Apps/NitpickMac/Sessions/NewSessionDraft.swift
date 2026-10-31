import Calibration
import ColorScience
import Foundation

/// The New Session form: starts from the preset of the chosen usage and dynamic range, then applies the user's choices.
struct NewSessionDraft {
    enum EOTF: String, CaseIterable, Identifiable {
        case bt1886, gamma22, gamma24, sRGB
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bt1886: "BT.1886"
            case .gamma22: "Gamma 2.2"
            case .gamma24: "Gamma 2.4"
            case .sRGB: "sRGB"
            }
        }
    }

    enum Metadata: Int, CaseIterable, Identifiable {
        case nits1000 = 1000
        case nits4000 = 4000
        case nits10000 = 10000
        var id: Int { rawValue }
        var title: String { "\(rawValue.formatted()) cd/m²" }
        var value: HDR10StaticMetadata {
            switch self {
            case .nits1000: .p3D65_1000
            case .nits4000: .p3D65_4000
            case .nits10000: .bt2020_10000
            }
        }
    }

    var name = ""
    var usage = SessionProfile.Usage.movie
    var range = DynamicRange.sdr
    var inputID = "HDMI_1"
    var pictureMode = ""
    var eotf = EOTF.bt1886
    var peak = 100.0
    var metadata = Metadata.nits1000
    var mapping = CalibrationTarget.HDRMapping.rollOff
    var useInternalLUTs = true
    var cubeLUT = true
    var settlingMS = 800.0
    var minReads = 1
    var maxReads = 5
    var sourceSessionID: UUID?

    init(usage: SessionProfile.Usage = .movie, range: DynamicRange = .sdr) {
        self.usage = usage
        self.range = range
        applyPreset()
    }

    static let ranges: [DynamicRange] = [.sdr, .hdr10, .dolbyVision]

    var preset: SessionProfile {
        switch (range, usage) {
        case (.sdr, .movie): .movieSDR
        case (.sdr, .game): .gameSDR
        case (.hdr10, .game): .gameHDR10
        case (.dolbyVision, _): .dolbyVision(source: sourceSessionID)
        default: .movieHDR10
        }
    }

    /// Resets every field to the preset of the current usage and dynamic range.
    mutating func applyPreset() {
        if range == .dolbyVision { usage = .movie }
        let p = preset
        name = p.name
        pictureMode = p.pictureMode
        peak = p.target.isHDR ? 100 : p.target.peakWhite
        eotf =
            switch p.target.eotf {
            case .gamma(let g, _, _): g < 2.3 ? .gamma22 : .gamma24
            case .sRGB: .sRGB
            default: .bt1886
            }
        metadata = Metadata(rawValue: Int(p.target.hdr10Metadata?.maxMasteringLuminance ?? 1000)) ?? .nits1000
        mapping = p.target.hdrMapping
        useInternalLUTs = p.useInternalLUTs
        cubeLUT = p.cubeLUT
        settlingMS =
            Double(p.measurement.settlingTime.components.seconds * 1000)
            + Double(p.measurement.settlingTime.components.attoseconds) / 1e15
        minReads = p.measurement.minReads
        maxReads = p.measurement.maxReads
    }

    /// Problems that block creating the session (empty = valid).
    func problems(capabilities: TVCapabilities?) -> [String] {
        var out: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Enter a name.") }
        if range == .sdr, !(50...600).contains(peak) { out.append("Peak white must be between 50 and 600 cd/m².") }
        if minReads > maxReads { out.append("Minimum reads cannot exceed maximum reads.") }
        if range == .dolbyVision, sourceSessionID == nil {
            out.append("Choose a completed Movie HDR10 session as the source (run one first).")
        }
        if useInternalLUTs, PictureModes.isGame(pictureMode) {
            out.append("Game Optimizer modes refuse calibration uploads: turn off Internal LUTs.")
        }
        if useInternalLUTs, let capabilities, !capabilities.supportsCalibrationAPI {
            out.append("This TV's calibration API is unavailable: turn off Internal LUTs.")
        }
        if let capabilities, !capabilities.inputs.contains(where: { $0.id == inputID }) {
            out.append("The TV has no input \(inputID).")
        }
        return out
    }

    func profile() -> SessionProfile {
        var p = preset
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.inputID = inputID
        p.pictureMode = pictureMode
        if range == .sdr {
            let curve: TargetEOTF =
                switch eotf {
                case .bt1886: .bt1886(white: peak, black: 0)
                case .gamma22: .gamma(2.2, white: peak, black: 0)
                case .gamma24: .gamma(2.4, white: peak, black: 0)
                case .sRGB: .sRGB(white: peak, black: 0)
                }
            p.target = CalibrationTarget(dynamicRange: .sdr, colorimetry: .bt709, eotf: curve, peakWhite: peak)
        } else {
            p.target.hdr10Metadata = metadata.value
            p.target.peakWhite = Double(metadata.rawValue)
            if range == .hdr10 { p.target.hdrMapping = mapping }
        }
        p.useInternalLUTs = useInternalLUTs
        p.cubeLUT = range == .sdr && useInternalLUTs && cubeLUT
        p.measurement.settlingTime = .milliseconds(Int(settlingMS))
        p.measurement.minReads = minReads
        p.measurement.maxReads = maxReads
        p.sourceSessionID = range == .dolbyVision ? sourceSessionID : nil
        return p
    }
}
