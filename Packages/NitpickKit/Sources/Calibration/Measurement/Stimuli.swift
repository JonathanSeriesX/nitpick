import Foundation
import ColorScience

/// Standard stimulus sets. Signals are normalised R′G′B′ in the target's container (BT.709 SDR, BT.2020 PQ HDR).
public enum Stimuli {
    /// SDR: 0…100 % in 5 % steps. HDR: the same plus 1, 2 and 3 % PQ.
    public static func grayscale(_ dynamicRange: DynamicRange) -> [Double] {
        let base = (0...20).map { Double($0) / 20 }
        return dynamicRange == .sdr ? base : ([0.01, 0.02, 0.03] + base).sorted()
    }

    public static let nearBlack = [0.01, 0.02, 0.03, 0.04]

    static let hues: [(String, RGB)] = [("Red", RGB(r: 1, g: 0, b: 0)), ("Green", RGB(r: 0, g: 1, b: 0)), ("Blue", RGB(r: 0, g: 0, b: 1)),
                                        ("Cyan", RGB(r: 0, g: 1, b: 1)), ("Magenta", RGB(r: 1, g: 0, b: 1)), ("Yellow", RGB(r: 1, g: 1, b: 0))]

    /// SDR: R, G, B, C, M, Y at 100 % and 75 % signal. HDR: the BT.2020 container primaries/secondaries at 100 % and
    /// 75 % saturation at 50 % PQ — they probe the display's native gamut limits (used by the Dolby Vision builder).
    public static func primariesSecondaries(_ target: CalibrationTarget) -> [(name: String, signal: SignalRGB)] {
        if target.isHDR {
            return [1.0, 0.75].flatMap { sat in
                hues.map { ("\($0.0) \(Int(sat * 100))%", desaturated($0.1, saturation: sat, nits: PQ.eotf(0.5), in: target.primaries, target: target)) }
            }
        }
        return [1.0, 0.75].flatMap { level in hues.map { ("\($0.0) \(Int(level * 100))%", SignalRGB($0.1 * level)) } }
    }

    /// 25/50/75/100 % saturation for R, G, B, C, M, Y at constant luminance. SDR: in the target space at 75 % stimulus.
    /// HDR: in P3-D65 inside BT.2020 at 50 % PQ.
    public static func saturationSweeps(_ target: CalibrationTarget) -> [(name: String, signal: SignalRGB)] {
        let space = target.isHDR ? (target.contentPrimaries ?? .dciP3D65) : target.primaries
        let nits = target.isHDR ? PQ.eotf(0.5) : target.eotf.luminance(forSignal: 0.75) - target.eotf.luminance(forSignal: 0)
        return hues.flatMap { hue in
            [0.25, 0.5, 0.75, 1.0].map { sat in ("\(hue.0) \(Int(sat * 100))% sat", desaturated(hue.1, saturation: sat, nits: nits, in: space, target: target)) }
        }
    }

    /// ColorChecker Classic (published sRGB 8-bit values, D65) shown at the target's white (SDR) or at 100 cd/m²
    /// diffuse white (HDR), plus 12 seeded random patches. Never fed to an optimizer.
    public static func verification(_ target: CalibrationTarget, seed: UInt64 = 0x5EED_C0DE) -> [(name: String, signal: SignalRGB)] {
        let white = target.isHDR ? 100 : target.eotf.luminance(forSignal: 1) - target.eotf.luminance(forSignal: 0)
        var out = colorChecker.map { patch -> (name: String, signal: SignalRGB) in
            let linear = RGB(r: SRGB.decode(Double(patch.1) / 255), g: SRGB.decode(Double(patch.2) / 255), b: SRGB.decode(Double(patch.3) / 255))
            return (patch.0, encode(ColorSpacePrimaries.bt709.xyz(fromLinear: linear) * white, target: target))
        }
        var random = SeededRandom(seed: seed)
        for i in 1...12 {
            let signal: SignalRGB
            if target.isHDR {
                let p3 = RGB(r: random.uniform(), g: random.uniform(), b: random.uniform())
                signal = encode((target.contentPrimaries ?? .dciP3D65).xyz(fromLinear: p3) * 150, target: target)
            } else {
                signal = SignalRGB(r: 0.05 + 0.9 * random.uniform(), g: 0.05 + 0.9 * random.uniform(), b: 0.05 + 0.9 * random.uniform())
            }
            out.append(("Random \(i)", signal))
        }
        return out
    }

    /// `hue` (unit linear RGB in `space`) at `nits` cd/m² per full channel, mixed with the equal-luminance grey.
    static func desaturated(_ hue: RGB, saturation: Double, nits: Double, in space: ColorSpacePrimaries, target: CalibrationTarget) -> SignalRGB {
        let full = space.xyz(fromLinear: hue * nits)
        let gray = space.white.xyz(Y: full.Y)
        return encode(gray + (full - gray) * saturation, target: target)
    }

    /// Signal that makes the ideal target display show absolute `xyz` (out-of-container channels clip at 0).
    static func encode(_ xyz: XYZ, target: CalibrationTarget) -> SignalRGB {
        let black = target.eotf.luminance(forSignal: 0)
        let linear = target.primaries.linearRGB(from: xyz)
        return SignalRGB(linear.map { target.eotf.signal(forLuminance: max($0, 0) + black) })
    }

    /// X-Rite ColorChecker Classic, sRGB 8-bit.
    public static let colorChecker: [(String, Int, Int, Int)] = [
        ("Dark skin", 115, 82, 68), ("Light skin", 194, 150, 130), ("Blue sky", 98, 122, 157), ("Foliage", 87, 108, 67),
        ("Blue flower", 133, 128, 177), ("Bluish green", 103, 189, 170), ("Orange", 214, 126, 44), ("Purplish blue", 80, 91, 166),
        ("Moderate red", 193, 90, 99), ("Purple", 94, 60, 108), ("Yellow green", 157, 188, 64), ("Orange yellow", 224, 163, 46),
        ("Blue", 56, 61, 150), ("Green", 70, 148, 73), ("Red", 175, 54, 60), ("Yellow", 231, 199, 31),
        ("Magenta", 187, 86, 149), ("Cyan", 8, 133, 161), ("White 9.5", 243, 243, 242), ("Neutral 8", 200, 200, 200),
        ("Neutral 6.5", 160, 160, 160), ("Neutral 5", 122, 122, 121), ("Neutral 3.5", 85, 85, 85), ("Black 2", 52, 52, 52),
    ]
}
