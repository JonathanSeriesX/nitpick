import Foundation
import Testing

@testable import ColorScience

// MARK: YCbCr

@Test func yCbCrReferenceCodes() {
    let limited10 = SignalFormat(colorimetry: .bt709, transfer: .bt1886, range: .limited, bitDepth: .ten)
    #expect(YCbCr.encode(.gray(0.5), format: limited10) == (502, 512, 512))
    let full8 = SignalFormat(colorimetry: .bt709, transfer: .bt1886, range: .full, bitDepth: .eight)
    #expect(YCbCr.encode(.white, format: full8) == (255, 128, 128))
    #expect(YCbCr.encode(SignalRGB(r: 1, g: 0, b: 0), format: limited10) == (250, 409, 960))  // BT.709 100 % red
    let limited8 = SignalFormat(colorimetry: .bt709, transfer: .bt1886, range: .limited, bitDepth: .eight)
    #expect(YCbCr.encode(SignalRGB(r: 1, g: 0, b: 0), format: limited8) == (63, 102, 240))
}

@Test func yCbCrGreysAreExact() {
    for colorimetry in Colorimetry.allCases {
        for range in SignalRange.allCases {
            for depth in BitDepth.allCases {
                let f = SignalFormat(colorimetry: colorimetry, transfer: .bt1886, range: range, bitDepth: depth)
                for code in f.legalCodes {
                    let v = f.signal(forCode: code)
                    let e = YCbCr.encode(.gray(v), format: f)
                    #expect(e.y == f.code(forSignal: v) && e.cb == f.chromaZeroCode && e.cr == f.chromaZeroCode)
                }
            }
        }
    }
}

@Test func codesClampAnyInputToLegalRange() {
    let f = SignalFormat.sdr  // 10-bit limited: legal 4…1019, black 64, white 940
    #expect(f.code(forSignal: 1.09) == 1019 && f.code(forSignal: -0.1) == 4)  // super-white / sub-black stay legal
    // Huge, infinite and NaN signals (a malformed pattern from the wire) must not trap in the Int conversion.
    #expect(f.code(forSignal: 1e300) == 1019 && f.code(forSignal: -.infinity) == 4 && f.code(forSignal: .nan) == 64)
    let e = YCbCr.encode(SignalRGB(r: 1e300, g: 0, b: -1e300), format: f)
    #expect(f.legalCodes.contains(e.y) && e.cb == 4 && e.cr == 1019)
    #expect(YCbCr.encode(SignalRGB(r: .nan, g: .nan, b: .nan), format: f) == (64, 512, 512))
}

@Test func yCbCrRoundTrip() {
    let f = SignalFormat(colorimetry: .bt2020, transfer: .pq, range: .limited, bitDepth: .ten)
    let rgb = SignalRGB(r: 0.62, g: 0.31, b: 0.12)
    let e = YCbCr.encode(rgb, format: f)
    let back = YCbCr.decode(y: e.y, cb: e.cb, cr: e.cr, format: f)
    #expect(close(back.r, rgb.r, 2e-3) && close(back.g, rgb.g, 2e-3) && close(back.b, rgb.b, 2e-3))
}

// MARK: LUTs

@Test func lut1DIdentity() {
    let lut = LUT1D.identity(size: 1024)
    for rgb in [RGB(r: 0, g: 0.5, b: 1), RGB(r: 0.123, g: 0.456, b: 0.789)] {
        let out = lut.apply(rgb)
        #expect(close(out.r, rgb.r, 1e-12) && close(out.g, rgb.g, 1e-12) && close(out.b, rgb.b, 1e-12))
    }
}

@Test func lut3DIdentityAndScaled() {
    let identity = LUT3D.identity(size: 17)
    let scaled = LUT3D(size: 17, nodes: identity.nodes.map { $0 * 0.5 })
    for rgb in [RGB(r: 0.1, g: 0.52, b: 0.97), RGB(r: 0.333, g: 0.666, b: 0.001), RGB.white] {
        let i = identity.apply(rgb)
        let s = scaled.apply(rgb)
        #expect(close(i.r, rgb.r, 1e-12) && close(i.g, rgb.g, 1e-12) && close(i.b, rgb.b, 1e-12))
        #expect(close(s.r, rgb.r * 0.5, 1e-12) && close(s.g, rgb.g * 0.5, 1e-12) && close(s.b, rgb.b * 0.5, 1e-12))
    }
}

// MARK: Linear algebra

@Test func gaussJordanSolve() {
    let x = LinearAlgebra.solve([[0, 2, 1], [1, 1, 1], [2, 1, 0]], [7, 6, 4])!  // zero first pivot needs a row swap
    #expect(close(x[0], 1, 1e-12) && close(x[1], 2, 1e-12) && close(x[2], 3, 1e-12))
    #expect(LinearAlgebra.solve([[1, 2], [2, 4]], [1, 2]) == nil)
    #expect(LinearAlgebra.solve([[1, 2]], [1]) == nil)
}

@Test func leastSquaresRecoversKnownMatrix() {
    let known = Matrix3(rows: (1.02, -0.015, 0.009), (0.004, 0.993, 0.006), (-0.002, 0.011, 1.049))
    let inputs = [
        XYZ(X: 41, Y: 21, Z: 2), XYZ(X: 36, Y: 72, Z: 12), XYZ(X: 18, Y: 7, Z: 95), XYZ(X: 95, Y: 100, Z: 109),
        XYZ(X: 10, Y: 10, Z: 11), XYZ(X: 60, Y: 40, Z: 30), XYZ(X: 5, Y: 30, Z: 60), XYZ(X: 70, Y: 80, Z: 20),
        XYZ(X: 0.5, Y: 0.4, Z: 0.6),
    ]
    let m = LinearAlgebra.leastSquaresMatrix(from: inputs, to: inputs.map { known * $0 })!
    #expect(zip(m.m, known.m).allSatisfy { close($0, $1, 1e-9) })
    #expect(LinearAlgebra.leastSquaresMatrix(from: Array(inputs.prefix(2)), to: Array(inputs.prefix(2))) == nil)
}

// MARK: Spectral correction

private func gaussian(_ centre: Double, _ width: Double, start: Double, step: Double, count: Int) -> [Double] {
    (0..<count).map { exp(-pow((start + Double($0) * step - centre) / width, 2) / 2) }
}

private let displaySpectra: SpectralSamples = {
    let r = gaussian(620, 15, start: 380, step: 10, count: 36)
    let g = gaussian(535, 20, start: 380, step: 10, count: 36)
    let b = gaussian(455, 12, start: 380, step: 10, count: 36)
    return SpectralSamples(startWavelength: 380, step: 10, rows: [r, g, b, zip(zip(r, g), b).map { $0.0 + $0.1 + $1 }])
}()

@Test func spectralCorrectionWithCMFSensorsIsIdentity() {
    let sensors = SpectralSamples(startWavelength: 380, step: 5, rows: [CIEObserver.xbar, CIEObserver.ybar, CIEObserver.zbar])
    let m = SpectralCorrection.matrix(sensorSensitivities: sensors, displaySamples: displaySpectra)!
    #expect(zip(m.m, Matrix3.identity.m).allSatisfy { close($0, $1, 1e-9) })
}

@Test func spectralCorrectionInvertsMixedSensors() {
    // Sensors that are linear mixes A·CMF must be corrected by A⁻¹.
    let a = Matrix3(rows: (0.8, 0.3, 0.05), (0.1, 0.9, 0.02), (0.0, 0.1, 1.2))
    let rows = (0..<3).map { r in
        (0..<81).map { a[r, 0] * CIEObserver.xbar[$0] + a[r, 1] * CIEObserver.ybar[$0] + a[r, 2] * CIEObserver.zbar[$0] }
    }
    let m = SpectralCorrection.matrix(
        sensorSensitivities: SpectralSamples(startWavelength: 380, step: 5, rows: rows), displaySamples: displaySpectra)!
    #expect(zip(m.m, a.inverse!.m).allSatisfy { close($0, $1, 1e-9) })
}

// MARK: CGATS

let ccmxFixture = """
    CCMX   

    DESCRIPTOR "LG WOLED (i1 DisplayPro vs specbos)"
    ORIGINATOR "Argyll ccxxmake"
    CREATED "Sat Oct 31 12:00:00 2026"
    KEYWORD "DEVICE"
    DEVICE "X-Rite i1 DisplayPro, ColorMunki Display"
    KEYWORD "DISPLAY"
    DISPLAY "LG OLED65C4"
    KEYWORD "TECHNOLOGY"
    TECHNOLOGY "WOLED"
    KEYWORD "DISPLAY_TYPE_REFRESH"
    DISPLAY_TYPE_REFRESH "NO"
    KEYWORD "REFERENCE"
    REFERENCE "JETI specbos 1211 # serial 123"
    KEYWORD "COLOR_REP"
    COLOR_REP "XYZ"

    NUMBER_OF_FIELDS 3
    BEGIN_DATA_FORMAT
    XYZ_X XYZ_Y XYZ_Z 
    END_DATA_FORMAT

    NUMBER_OF_SETS 3
    BEGIN_DATA
    1.021300 -0.015300 0.008700 
    0.004400 0.993200 0.006100 # green row
    -0.002100 0.011300 1.048800 
    END_DATA
    """

let ccssFixture = """
    CCSS   

    # Synthetic WOLED spectra, 380–730 nm at 50 nm
    DESCRIPTOR "WOLED (LG 2024)"
    ORIGINATOR "Argyll ccxxmake"
    CREATED "Sat Oct 31 12:00:00 2026"
    KEYWORD "DISPLAY"
    DISPLAY "LG OLED65C4"
    KEYWORD "TECHNOLOGY"
    TECHNOLOGY "WOLED"
    KEYWORD "DISPLAY_TYPE_REFRESH"
    DISPLAY_TYPE_REFRESH "NO"
    KEYWORD "DISPLAY_TYPE_BASE_ID"
    DISPLAY_TYPE_BASE_ID "1"
    KEYWORD "REFERENCE"
    REFERENCE "X-Rite i1 Pro 2"
    KEYWORD "SPECTRAL_BANDS"
    SPECTRAL_BANDS "8"
    KEYWORD "SPECTRAL_START_NM"
    SPECTRAL_START_NM "380.000000"
    KEYWORD "SPECTRAL_END_NM"
    SPECTRAL_END_NM "730.000000"
    KEYWORD "SPECTRAL_NORM"
    SPECTRAL_NORM "1.000000"

    NUMBER_OF_FIELDS 9
    BEGIN_DATA_FORMAT
    SAMPLE_ID SPEC_380 SPEC_430 SPEC_480 SPEC_530 SPEC_580 SPEC_630 SPEC_680 SPEC_730 
    END_DATA_FORMAT

    NUMBER_OF_SETS 4
    BEGIN_DATA
    1 0.0004 0.0011 0.0020 0.0062 0.1240 0.9810 0.2050 0.0094 
    2 0.0003 0.0190 0.1520 0.9930 0.4110 0.0310 0.0040 0.0006 
    3 0.0021 0.9620 0.3080 0.0210 0.0030 0.0011 0.0004 0.0001 
    4 0.0028 0.9820 0.4620 1.0200 0.5380 1.0130 0.2094 0.0101 
    END_DATA
    """

@Test func parseCCMX() throws {
    let file = try CGATS.parse(ccmxFixture)
    #expect(file.fileType == "CCMX")
    #expect(file.keywords["REFERENCE"] == "JETI specbos 1211 # serial 123")  // '#' inside quotes is data
    #expect(file.keywords["COLOR_REP"] == "XYZ" && file.keywords["KEYWORD"] == nil)
    #expect(file.fields == ["XYZ_X", "XYZ_Y", "XYZ_Z"] && file.rows.count == 3)
    #expect(file.column("XYZ_Y") == [-0.0153, 0.9932, 0.0113])
    #expect(file.column("SAMPLE_ID") == nil)

    let correction = try ColorimeterCorrection(ccmxText: ccmxFixture)
    #expect(correction.name == "LG WOLED (i1 DisplayPro vs specbos)" && correction.displayTechnology == "WOLED")
    #expect(correction.kind == .matrix([1.0213, -0.0153, 0.0087, 0.0044, 0.9932, 0.0061, -0.0021, 0.0113, 1.0488]))
}

@Test func parseCCSS() throws {
    let file = try CGATS.parse(ccssFixture)
    #expect(file.fileType == "CCSS")
    #expect(file.keywords["DISPLAY_TYPE_REFRESH"] == "NO" && file.keywords["DISPLAY_TYPE_BASE_ID"] == "1")
    #expect(file.keywords["ORIGINATOR"] == "Argyll ccxxmake" && file.keywords["DESCRIPTOR"] == "WOLED (LG 2024)")
    #expect(file.fields.count == 9 && file.rows.count == 4)
    #expect(file.column("SAMPLE_ID") == [1, 2, 3, 4])

    let correction = try ColorimeterCorrection(ccssText: ccssFixture)
    #expect(correction.name == "WOLED (LG 2024)" && correction.displayTechnology == "WOLED")
    guard case .spectral(let samples) = correction.kind else {
        Issue.record("expected spectral")
        return
    }
    #expect(samples.startWavelength == 380 && samples.step == 50 && samples.count == 8 && samples.rows.count == 4)
    #expect(samples.rows[1][3] == 0.9930)  // set 2, SPEC_530
}

@Test func cgatsRejectsMalformedFiles() {
    #expect(throws: CGATSError.empty) { try CGATS.parse("  \n# only a comment\n") }
    #expect(throws: CGATSError.missingDataFormat) { try CGATS.parse("CCMX\nDESCRIPTOR \"x\"\n") }
    #expect(throws: CGATSError.self) { try CGATS.parse(ccmxFixture.replacingOccurrences(of: "NUMBER_OF_SETS 3", with: "NUMBER_OF_SETS 4")) }
    #expect(throws: CGATSError.self) {
        try CGATS.parse(ccmxFixture.replacingOccurrences(of: "END_DATA\n", with: "").replacingOccurrences(of: "END_DATA", with: ""))
    }
    #expect(throws: CGATSError.self) { try ColorimeterCorrection(ccssText: ccmxFixture) }
    #expect(throws: CGATSError.self) { try ColorimeterCorrection(ccmxText: ccmxFixture.replacingOccurrences(of: "1.048800", with: "abc")) }
}
