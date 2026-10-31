import ColorScience
import Foundation
import Testing

@testable import LGControl

@Suite struct EncoderTests {
    @Test func unity1DLUTMatchesSpecHash() throws {
        let d = try ExternalPQEncoder.lut1D(.identity())
        #expect(d.count == 3072 && d.bytes.count == 6144 && d.base64.count == 8192 && d.dataType == .uint16)
        #expect(sha256(d.bytes) == "51a5362cea91bfcea487c7160c249f3ae0380fc4d3028b6c0b5036dfafa0dd80")
        // Calman's capture: i * 32.
        let ramp = (0..<1024).map { Double($0 * 32) / 32767 }
        let calman = try ExternalPQEncoder.lut1D(LUT1D(red: ramp, green: ramp, blue: ramp))
        #expect(sha256(calman.bytes) == "351e9a3ca08b509767a04ad8080300980f97b63580804549cfbe8c7e50681af6")
        #expect(calman.base64.hasPrefix("AAAgAEAAYACAAKAAwADgAAAB"))
        // Any input size is resampled to 1024 points.
        #expect(try ExternalPQEncoder.lut1D(.identity(size: 256)).bytes == d.bytes)
    }

    @Test func unity3DLUTsMatchSpecHashes() throws {
        let d17 = try ExternalPQEncoder.lut3D(.identity(size: 17), size: 17)
        #expect(d17.count == 14739 && d17.bytes.count == 29478 && d17.base64.count == 39304)
        #expect(sha256(d17.bytes) == "7bf3000f247f76254a920e17b1ed23e6e12edacfbf493c99f7527e5f9b3e44ab")
        #expect(Array(d17.values.prefix(9)) == [0, 0, 0, 256, 0, 0, 512, 0, 0])  // R fastest
        let d33 = try ExternalPQEncoder.lut3D(.identity(size: 33), size: 33)
        #expect(d33.count == 107811 && d33.base64.count == 287496)
        #expect(sha256(d33.bytes) == "ac797aeab6521e160c8cf765662b8bd7cd608e4b1512dbc12587d75d03d39391")
    }

    @Test func singleNodeLandsAtRedFastestIndex() throws {
        var lut = LUT3D.identity(size: 17)
        lut[3, 5, 7] = RGB(r: 1, g: 0, b: 0.5)
        let values = try ExternalPQEncoder.lut3D(lut, size: 17).values
        let base = try ExternalPQEncoder.lut3D(.identity(size: 17), size: 17).values
        let flat = 3 * (3 + 17 * 5 + 17 * 17 * 7)
        #expect(Array(values[flat..<(flat + 3)]) == [4095, 0, 2048])
        let differing = zip(values, base).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(Set(differing).isSubset(of: [flat, flat + 1, flat + 2]) && !differing.isEmpty)
    }

    @Test func resample33To17KeepsIdentity() throws {
        let resampled = try ExternalPQEncoder.lut3D(.identity(size: 33), size: 17)
        #expect(sha256(resampled.bytes) == "7bf3000f247f76254a920e17b1ed23e6e12edacfbf493c99f7527e5f9b3e44ab")
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut3D(.identity(size: 9), size: 17) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut3D(.identity(size: 17), size: 33) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut3D(.identity(size: 17), size: 17, command: .lut1D) }
    }

    @Test func matrixAndScalarBytes() throws {
        #expect(try ExternalPQEncoder.matrix(.identity).base64 == "AACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/")
        let m = Matrix3(rows: (0.4, 0.3, 0.2), (0.2, 0.4, 0.3), (0.3, 0.2, 0.4))
        #expect(try ExternalPQEncoder.matrix(m, command: .bt2020Gamut).base64 == "zczMPpqZmT7NzEw+zcxMPs3MzD6amZk+mpmZPs3MTD7NzMw+")
        let expected = [0: "AAA=", 39: "JwA=", 50: "MgA=", 85: "VQA=", 100: "ZAA="]
        for (v, b64) in expected { #expect(try ExternalPQEncoder.value(v, command: .contrastUI).base64 == b64) }
        #expect(try ExternalPQEncoder.value(1, command: .degamma22Enable).base64 == "AQA=")
        #expect(throws: LGError.self) { try ExternalPQEncoder.value(2, command: .gamutEnable) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.value(101, command: .backlightUI) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.value(1, command: .lut1D) }
        let tone = LGToneMapParameters(
            panelPeak: 760, masteringPeak1: 1000, rolloff1: 75, masteringPeak2: 4000, rolloff2: 60, masteringPeak3: 10000, rolloff3: 50)
        #expect(try ExternalPQEncoder.toneMap(tone).base64 == "+ALoA0sAoA88ABAnMgA=")
        #expect(LGToneMapParameters().values == [700, 1000, 70, 4000, 60, 10000, 50])
        #expect(ExternalPQEncoder.calStartZeros.base64 == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test func validatorRefusesBadData() throws {
        func refuses(_ data: ExternalPQData, size: Int? = 17, _ comment: Comment) {
            #expect(throws: LGError.self, comment) { try PayloadValidator.validate(data, lut3DSize: size) }
        }
        var bad = LUT1D.identity()
        bad.red[10] = .nan
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut1D(bad) }
        bad.red[10] = 1.01
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut1D(bad) }
        bad.red[10] = -0.2
        #expect(throws: LGError.self) { try ExternalPQEncoder.lut1D(bad) }

        var dip = LUT1D.identity()
        dip.green[500] = 0.1
        refuses(try ExternalPQEncoder.lut1D(dip), "non-monotonic 1D")
        try PayloadValidator.validate(
            try ExternalPQEncoder.lut1D(
                LUT1D(
                    red: Array(repeating: 0.5, count: 1024), green: Array(repeating: 0.5, count: 1024),
                    blue: Array(repeating: 0.5, count: 1024))), lut3DSize: 17)  // flats allowed

        refuses(ExternalPQData(command: .lut1D, dataType: .uint16, bytes: Data(count: 10), count: 3072), "byte count")
        refuses(ExternalPQData(command: .lut1D, dataType: .uint16, bytes: Data(count: 20), count: 10), "element count")
        refuses(
            ExternalPQData(
                command: .lut1D, dataType: .uint16, bytes: ExternalPQEncoder.le(Array(repeating: 40000, count: 3072)), count: 3072),
            "1D > 32767")
        refuses(
            ExternalPQData(
                command: .bt709LUT3D, dataType: .uint16, bytes: ExternalPQEncoder.le(Array(repeating: 5000, count: 14739)), count: 14739),
            "3D > 4095")
        refuses(try ExternalPQEncoder.lut3D(.identity(size: 17), size: 17), size: nil, "unknown 3D size")
        refuses(try ExternalPQEncoder.lut3D(.identity(size: 17), size: 17), size: 33, "wrong 3D size")
        refuses(ExternalPQData(command: .bt709Gamut, dataType: .uint16, bytes: Data(count: 18), count: 9), "wrong dataType")
        refuses(ExternalPQEncoder.floats([.nan, 0, 0, 0, 1, 0, 0, 0, 1], command: .bt709Gamut), "NaN matrix")
        refuses(ExternalPQEncoder.floats([2000, 0, 0, 0, 1, 0, 0, 0, 1], command: .bt709Gamut), "matrix > 1024")
        refuses(
            ExternalPQData(
                command: .toneMap, dataType: .uint16, bytes: ExternalPQEncoder.le([700, 1000, 101, 4000, 60, 10000, 50]), count: 7),
            "rolloff 101")
        refuses(ExternalPQData(command: .dolbyConfig, dataType: .uint8, bytes: Data([0x41, 0x00]), count: 2), "non-printable DV text")
        #expect(throws: LGError.self) { try ExternalPQEncoder.matrix(Matrix3([2000, 0, 0, 0, 1, 0, 0, 0, 1])) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.toneMap(LGToneMapParameters(panelPeak: 50)) }
        #expect(throws: LGError.self) { try ExternalPQEncoder.dolbyConfig("Tmax = 700 ✓") }
    }

    @Test func dolbyVisionConfig2019MatchesBscpylgtvVector() throws {
        let fixture =
            "W1BpY3R1cmVNb2RlID0gNF0NClRtYXggPSA4MjAuMDAwMA0KVG1pbiA9IDAuMDAwMQ0KVGdhbW1hID0gMi4yDQpUUHJpbWFyaWVzID0gMC42Nzk2IDAuMzE4NyAwLjI1OTUgMC42ODQ5IDAuMTQ0OCAwLjA0OTQgMC4zMTI3IDAuMzI5MA0K"
        let config = DolbyVisionDisplayConfig(
            pictureMode: .dolbyGame, tMax: 820, red: .init(x: 0.6796, y: 0.3187),
            green: .init(x: 0.2595, y: 0.6849), blue: .init(x: 0.1448, y: 0.0494))
        let data = try ExternalPQEncoder.dolbyConfig(config.text(format: .v2019))
        #expect(data.base64 == fixture && data.count == 135)
        let file = try DolbyVisionDisplayConfig.usbFile([config], date: "2026-10-31")
        #expect(
            file.hasPrefix(
                "# Dolby Vision User Display Configuration File\r\n# Generated by Nitpick on 2026-10-31\r\n# Display: Unspecified\r\n# DM Version: \r\n[PictureMode = 4]\r\n"
            ))
        #expect(throws: LGError.self) {
            try DolbyVisionDisplayConfig(pictureMode: .expert2, tMax: 700, red: .d65, green: .d65, blue: .d65).text(format: .v2019)
        }
        #expect(throws: LGError.self) {
            try DolbyVisionDisplayConfig(pictureMode: .dolbyGame, tMax: 5000, red: .d65, green: .d65, blue: .d65).text(format: .v2019)
        }
    }

    @Test func dolbyVisionConfig2018MatchesBscpylgtvVector() throws {
        let config = DolbyVisionDisplayConfig(
            pictureMode: .dolbyCinemaDark, tMax: 710, red: .init(x: 0.6796, y: 0.3187),
            green: .init(x: 0.2595, y: 0.6849), blue: .init(x: 0.1448, y: 0.0494))
        let lines = try config.text(format: .v2018).components(separatedBy: "\r\n")
        #expect(
            Array(lines.prefix(5)) == [
                "PictureMode = 2", "Tmax = 710.0000", "Tmin = 0.0001", "Tgamma = 2.2",
                "ColorPrimaries = 0.6796 0.3187 0.2595 0.6849 0.1448 0.0494 0.3127 0.3290",
            ])
        let expected = [
            4.18278398329451, -3.30049295101940, 0.117749870955320, -0.882467140762750, 2.01734548281183,
            -0.134865869784530, 0.0437827473048400, -0.107670286757020, 1.06391551060750,
        ]
        let printed = lines[5].replacingOccurrences(of: "TLMS2RGBmat = ", with: "").split(separator: " ").compactMap { Double($0) }
        #expect(printed.count == 9)
        for (a, b) in zip(printed, expected) { #expect(abs(a - b) < 1e-9 * max(1, abs(b)), "\(a) vs \(b)") }
        #expect(lines.last == "")  // CRLF-terminated
    }
}
