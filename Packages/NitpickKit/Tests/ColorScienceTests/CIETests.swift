import Foundation
import Testing

@testable import ColorScience

@Test func labRoundTripAndWhite() {
    let white = Chromaticity.d65.xyz(Y: 100)
    let w = CIE.lab(white, white: white)
    #expect(close(w.L, 100, 1e-9) && close(w.a, 0, 1e-9) && close(w.b, 0, 1e-9))
    for xyz in [XYZ(X: 20, Y: 15, Z: 40), XYZ(X: 0.3, Y: 0.2, Z: 0.5), XYZ(X: 80, Y: 90, Z: 10)] {
        let back = CIE.xyz(CIE.lab(xyz, white: white), white: white)
        #expect(close(back.X, xyz.X, 1e-9) && close(back.Y, xyz.Y, 1e-9) && close(back.Z, xyz.Z, 1e-9))
    }
    #expect(close(CIE.deltaE76(Lab(L: 50, a: 0, b: 0), Lab(L: 53, a: 4, b: 0)), 5, 1e-12))
}

/// Sharma, Wu & Dalal (2005) supplementary test data, pairs 1–4, 7, 8, 13, 17, 25, 34 (ΔE00 to 4 decimals).
@Test(arguments: [
    (Lab(L: 50, a: 2.6772, b: -79.7751), Lab(L: 50, a: 0, b: -82.7485), 2.0425),
    (Lab(L: 50, a: 3.1571, b: -77.2803), Lab(L: 50, a: 0, b: -82.7485), 2.8615),
    (Lab(L: 50, a: 2.8361, b: -74.0200), Lab(L: 50, a: 0, b: -82.7485), 3.4412),
    (Lab(L: 50, a: -1.3802, b: -84.2814), Lab(L: 50, a: 0, b: -82.7485), 1.0000),
    (Lab(L: 50, a: 0, b: 0), Lab(L: 50, a: -1, b: 2), 2.3669),
    (Lab(L: 50, a: -1, b: 2), Lab(L: 50, a: 0, b: 0), 2.3669),
    (Lab(L: 50, a: 2.5, b: 0), Lab(L: 56, a: -27, b: -3), 31.9030),
    (Lab(L: 50, a: 2.5, b: 0), Lab(L: 73, a: 25, b: -18), 27.1492),
    (Lab(L: 50, a: 2.5, b: 0), Lab(L: 61, a: -5, b: 29), 22.8977),
    (Lab(L: 2.0776, a: 0.0795, b: -1.1350), Lab(L: 0.9033, a: -0.0636, b: -0.5514), 0.9082),
])
func deltaE2000SharmaPairs(_ a: Lab, _ b: Lab, _ expected: Double) {
    #expect(close(CIE.deltaE2000(a, b), expected, 5e-5))
    #expect(close(CIE.deltaE2000(b, a), expected, 5e-5))
}

@Test func deltaEITP() {
    let white100 = CIE.ictcp(Chromaticity.d65.xyz(Y: 100))
    let white110 = CIE.ictcp(Chromaticity.d65.xyz(Y: 110))
    #expect(CIE.deltaEITP(white100, white100) == 0)
    // D65 grey is neutral in ICtCp (Ct, Cp ≈ 0) and I is the PQ code of its luminance.
    #expect(abs(white100.Ct) < 1e-4 && abs(white100.Cp) < 1e-4)
    #expect(close(white100.I, PQ.inverseEOTF(100), 1e-4))
    // Recorded: ΔE_ITP(100 vs 110 cd/m² D65) = 6.909 (ΔI = 0.0096).
    #expect(close(CIE.deltaEITP(white100, white110), 6.909, 1e-3))
}

@Test func mcCamyCCTOfD65() {
    #expect(close(CIE.cct(.d65), 6504, 10))
    #expect(close(CIE.cct(Chromaticity(x: 0.44757, y: 0.40745)), 2856, 5))  // illuminant A
}

@Test func duvOfD65AndPlanckianLocus() {
    #expect(close(CIE.duv(.d65), 0.0032, 0.0010))
    // Krystek's (1985) Planckian locus fit in CIE 1960 uv, independent of the ANSI polynomial under test.
    func locus(_ t: Double) -> (u: Double, v: Double) {
        (
            (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t),
            (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        )
    }
    func xy(_ u: Double, _ v: Double) -> Chromaticity {
        let d = 2 * u - 8 * v + 4
        return Chromaticity(x: 3 * u / d, y: 2 * v / d)
    }
    for t in stride(from: 2000.0, through: 15000, by: 250) {
        let p = locus(t)
        let a = locus(t - 1)
        let b = locus(t + 1)
        #expect(abs(CIE.duv(xy(p.u, p.v))) < 3e-4, "T = \(t)")
        // 0.003 along the normal pointing to larger v (above the locus) must read Duv ≈ +0.003, below ≈ −0.003.
        let tu = b.u - a.u
        let tv = b.v - a.v
        let n = hypot(tu, tv)
        let (nu, nv) = tv < 0 ? (tv / n, -tu / n) : (-tv / n, tu / n)
        #expect(close(CIE.duv(xy(p.u + 0.003 * nu, p.v + 0.003 * nv)), 0.003, 3e-4), "T = \(t)")
        #expect(close(CIE.duv(xy(p.u - 0.003 * nu, p.v - 0.003 * nv)), -0.003, 3e-4), "T = \(t)")
    }
}

@Test func uvCoordinates() {
    let uv = CIE.uv1960(.d65)
    let uvp = CIE.uv1976(.d65)
    #expect(close(uv.u, 0.19783, 1e-5) && close(uv.v, 0.31221, 1e-5))
    #expect(close(uvp.u, 0.19783, 1e-5) && close(uvp.v, 0.46832, 1e-5))
    #expect(CIE.deltaUV(.d65, .d65) == 0)
    #expect(close(CIE.deltaUV(.d65, Chromaticity(x: 0.3127, y: 0.3390)), 0.006411, 1e-6))
}

@Test func observerTableShape() {
    #expect(CIEObserver.wavelengths.count == 81 && CIEObserver.wavelengths.first == 380 && CIEObserver.wavelengths.last == 780)
    #expect(CIEObserver.xbar.count == 81 && CIEObserver.ybar.count == 81 && CIEObserver.zbar.count == 81)
    #expect(CIEObserver.ybar.max() == 1.0 && CIEObserver.ybar.firstIndex(of: 1.0) == CIEObserver.wavelengths.firstIndex(of: 555))
}

@Test func equalEnergySpectrumIsAchromatic() {
    let c = CIEObserver.xyz(ofSpectrum: Array(repeating: 1, count: 41), startWavelength: 380, step: 10).chromaticity
    #expect(close(c.x, 1.0 / 3, 1e-4) && close(c.y, 1.0 / 3, 1e-4))
    #expect(close(CIEObserver.xyz(ofSpectrum: [1, 1], startWavelength: 380, step: 400, normalizeY: true).Y, 1, 1e-12))
}

@Test func monochromatic555Line() {
    var spd = Array(repeating: 0.0, count: 81)
    spd[35] = 1  // 555 nm
    let xyz = CIEObserver.xyz(ofSpectrum: spd, startWavelength: 380, step: 5)
    #expect(close(xyz.Y / 5, 1.0, 1e-12))  // ȳ(555) = 1, integrated over one 5 nm bin
    #expect(close(xyz.chromaticity.x, 0.3373, 1e-4) && close(xyz.chromaticity.y, 0.6589, 1e-4))  // spectrum locus at 555 nm
}
