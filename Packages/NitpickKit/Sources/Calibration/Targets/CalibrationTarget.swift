import Foundation
import ColorScience
import PatternLink

/// What a calibration aims for.
public struct CalibrationTarget: Codable, Hashable, Sendable {
    /// What the TV is expected to do above its peak for HDR10 grayscale.
    public enum HDRMapping: String, Codable, Hashable, Sendable {
        /// Static tone mapping with a roll-off below the display peak (movie modes, Dolby Vision).
        case rollOff
        /// HGiG: track PQ exactly, hard clip at the display peak (game modes).
        case hardClip
    }

    public var dynamicRange: DynamicRange
    /// Signal container colorimetry (BT.709 for SDR, BT.2020 for HDR).
    public var colorimetry: Colorimetry
    /// Absolute target EOTF (cd/m²).
    public var eotf: TargetEOTF
    public var whitePoint: Chromaticity
    /// SDR: target white luminance, cd/m². HDR: the mastering peak the content assumes.
    public var peakWhite: Double
    /// HDR: the gamut content is mastered in, inside the BT.2020 container (P3-D65).
    public var contentPrimaries: ColorSpacePrimaries?
    public var hdr10Metadata: HDR10StaticMetadata?
    public var hdrMapping: HDRMapping

    public init(dynamicRange: DynamicRange, colorimetry: Colorimetry, eotf: TargetEOTF, whitePoint: Chromaticity = .d65,
                peakWhite: Double, contentPrimaries: ColorSpacePrimaries? = nil, hdr10Metadata: HDR10StaticMetadata? = nil,
                hdrMapping: HDRMapping = .rollOff) {
        self.dynamicRange = dynamicRange; self.colorimetry = colorimetry; self.eotf = eotf; self.whitePoint = whitePoint
        self.peakWhite = peakWhite; self.contentPrimaries = contentPrimaries; self.hdr10Metadata = hdr10Metadata
        self.hdrMapping = hdrMapping
    }

    /// BT.1886, 100 cd/m², D65. Black starts at 0; the workflow replaces it with the measured black (`withBlackLevel`).
    public static let sdrMovie = CalibrationTarget(dynamicRange: .sdr, colorimetry: .bt709, eotf: .bt1886(white: 100, black: 0), peakWhite: 100)
    /// Gamma 2.2, 150 cd/m², D65.
    public static let sdrGame = CalibrationTarget(dynamicRange: .sdr, colorimetry: .bt709, eotf: .gamma(2.2, white: 150, black: 0), peakWhite: 150)
    /// PQ with P3-D65 1000 cd/m² metadata; tone-mapped above the display peak.
    public static let hdr10Movie = CalibrationTarget(dynamicRange: .hdr10, colorimetry: .bt2020, eotf: .pq, peakWhite: 1000,
                                                     contentPrimaries: .dciP3D65, hdr10Metadata: .p3D65_1000, hdrMapping: .rollOff)
    /// PQ, HGiG: hard clip at the display peak.
    public static let hdr10Game = CalibrationTarget(dynamicRange: .hdr10, colorimetry: .bt2020, eotf: .pq, peakWhite: 1000,
                                                    contentPrimaries: .dciP3D65, hdr10Metadata: .p3D65_1000, hdrMapping: .hardClip)
    /// Dolby Vision output, judged like HDR10 (frames are authored as PQ / BT.2020).
    public static let dolbyVision = CalibrationTarget(dynamicRange: .dolbyVision, colorimetry: .bt2020, eotf: .pq, peakWhite: 1000,
                                                      contentPrimaries: .dciP3D65, hdr10Metadata: .p3D65_1000, hdrMapping: .rollOff)

    public var isHDR: Bool { dynamicRange != .sdr }

    /// Container primaries with the target white.
    public var primaries: ColorSpacePrimaries {
        var p = ColorSpacePrimaries(colorimetry: colorimetry)
        p.white = whitePoint
        return p
    }

    /// How patterns for this target are encoded.
    public var format: SignalFormat { SignalFormat(colorimetry: colorimetry, transfer: isHDR ? .pq : .bt1886) }

    /// The grey level `s` actually sent after quantisation to `format`'s code values (references must use it:
    /// at 10 % a half-code error is ~1 % luminance).
    public func quantizedGray(_ s: Double) -> Double { format.signal(forCode: format.code(forSignal: s)) }

    /// Absolute XYZ an ideal display shows for `signal` (no tone mapping).
    public func reference(_ signal: SignalRGB) -> XYZ { primaries.xyz(signal: signal, eotf: eotf) }

    /// White the SDR ΔE2000 is computed against: target white at target peak. HDR uses a 100 cd/m² diffuse white
    /// (ΔE2000 is only reported for HDR; ΔE ITP is judged).
    public var referenceWhite: XYZ { whitePoint.xyz(Y: isHDR ? 100 : eotf.peakLuminance) }

    /// The same target with the SDR EOTF's black replaced (BT.1886 / gamma use the display's measured black).
    public func withBlackLevel(_ black: Double) -> CalibrationTarget {
        var t = self
        switch eotf {
        case .bt1886(let white, _): t.eotf = .bt1886(white: white, black: black)
        case .gamma(let g, let white, _): t.eotf = .gamma(g, white: white, black: black)
        case .sRGB(let white, _): t.eotf = .sRGB(white: white, black: black)
        case .pq, .hlg: break
        }
        return t
    }
}

/// The simple static roll-off shared by the simulated panel and the expected-HDR-reference model.
public enum ToneCurve {
    /// Identity up to `knee`; above it knee + (peak − knee)·(1 − (1 − t)^b) with t = (L − knee)/(source − knee) and
    /// b = (source − knee)/(peak − knee): slope 1 at the knee, `source` maps to `peak`, clipped beyond `source`.
    /// When `source ≤ peak` there is nothing to compress and the result is min(L, peak). All values cd/m².
    public static func rollOff(_ L: Double, knee: Double, peak: Double, source: Double) -> Double {
        guard source > peak, L > knee, peak > knee else { return min(L, peak) }
        guard L < source else { return peak }
        let b = (source - knee) / (peak - knee)
        return knee + (peak - knee) * (1 - pow(1 - (L - knee) / (source - knee), b))
    }
}
