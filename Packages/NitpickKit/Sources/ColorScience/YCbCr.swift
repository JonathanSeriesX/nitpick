import Foundation

/// Non-constant-luminance Y′CbCr (ITU-R BT.709 / BT.2020) quantised to integer codes.
///
/// Luma coefficients: BT.709 Kr = 0.2126, Kb = 0.0722; BT.2020 Kr = 0.2627, Kb = 0.0593 (Kg = 1 − Kr − Kb).
/// Y′ = Kr·R′ + Kg·G′ + Kb·B′, Cb = (B′ − Y′) / (2(1 − Kb)), Cr = (R′ − Y′) / (2(1 − Kr)).
/// Quantisation: luma uses `SignalFormat.code(forSignal:)` (limited 16…235·2^(n−8), full 0…2^n−1); chroma is
/// centred on `chromaZeroCode` (2^(n−1)) with scale 224·2^(n−8) (limited) or 2^n − 1 (full). All codes are clamped
/// to `legalCodes`.
public enum YCbCr {
    public static func encode(_ rgb: SignalRGB, format: SignalFormat) -> (y: Int, cb: Int, cr: Int) {
        let (kr, kb) = coefficients(format.colorimetry)
        // Written as offsets from G′ so that a grey gives Y′ == G′ and Cb == Cr == 0 exactly.
        let y = rgb.g + kr * (rgb.r - rgb.g) + kb * (rgb.b - rgb.g)
        let cb = (rgb.b - y) / (2 * (1 - kb))
        let cr = (rgb.r - y) / (2 * (1 - kr))
        let zero = Double(format.chromaZeroCode)
        let scale = chromaScale(format)
        func chroma(_ c: Double) -> Int {
            Swift.min(Swift.max(Int((zero + c * scale).rounded()), format.legalCodes.lowerBound), format.legalCodes.upperBound)
        }
        return (format.code(forSignal: y), chroma(cb), chroma(cr))
    }

    public static func decode(y: Int, cb: Int, cr: Int, format: SignalFormat) -> SignalRGB {
        let (kr, kb) = coefficients(format.colorimetry)
        let zero = Double(format.chromaZeroCode)
        let scale = chromaScale(format)
        let luma = format.signal(forCode: y)
        let pb = (Double(cb) - zero) / scale
        let pr = (Double(cr) - zero) / scale
        let r = luma + 2 * (1 - kr) * pr
        let b = luma + 2 * (1 - kb) * pb
        return SignalRGB(r: r, g: (luma - kr * r - kb * b) / (1 - kr - kb), b: b)
    }

    private static func coefficients(_ c: Colorimetry) -> (kr: Double, kb: Double) {
        switch c {
        case .bt709: (0.2126, 0.0722)
        case .bt2020: (0.2627, 0.0593)
        }
    }

    private static func chromaScale(_ f: SignalFormat) -> Double {
        f.range == .limited ? Double(224 << (f.bitDepth.rawValue - 8)) : Double((1 << f.bitDepth.rawValue) - 1)
    }
}
