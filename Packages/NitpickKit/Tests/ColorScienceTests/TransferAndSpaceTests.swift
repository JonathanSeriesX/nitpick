import Foundation
import Testing

@testable import ColorScience

func close(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

// MARK: Transfer functions

@Test func pqReferencePoints() {
    #expect(close(PQ.eotf(0.5081), 100, 0.5))
    #expect(close(PQ.eotf(0.7518), 1000, 1.5))
    #expect(close(PQ.eotf(1), 10000, 1e-6))
    #expect(PQ.eotf(0) == 0)
    #expect(close(PQ.inverseEOTF(100), 0.5081, 1e-4))
    for nits in [0.001, 0.1, 1, 48, 100, 203, 1000, 4000, 10000] {
        #expect(close(PQ.eotf(PQ.inverseEOTF(nits)), nits, nits * 1e-9))
    }
}

@Test func bt1886WithZeroBlackIsPureGamma24() {
    let eotf = TargetEOTF.bt1886(white: 100, black: 0)
    for v in stride(from: 0.0, through: 1.0, by: 0.05) {
        #expect(close(eotf.luminance(forSignal: v), 100 * pow(v, 2.4), 1e-9))
    }
}

@Test func bt1886WithBlackHitsEndpointsAndInverts() {
    let eotf = TargetEOTF.bt1886(white: 120, black: 0.05)
    #expect(close(eotf.luminance(forSignal: 0), 0.05, 1e-9))
    #expect(close(eotf.luminance(forSignal: 1), 120, 1e-9))
    #expect(close(eotf.signal(forLuminance: eotf.luminance(forSignal: 0.37)), 0.37, 1e-9))
    #expect(eotf.signal(forLuminance: 0) == 0)  // below black clamps
    #expect(eotf.signal(forLuminance: 500) == 1)
}

@Test func srgbHalfSignal() {
    #expect(close(SRGB.decode(0.5), 0.2140, 5e-5))
    #expect(close(SRGB.encode(SRGB.decode(0.03)), 0.03, 1e-12))
    #expect(close(SRGB.encode(SRGB.decode(0.8)), 0.8, 1e-12))
}

@Test func hlgPeakAndRoundTrip() {
    #expect(close(HLG.eotf(1, peak: 1000) / 1000, 1, 1e-6))
    #expect(close(HLG.eotf(1, peak: 600) / 600, 1, 1e-6))
    #expect(close(HLG.systemGamma(peak: 1000), 1.2, 1e-12))
    #expect(close(HLG.oetf(1.0 / 12), 0.5, 1e-12))
    for e in [0.0, 0.01, 1.0 / 12, 0.2, 0.5, 1] {
        #expect(close(HLG.inverseOETF(HLG.oetf(e)), e, 1e-9))
    }
}

@Test func bt709CameraOETFRoundTrip() {
    #expect(close(BT709.oetf(1), 1, 1e-12))
    for l in [0.0, 0.01, 0.018, 0.18, 0.9] {
        #expect(close(BT709.inverseOETF(BT709.oetf(l)), l, 1e-9))
    }
}

@Test func targetEOTFInversesAndPeaks() {
    let cases: [TargetEOTF] = [
        .gamma(2.2, white: 100, black: 0.1), .bt1886(white: 100, black: 0.02), .sRGB(white: 80, black: 0.2),
        .pq, .hlg(peak: 1000), .hlg(peak: 600),
    ]
    for eotf in cases {
        #expect(close(eotf.luminance(forSignal: 1), eotf.peakLuminance, eotf.peakLuminance * 1e-6))
        for v in [0.1, 0.5, 0.9] {
            #expect(close(eotf.signal(forLuminance: eotf.luminance(forSignal: v)), v, 1e-9), "\(eotf.displayName) at \(v)")
        }
    }
    #expect(TargetEOTF.gamma(2.4, white: 100, black: 0).displayName == "Gamma 2.4")
    #expect(TargetEOTF.hlg(peak: 1000).displayName == "HLG 1000 cd/m²")
}

@Test func targetEOTFCodableRoundTrip() throws {
    let cases: [TargetEOTF] = [
        .gamma(2.4, white: 100, black: 0.05), .bt1886(white: 100, black: 0), .sRGB(white: 80, black: 0), .pq, .hlg(peak: 1000),
    ]
    let decoded = try JSONDecoder().decode([TargetEOTF].self, from: JSONEncoder().encode(cases))
    #expect(decoded == cases)
    let m = Matrix3(rows: (1, 2, 3), (4, 5, 6), (7, 8, 10))
    #expect(try JSONDecoder().decode(Matrix3.self, from: JSONEncoder().encode(m)) == m)
}

// MARK: Matrix3 and primaries

@Test func matrixBasics() {
    let a = Matrix3(rows: (2, 1, 0), (0, 3, 1), (1, 0, 4))
    #expect(close(a.determinant(), 25, 1e-12))
    #expect(a[1, 2] == 1 && a[row: 2, col: 0] == 1)
    #expect(a.transposed[0, 2] == 1)
    let product = a * a.inverse!
    #expect(zip(product.m, Matrix3.identity.m).allSatisfy { close($0, $1, 1e-12) })
    #expect(Matrix3(rows: (1, 2, 3), (2, 4, 6), (0, 1, 1)).inverse == nil)
    #expect(Matrix3.scaling(2, 3, 4) * XYZ(X: 1, Y: 1, Z: 1) == XYZ(X: 2, Y: 3, Z: 4))
    #expect(Matrix3.scaling(2, 3, 4) * RGB(r: 1, g: 1, b: 1) == RGB(r: 2, g: 3, b: 4))
}

@Test func bt709WhiteIsD65AndMatrixMatchesStandard() {
    let w = ColorSpacePrimaries.bt709.xyz(fromLinear: .white)
    #expect(close(w.X, 0.9505, 5e-5) && close(w.Y, 1, 1e-12) && close(w.Z, 1.0891, 5e-5))
    let expected = [0.4124, 0.3576, 0.1805, 0.2126, 0.7152, 0.0722, 0.0193, 0.1192, 0.9505]
    #expect(zip(ColorSpacePrimaries.bt709.rgbToXYZ.m, expected).allSatisfy { close($0, $1, 5e-5) })
    let rgb = ColorSpacePrimaries.bt709.linearRGB(from: w)
    #expect(close(rgb.r, 1, 1e-12) && close(rgb.g, 1, 1e-12) && close(rgb.b, 1, 1e-12))
}

@Test func bt2020RedPrimary() {
    let red = ColorSpacePrimaries.bt2020.xyz(fromLinear: RGB(r: 1, g: 0, b: 0)).chromaticity
    #expect(close(red.x, 0.708, 1e-12) && close(red.y, 0.292, 1e-12))
    #expect(close(ColorSpacePrimaries.bt2020.rgbToXYZ[1, 0], 0.2627, 5e-5))  // BT.2020 Kr
    #expect(ColorSpacePrimaries(colorimetry: .bt2020) == .bt2020)
}

@Test func gamutContainment() {
    let p = ColorSpacePrimaries.bt709
    #expect(p.contains(.d65))
    #expect(p.contains(p.red) && p.contains(p.green))
    #expect(!p.contains(ColorSpacePrimaries.bt2020.green))
    #expect(ColorSpacePrimaries.bt2020.contains(ColorSpacePrimaries.dciP3D65.green))
}

@Test func bradfordD50ToD65MatchesLindbloom() {
    // Bruce Lindbloom's Bradford D50 → D65 matrix, built from whites D50 (0.96422, 1, 0.82521), D65 (0.95047, 1, 1.08883).
    let d50 = XYZ(X: 0.96422, Y: 1, Z: 0.82521).chromaticity
    let d65 = XYZ(X: 0.95047, Y: 1, Z: 1.08883).chromaticity
    let m = ColorSpacePrimaries.chromaticAdaptation(from: d50, to: d65)
    let expected = [0.9555766, -0.0230393, 0.0631636, -0.0282895, 1.0099416, 0.0210077, 0.0122982, -0.0204830, 1.3299098]
    #expect(zip(m.m, expected).allSatisfy { close($0, $1, 1e-6) })
    let adapted = m * XYZ(X: 0.96422, Y: 1, Z: 0.82521)
    #expect(close(adapted.X, 0.95047, 1e-6) && close(adapted.Z, 1.08883, 1e-6))
}

@Test func signalToXYZOnIdealDisplay() {
    let eotf = TargetEOTF.bt1886(white: 100, black: 0.1)
    let white = ColorSpacePrimaries.bt709.xyz(signal: .white, eotf: eotf)
    #expect(close(white.Y, 100, 1e-9))
    #expect(close(white.chromaticity.x, 0.3127, 1e-9) && close(white.chromaticity.y, 0.3290, 1e-9))
    #expect(close(ColorSpacePrimaries.bt709.xyz(signal: .black, eotf: eotf).Y, 0.1, 1e-12))
    let red = ColorSpacePrimaries.bt709.xyz(signal: SignalRGB(r: 1, g: 0, b: 0), eotf: eotf)
    #expect(close(red.Y, 0.2126 * 99.9 + 0.1, 0.01))
}
