import Foundation

/// An additive RGB colour space defined by CIE 1931 xy chromaticities of its primaries and white point.
public struct ColorSpacePrimaries: Hashable, Codable, Sendable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity

    public init(red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.red = red
        self.green = green
        self.blue = blue
        self.white = white
    }

    /// ITU-R BT.709 (= sRGB primaries), D65.
    public static let bt709 = ColorSpacePrimaries(
        red: Chromaticity(x: 0.640, y: 0.330), green: Chromaticity(x: 0.300, y: 0.600),
        blue: Chromaticity(x: 0.150, y: 0.060), white: .d65)
    /// ITU-R BT.2020 / BT.2100, D65.
    public static let bt2020 = ColorSpacePrimaries(
        red: Chromaticity(x: 0.708, y: 0.292), green: Chromaticity(x: 0.170, y: 0.797),
        blue: Chromaticity(x: 0.131, y: 0.046), white: .d65)
    /// DCI-P3 primaries with a D65 white (SMPTE EG 432-1 "P3-D65").
    public static let dciP3D65 = ColorSpacePrimaries(
        red: Chromaticity(x: 0.680, y: 0.320), green: Chromaticity(x: 0.265, y: 0.690),
        blue: Chromaticity(x: 0.150, y: 0.060), white: .d65)
    /// Apple Display P3: the same primaries and white as `dciP3D65` (only the transfer function differs, sRGB).
    public static let displayP3 = dciP3D65

    public init(colorimetry: Colorimetry) {
        switch colorimetry {
        case .bt709: self = .bt709
        case .bt2020: self = .bt2020
        }
    }

    /// Linear RGB → XYZ, normalised so RGB(1, 1, 1) maps to the white point with Y = 1.
    /// Traps if the primaries are collinear (no valid colour space).
    public var rgbToXYZ: Matrix3 {
        let r = red.xyz(Y: 1)
        let g = green.xyz(Y: 1)
        let b = blue.xyz(Y: 1)
        let p = Matrix3(rows: (r.X, g.X, b.X), (r.Y, g.Y, b.Y), (r.Z, g.Z, b.Z))
        let s = p.inverse! * white.xyz(Y: 1)
        return p * .scaling(s.X, s.Y, s.Z)
    }

    /// XYZ → linear RGB, the inverse of `rgbToXYZ`.
    public var xyzToRGB: Matrix3 { rgbToXYZ.inverse! }

    /// Linear RGB in this space for `xyz`, in the same scale as `xyz` (Y = 1 ↔ RGB 1 for white).
    public func linearRGB(from xyz: XYZ) -> RGB { xyzToRGB * RGB(r: xyz.X, g: xyz.Y, b: xyz.Z) }

    /// XYZ of linear RGB in this space.
    public func xyz(fromLinear rgb: RGB) -> XYZ { rgbToXYZ * XYZ(X: rgb.r, Y: rgb.g, Z: rgb.b) }

    /// Whether `c` lies inside the gamut triangle in CIE 1931 xy (edges and vertices included).
    public func contains(_ c: Chromaticity) -> Bool {
        func side(_ a: Chromaticity, _ b: Chromaticity) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        let s = [side(red, green), side(green, blue), side(blue, red)]
        return !(s.contains { $0 < 0 } && s.contains { $0 > 0 })
    }

    /// Bradford chromatic adaptation XYZ → XYZ from white `from` to white `to` (both taken with Y = 1).
    public static func chromaticAdaptation(from source: Chromaticity, to destination: Chromaticity) -> Matrix3 {
        let s = bradford * source.xyz(Y: 1)
        let d = bradford * destination.xyz(Y: 1)
        return bradford.inverse! * .scaling(d.X / s.X, d.Y / s.Y, d.Z / s.Z) * bradford
    }

    private static let bradford = Matrix3(rows: (0.8951, 0.2664, -0.1614), (-0.7502, 1.7135, 0.0367), (0.0389, -0.0685, 1.0296))
}

extension ColorSpacePrimaries {
    /// Absolute XYZ (cd/m²) an ideal additive display with these primaries shows for `signal` under `eotf`.
    ///
    /// Model: the EOTF is applied per channel, black is a constant offset at the white chromaticity:
    /// L_c = eotf.luminance(v_c) − eotf.luminance(0); XYZ = rgbToXYZ · (L_r, L_g, L_b) + L_black · white.
    /// For HLG this ignores the luminance-dependent OOTF on saturated colours (exact for greys only).
    public func xyz(signal: SignalRGB, eotf: TargetEOTF) -> XYZ {
        let black = eotf.luminance(forSignal: 0)
        let l = RGB(
            r: eotf.luminance(forSignal: signal.r) - black, g: eotf.luminance(forSignal: signal.g) - black,
            b: eotf.luminance(forSignal: signal.b) - black)
        return xyz(fromLinear: l) + white.xyz(Y: black)
    }
}
