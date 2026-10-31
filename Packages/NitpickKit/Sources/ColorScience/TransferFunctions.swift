import Foundation

/// SMPTE ST 2084 (PQ). Signal is normalised 0…1 (0 = code black, 1 = code white); luminance in cd/m², peak 10 000.
public enum PQ {
    static let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    static let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32

    /// cd/m² for signal `v` (clamped to 0…1).
    public static func eotf(_ v: Double) -> Double {
        let p = pow(Swift.min(Swift.max(v, 0), 1), 1 / m2)
        return 10000 * pow(Swift.max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// Signal 0…1 for `nits` cd/m² (clamped to 0…10 000).
    public static func inverseEOTF(_ nits: Double) -> Double {
        let y = pow(Swift.min(Swift.max(nits, 0), 10000) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
}

/// ITU-R BT.2100 Hybrid Log-Gamma.
public enum HLG {
    static let a = 0.17883277, b = 0.28466892, c = 0.55991073

    /// OETF: normalised scene-linear light E (0…1) → signal E′ (0…1).
    public static func oetf(_ linear: Double) -> Double {
        let e = Swift.max(linear, 0)
        return e <= 1.0 / 12 ? (3 * e).squareRoot() : a * log(12 * e - b) + c
    }

    /// Inverse OETF: signal E′ → normalised scene-linear light E.
    public static func inverseOETF(_ v: Double) -> Double {
        let e = Swift.max(v, 0)
        return e <= 0.5 ? e * e / 3 : (exp((e - c) / a) + b) / 12
    }

    /// BT.2100 system gamma for a display of nominal peak `peak` cd/m²: 1.2 + 0.42·log10(peak / 1000)
    /// (the formula BT.2100 gives for 400…2000 cd/m²; used unchanged outside that range).
    public static func systemGamma(peak: Double) -> Double { 1.2 + 0.42 * log10(peak / 1000) }

    /// Display luminance in cd/m² of an achromatic signal `v` (R = G = B): peak · E^γ, black level 0.
    /// `systemGamma` defaults to `systemGamma(peak:)`.
    public static func eotf(_ v: Double, peak: Double, systemGamma gamma: Double? = nil) -> Double {
        peak * pow(inverseOETF(v), gamma ?? systemGamma(peak: peak))
    }
}

/// IEC 61966-2-1 sRGB piecewise transfer function (relative, 0…1).
public enum SRGB {
    /// Signal → linear light.
    public static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    /// Linear light → signal.
    public static func encode(_ l: Double) -> Double { l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055 }
}

/// ITU-R BT.709 camera OETF (scene light → signal, relative 0…1). Not a display EOTF; SDR displays use BT.1886.
public enum BT709 {
    public static func oetf(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
    public static func inverseOETF(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v + 0.099) / 1.099, 1 / 0.45) }
}

/// A target display EOTF in **absolute** luminance: signal 0…1 (0 = reference black code, 1 = reference white code)
/// → cd/m². Signals are clamped to 0…1. Luminances apply to achromatic (grey) signals.
public enum TargetEOTF: Hashable, Codable, Sendable {
    /// Black-offset power law: L = black + (white − black)·v^γ.
    case gamma(Double, white: Double, black: Double)
    /// ITU-R BT.1886 Annex 1: L = a·max(v + b, 0)^2.4 with a = (Lw^(1/2.4) − Lb^(1/2.4))^2.4,
    /// b = Lb^(1/2.4) / (Lw^(1/2.4) − Lb^(1/2.4)).
    case bt1886(white: Double, black: Double)
    /// sRGB piecewise curve scaled between black and white: L = black + (white − black)·SRGB.decode(v).
    case sRGB(white: Double, black: Double)
    /// SMPTE ST 2084, 0…10 000 cd/m².
    case pq
    /// BT.2100 HLG with nominal peak `peak` cd/m², black 0, system gamma `HLG.systemGamma(peak:)`.
    case hlg(peak: Double)

    /// cd/m² for signal `v`.
    public func luminance(forSignal v: Double) -> Double {
        let v = Swift.min(Swift.max(v, 0), 1)
        switch self {
        case .gamma(let g, let white, let black): return black + (white - black) * pow(v, g)
        case .bt1886(let white, let black):
            let (a, b) = Self.bt1886Coefficients(white: white, black: black)
            return a * pow(Swift.max(v + b, 0), 2.4)
        case .sRGB(let white, let black): return black + (white - black) * SRGB.decode(v)
        case .pq: return PQ.eotf(v)
        case .hlg(let peak): return HLG.eotf(v, peak: peak)
        }
    }

    /// Signal 0…1 that produces `L` cd/m² (inverse of `luminance(forSignal:)`, clamped to 0…1).
    public func signal(forLuminance L: Double) -> Double {
        let v: Double
        switch self {
        case .gamma(let g, let white, let black): v = pow(Swift.max((L - black) / (white - black), 0), 1 / g)
        case .bt1886(let white, let black):
            let (a, b) = Self.bt1886Coefficients(white: white, black: black)
            v = pow(Swift.max(L, 0) / a, 1 / 2.4) - b
        case .sRGB(let white, let black): v = SRGB.encode(Swift.max((L - black) / (white - black), 0))
        case .pq: v = PQ.inverseEOTF(L)
        case .hlg(let peak): v = HLG.oetf(pow(Swift.max(L, 0) / peak, 1 / HLG.systemGamma(peak: peak)))
        }
        return Swift.min(Swift.max(v, 0), 1)
    }

    /// Luminance at signal 1, cd/m².
    public var peakLuminance: Double {
        switch self {
        case .gamma(_, let white, _), .bt1886(let white, _), .sRGB(let white, _): white
        case .pq: 10000
        case .hlg(let peak): peak
        }
    }

    public var displayName: String {
        func n(_ x: Double) -> String { String(format: "%g", x) }
        switch self {
        case .gamma(let g, _, _): return "Gamma \(n(g))"
        case .bt1886: return "BT.1886"
        case .sRGB: return "sRGB"
        case .pq: return "PQ (ST 2084)"
        case .hlg(let peak): return "HLG \(n(peak)) cd/m²"
        }
    }

    private static func bt1886Coefficients(white: Double, black: Double) -> (a: Double, b: Double) {
        let w = pow(white, 1 / 2.4)
        let k = pow(Swift.max(black, 0), 1 / 2.4)
        return (pow(w - k, 2.4), k / (w - k))
    }
}
