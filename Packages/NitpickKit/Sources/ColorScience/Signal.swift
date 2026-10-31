import Foundation

/// Colour primaries + YCbCr matrix family carried by the video signal.
public enum Colorimetry: String, Codable, Sendable, CaseIterable {
    case bt709
    case bt2020
}

/// Transfer characteristic of the signal container. SDR uses the BT.1886 display EOTF convention.
public enum TransferCharacteristic: String, Codable, Sendable, CaseIterable {
    case bt1886
    case pq
    case hlg
}

/// Limited ("video") or full ("PC") code range.
public enum SignalRange: String, Codable, Sendable, CaseIterable {
    case limited
    case full
}

public enum BitDepth: Int, Codable, Sendable, CaseIterable {
    case eight = 8
    case ten = 10
}

/// The display/output mode a pattern source should be in. Distinct from `TransferCharacteristic`:
/// Dolby Vision is an output mode negotiated with the TV, while the frames we author stay PQ.
public enum DynamicRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        case .dolbyVision: "Dolby Vision"
        }
    }
}

/// How a pattern frame is encoded on the wire to the TV.
public struct SignalFormat: Hashable, Codable, Sendable {
    public var colorimetry: Colorimetry
    public var transfer: TransferCharacteristic
    public var range: SignalRange
    public var bitDepth: BitDepth

    public init(colorimetry: Colorimetry, transfer: TransferCharacteristic, range: SignalRange = .limited, bitDepth: BitDepth = .ten) {
        self.colorimetry = colorimetry
        self.transfer = transfer
        self.range = range
        self.bitDepth = bitDepth
    }

    public static let sdr = SignalFormat(colorimetry: .bt709, transfer: .bt1886)
    public static let hdr10 = SignalFormat(colorimetry: .bt2020, transfer: .pq)
    public static let hlg = SignalFormat(colorimetry: .bt2020, transfer: .hlg)

    /// The format normally used to drive a given output mode. Dolby Vision frames are authored as PQ/BT.2020.
    public static func standard(for dynamicRange: DynamicRange) -> SignalFormat {
        switch dynamicRange {
        case .sdr: .sdr
        case .hdr10, .dolbyVision: .hdr10
        case .hlg: .hlg
        }
    }

    /// Code value of reference black for this range/bit depth (64 for 10-bit limited).
    public var blackCode: Int { range == .limited ? 16 << (bitDepth.rawValue - 8) : 0 }
    /// Code value of reference white (940 for 10-bit limited).
    public var whiteCode: Int { range == .limited ? 235 << (bitDepth.rawValue - 8) : (1 << bitDepth.rawValue) - 1 }
    /// Legal code range (10-bit limited video excludes 0–3 and 1020–1023, which are timing references).
    public var legalCodes: ClosedRange<Int> {
        range == .limited ? (1 << (bitDepth.rawValue - 8))...((1 << bitDepth.rawValue) - 1 - (1 << (bitDepth.rawValue - 8)))
                          : 0...((1 << bitDepth.rawValue) - 1)
    }
    /// Achromatic chroma code (512 for 10-bit).
    public var chromaZeroCode: Int { 1 << (bitDepth.rawValue - 1) }

    /// Quantises a normalised signal (0 = reference black, 1 = reference white) to a legal code value.
    public func code(forSignal v: Double) -> Int {
        let c = (Double(blackCode) + v * Double(whiteCode - blackCode)).rounded()
        return Swift.min(Swift.max(Int(c), legalCodes.lowerBound), legalCodes.upperBound)
    }

    /// Normalised signal for a code value (may fall outside 0…1 for sub-black / super-white codes).
    public func signal(forCode c: Int) -> Double {
        Double(c - blackCode) / Double(whiteCode - blackCode)
    }
}

/// A colour expressed as normalised R'G'B' signal: 0 = reference black, 1 = reference white (nominal peak for SDR,
/// 10 000 cd/m² for PQ). Values outside 0…1 are allowed to author sub-black/super-white clipping tests.
public struct SignalRGB: Hashable, Codable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public init(gray v: Double) { self.init(r: v, g: v, b: v) }
    public init(_ rgb: RGB) { self.init(r: rgb.r, g: rgb.g, b: rgb.b) }

    /// Builds a signal that quantises exactly to the given code values in `format`.
    public init(codes r: Int, _ g: Int, _ b: Int, in format: SignalFormat) {
        self.init(r: format.signal(forCode: r), g: format.signal(forCode: g), b: format.signal(forCode: b))
    }

    public static let black = SignalRGB(gray: 0)
    public static let white = SignalRGB(gray: 1)
    public static func gray(_ v: Double) -> SignalRGB { SignalRGB(gray: v) }

    public var rgb: RGB { RGB(r: r, g: g, b: b) }
    public var isGray: Bool { r == g && g == b }

    /// Code values after quantisation into `format`.
    public func codes(in format: SignalFormat) -> (r: Int, g: Int, b: Int) {
        (format.code(forSignal: r), format.code(forSignal: g), format.code(forSignal: b))
    }

    /// The signal as actually representable in `format` (after quantisation).
    public func quantized(in format: SignalFormat) -> SignalRGB {
        let c = codes(in: format)
        return SignalRGB(codes: c.r, c.g, c.b, in: format)
    }
}

/// HDR10 static metadata (SMPTE ST 2086 mastering display + CTA-861 content light levels).
public struct HDR10StaticMetadata: Hashable, Codable, Sendable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity
    /// cd/m²
    public var maxMasteringLuminance: Double
    /// cd/m²
    public var minMasteringLuminance: Double
    /// MaxCLL in cd/m²; 0 = unknown.
    public var maxContentLightLevel: Int
    /// MaxFALL in cd/m²; 0 = unknown.
    public var maxFrameAverageLightLevel: Int

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity = .d65,
                maxMasteringLuminance: Double, minMasteringLuminance: Double = 0.0001,
                maxContentLightLevel: Int = 0, maxFrameAverageLightLevel: Int = 0) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
        self.maxMasteringLuminance = maxMasteringLuminance
        self.minMasteringLuminance = minMasteringLuminance
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    }

    public static let p3D65 = (red: Chromaticity(x: 0.680, y: 0.320), green: Chromaticity(x: 0.265, y: 0.690), blue: Chromaticity(x: 0.150, y: 0.060))

    /// P3-D65 mastering display, 1000 nits, MaxCLL 1000 / MaxFALL 400 — the most common consumer HDR10 metadata.
    public static let p3D65_1000 = HDR10StaticMetadata(red: p3D65.red, green: p3D65.green, blue: p3D65.blue,
                                                       maxMasteringLuminance: 1000, maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400)
    /// P3-D65 mastering display, 4000 nits.
    public static let p3D65_4000 = HDR10StaticMetadata(red: p3D65.red, green: p3D65.green, blue: p3D65.blue,
                                                       maxMasteringLuminance: 4000, maxContentLightLevel: 4000, maxFrameAverageLightLevel: 1000)
    /// BT.2020 mastering display, 10 000 nits (exercises the TV's full tone-mapping range).
    public static let bt2020_10000 = HDR10StaticMetadata(red: Chromaticity(x: 0.708, y: 0.292), green: Chromaticity(x: 0.170, y: 0.797), blue: Chromaticity(x: 0.131, y: 0.046),
                                                         maxMasteringLuminance: 10000, maxContentLightLevel: 10000, maxFrameAverageLightLevel: 4000)
}
