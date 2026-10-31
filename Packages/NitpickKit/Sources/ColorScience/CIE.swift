import Foundation

/// CIE 1976 L*a*b*.
public struct Lab: Hashable, Codable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// ITU-R BT.2100 ICtCp (PQ variant). I ≈ PQ signal of luminance; Ct, Cp are colour-difference axes.
public struct ICtCp: Hashable, Codable, Sendable {
    public var I: Double
    public var Ct: Double
    public var Cp: Double

    public init(I: Double, Ct: Double, Cp: Double) {
        self.I = I
        self.Ct = Ct
        self.Cp = Cp
    }
}

/// CIE colour-difference, uniform-space and correlated-colour-temperature formulas.
public enum CIE {
    // MARK: L*a*b*

    /// L*a*b* of `xyz` relative to the reference `white` (same units, e.g. both in cd/m²).
    public static func lab(_ xyz: XYZ, white: XYZ) -> Lab {
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        let fx = f(xyz.X / white.X)
        let fy = f(xyz.Y / white.Y)
        let fz = f(xyz.Z / white.Z)
        return Lab(L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// Inverse of `lab(_:white:)`.
    public static func xyz(_ lab: Lab, white: XYZ) -> XYZ {
        let fy = (lab.L + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        func finv(_ f: Double) -> Double { f * f * f > epsilon ? f * f * f : (116 * f - 16) / kappa }
        let yr = lab.L > kappa * epsilon ? fy * fy * fy : lab.L / kappa
        return XYZ(X: finv(fx) * white.X, Y: yr * white.Y, Z: finv(fz) * white.Z)
    }

    private static let epsilon = 216.0 / 24389, kappa = 24389.0 / 27

    // MARK: Colour differences

    /// CIE 1976 ΔE*ab (Euclidean distance in L*a*b*).
    public static func deltaE76(_ a: Lab, _ b: Lab) -> Double {
        ((a.L - b.L) * (a.L - b.L) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// CIEDE2000 with kL = kC = kH = 1, following Sharma, Wu & Dalal (2005), "The CIEDE2000 color-difference formula:
    /// implementation notes, supplementary test data, and mathematical observations".
    public static func deltaE2000(_ x: Lab, _ y: Lab) -> Double {
        let deg = Double.pi / 180
        let pow25to7 = 6_103_515_625.0  // 25^7
        let cBar = (hypot(x.a, x.b) + hypot(y.a, y.b)) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow25to7)).squareRoot())
        let a1 = (1 + g) * x.a
        let a2 = (1 + g) * y.a
        let c1 = hypot(a1, x.b)
        let c2 = hypot(a2, y.b)
        func hue(_ a: Double, _ b: Double) -> Double {
            guard a != 0 || b != 0 else { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(a1, x.b)
        let h2 = hue(a2, y.b)

        let dL = y.L - x.L
        let dC = c2 - c1
        var dh = 0.0
        if c1 * c2 != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (c1 * c2).squareRoot() * sin(dh / 2 * deg)

        let lBar = (x.L + y.L) / 2
        let cBarP = (c1 + c2) / 2
        var hBar = h1 + h2
        if c1 * c2 != 0 {
            if abs(h1 - h2) <= 180 { hBar /= 2 } else if hBar < 360 { hBar = (hBar + 360) / 2 } else { hBar = (hBar - 360) / 2 }
        }
        let t =
            1 - 0.17 * cos((hBar - 30) * deg) + 0.24 * cos(2 * hBar * deg) + 0.32 * cos((3 * hBar + 6) * deg)
            - 0.20 * cos((4 * hBar - 63) * deg)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rC = 2 * (pow(cBarP, 7) / (pow(cBarP, 7) + pow25to7)).squareRoot()
        let sL = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * deg) * rC
        let l = dL / sL
        let c = dC / sC
        let h = dH / sH
        return (l * l + c * c + h * h + rT * c * h).squareRoot()
    }

    // MARK: ICtCp

    /// BT.2100 ICtCp (PQ) of absolute XYZ in cd/m². XYZ → linear BT.2020 RGB (D65) → LMS with BT.2100's crosstalk
    /// matrix (1688, 2146, 262 / 683, 2951, 462 / 99, 309, 3688)/4096 → ST 2084 inverse EOTF → ICtCp.
    public static func ictcp(_ xyz: XYZ) -> ICtCp {
        let lms = xyzToLMS * xyz
        let l = PQ.inverseEOTF(lms.X)
        let m = PQ.inverseEOTF(lms.Y)
        let s = PQ.inverseEOTF(lms.Z)
        return ICtCp(I: 0.5 * l + 0.5 * m, Ct: (6610 * l - 13613 * m + 7003 * s) / 4096, Cp: (17933 * l - 17390 * m - 543 * s) / 4096)
    }

    private static let xyzToLMS =
        Matrix3(([1688, 2146, 262, 683, 2951, 462, 99, 309, 3688] as [Double]).map { $0 / 4096 })
        * ColorSpacePrimaries.bt2020.xyzToRGB

    /// ITU-R BT.2124 ΔE_ITP = 720·√(ΔI² + ΔT² + ΔP²) with T = 0.5·Ct, P = Cp. 1.0 ≈ one just-noticeable difference.
    public static func deltaEITP(_ a: ICtCp, _ b: ICtCp) -> Double {
        let dI = a.I - b.I
        let dT = 0.5 * (a.Ct - b.Ct)
        let dP = a.Cp - b.Cp
        return 720 * (dI * dI + dT * dT + dP * dP).squareRoot()
    }

    // MARK: Chromaticity metrics

    /// CIE 1960 UCS (u, v).
    public static func uv1960(_ c: Chromaticity) -> (u: Double, v: Double) {
        let d = -2 * c.x + 12 * c.y + 3
        return (4 * c.x / d, 6 * c.y / d)
    }

    /// CIE 1976 UCS (u′, v′).
    public static func uv1976(_ c: Chromaticity) -> (u: Double, v: Double) {
        let d = -2 * c.x + 12 * c.y + 3
        return (4 * c.x / d, 9 * c.y / d)
    }

    /// Δu′v′: Euclidean distance in CIE 1976 u′v′, the usual greyscale tint metric.
    public static func deltaUV(_ a: Chromaticity, _ b: Chromaticity) -> Double {
        let p = uv1976(a)
        let q = uv1976(b)
        return hypot(p.u - q.u, p.v - q.v)
    }

    /// Correlated colour temperature in kelvin by McCamy's (1992) cubic: within ~2 K of the exact CCT for 2856…6504 K
    /// near the Planckian locus; degrades far from it.
    public static func cct(_ c: Chromaticity) -> Double {
        let n = (c.x - 0.3320) / (0.1858 - c.y)
        return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    }

    /// Duv: signed distance from the Planckian locus in CIE 1960 (u, v), positive above (greenish), negative below
    /// (magenta). Uses the polynomial approximation of ANSI C78.377-2015 / Ohno (2014, LEUKOS 10:1); it agrees with
    /// Krystek's (1985) Planckian locus within 3e-4 over 2000…15 000 K (checked in tests).
    public static func duv(_ c: Chromaticity) -> Double {
        let (u, v) = uv1960(c)
        let lfp = hypot(u - 0.292, v - 0.24)
        let a = acos((u - 0.292) / lfp)
        let k: [Double] = [-0.471106, 1.925865, -2.4243787, 1.5317403, -0.5179722, 0.0893944, -0.00616793]
        let lbb = k.reversed().reduce(0) { $0 * a + $1 }
        return lfp - lbb
    }
}
