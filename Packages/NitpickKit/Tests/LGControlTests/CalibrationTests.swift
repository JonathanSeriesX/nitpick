import ColorScience
import Foundation
import Testing

@testable import LGControl

@Suite struct CalibrationTests {
    private func connected(_ configuration: FakeWebOSServer.Configuration = .init()) async throws -> (FakeWebOSServer, LGTV, LGCalibration)
    {
        let (fake, tv) = try await makeTV(configuration)
        try await tv.connect(host: "127.0.0.1")
        let cal = try await tv.calibration()
        #expect(cal.profile?.lut3DSize == 17)
        return (fake, tv, cal)
    }

    private func pqCommands(_ fake: FakeWebOSServer) async -> [String] {
        await requests(fake, uri: "externalpq/setExternalPqData").compactMap { $0["payload"]?["command"]?.stringValue }
    }

    @Test func sessionOrderingIsEnforcedClientSide() async throws {
        let (fake, _, cal) = try await connected()
        await #expect(throws: LGError.self) { try await cal.upload1DLUT(.identity()) }
        await #expect(throws: LGError.self) { try await cal.setValue(.backlightUI, 40) }
        await #expect(throws: LGError.self) { try await cal.bypass() }
        await #expect(throws: LGError.self) { try await cal.end() }
        #expect(await pqCommands(fake).isEmpty)  // nothing reached the TV
        try await cal.start(.expert2)
        await #expect(throws: LGError.self) { try await cal.start(.expert1) }
        try await cal.end()
        #expect(await cal.session == nil)
        await fake.stop()
    }

    @Test func sessionOrderingIsEnforcedByTheFake() async throws {
        let (fake, tv, _) = try await connected()
        let e = await lgError {
            try await tv.request(
                "externalpq/setExternalPqData",
                payload: [
                    "command": "BACKLIGHT_UI_DATA", "picMode": "expert2", "profileNo": 0,
                    "programID": 1, "data": "JwA=", "dataCount": 1,
                    "dataType": "unsigned integer16", "dataOpt": 1,
                ])
        }
        guard case .server(500, _, let payload) = e else {
            Issue.record("expected 500, got \(String(describing: e))")
            return
        }
        #expect(payload["errorCode"] == 20)
        let end = await lgError {
            try await tv.request(
                "externalpq/setExternalPqData", payload: ["command": "CAL_END", "picMode": "expert2", "profileNo": 0, "programID": 1])
        }
        #expect(end?.serverCode == 500)
        await fake.stop()
    }

    @Test func sdrBypassSequenceAndWireFormat() async throws {
        let (fake, _, cal) = try await connected()
        try await cal.start(.expert2)
        #expect(await fake.pictureSetting("colorGamut") == "wide")
        #expect(await fake.pictureSetting("colorTemperature") == "50")
        try await cal.bypass()
        try await cal.setValue(.backlightUI, 39)
        try await cal.end()
        #expect(
            await pqCommands(fake) == [
                "CAL_START", "1D_2_2_EN", "1D_0_45_EN", "BT709_3BY3_GAMUT_DATA", "BT2020_3BY3_GAMUT_DATA",
                "BT709_3D_LUT_DATA", "BT2020_3D_LUT_DATA", "1D_DPG_DATA", "BACKLIGHT_UI_DATA", "CAL_END",
            ])
        let frames = await requests(fake, uri: "externalpq/setExternalPqData")
        #expect(frames[0]["payload"] == ["command": "CAL_START", "profileNo": 0, "programID": 1, "picMode": "expert2"])
        #expect(
            frames[8]["payload"] == [
                "command": "BACKLIGHT_UI_DATA", "picMode": "expert2", "profileNo": 0, "programID": 1,
                "data": "JwA=", "dataCount": 1, "dataType": "unsigned integer16", "dataOpt": 1,
            ])
        let lut = try #require(frames[5]["payload"])
        #expect(lut["dataCount"] == 14739 && lut["dataType"] == "unsigned integer16")
        #expect(
            sha256(Data(base64Encoded: lut["data"]!.stringValue!)!) == "7bf3000f247f76254a920e17b1ed23e6e12edacfbf493c99f7527e5f9b3e44ab")
        #expect(frames.allSatisfy { $0["payload"]?["picMode"] == "expert2" })
        await fake.stop()
    }

    @Test func calStartFormsAndRejection() async throws {
        let (fake, _, cal) = try await connected()
        // HDR bank while the TV shows SDR: both forms fail with driver error 20; no CAL_END follows a rejection.
        let e = await lgError { try await cal.start(.hdrCinema) }
        #expect(e?.serverCode == 500)
        #expect(await pqCommands(fake) == ["CAL_START", "CAL_START"])
        #expect(await cal.session == nil)
        try await cal.start(.expert2, form: .zeroFloats)
        let last = try #require(await requests(fake, uri: "externalpq/setExternalPqData").last)
        #expect(
            last["payload"] == [
                "command": "CAL_START", "picMode": "expert2", "profileNo": 0, "programID": 1,
                "data": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "dataCount": 9, "dataType": "float", "dataOpt": 1,
            ])
        try await cal.end()
        await fake.stop()
    }

    @Test func cancelledStartSendsNothingAndOpensNothing() async throws {
        let (fake, _, cal) = try await connected()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await cal.start(.expert2)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await cal.session == nil)
        #expect(await pqCommands(fake).isEmpty)
        try await cal.start(.expert2)
        try await cal.end()
        await fake.stop()
    }

    @Test func toneMapNeedsHDR10Session() async throws {
        let (sdrFake, _, sdr) = try await connected()
        try await sdr.start(.expert2)
        await #expect(throws: LGError.self) { try await sdr.uploadToneMap(.init()) }
        await sdrFake.stop()

        let (fake, _, cal) = try await connected(.init(dynamicRange: "hdr"))
        try await cal.start(.hdrCinema)
        try await cal.uploadToneMap(LGToneMapParameters(panelPeak: 760, rolloff1: 75))
        let frame = try #require(await requests(fake, uri: "externalpq/setExternalPqData").last)
        #expect(frame["payload"]?["data"] == "+ALoA0sAoA88ABAnMgA=" && frame["payload"]?["picMode"] == "hdr_cinema")
        try await cal.end()
        await fake.stop()
    }

    @Test func dolbyConfigUploadUsesProfileFormat() async throws {
        let (fake, _, cal) = try await connected(.init(dynamicRange: "dolbyHdr"))
        try await cal.start(.dolbyGame)
        let config = DolbyVisionDisplayConfig(
            pictureMode: .dolbyGame, tMax: 820, red: .init(x: 0.6796, y: 0.3187),
            green: .init(x: 0.2595, y: 0.6849), blue: .init(x: 0.1448, y: 0.0494))
        try await cal.uploadDolbyConfig(config)
        let frame = try #require(await requests(fake, uri: "externalpq/setExternalPqData").last)
        #expect(frame["payload"]?["dataCount"] == 135 && frame["payload"]?["dataType"] == "unsigned char")
        #expect(frame["payload"]?["data"]?.stringValue?.hasPrefix("W1BpY3R1cmVNb2RlID0gNF0NCl") == true)
        var other = config
        other.pictureMode = .dolbyCinemaDark
        await #expect(throws: LGError.self) { try await cal.uploadDolbyConfig(other) }
        try await cal.end()
        await fake.stop()
    }

    @Test func factoryResetSendsEmptyDataWithOpt2() async throws {
        let (fake, _, cal) = try await connected()
        try await cal.start(.expert2)
        try await cal.resetToFactory()
        try await cal.end()
        let resets = await requests(fake, uri: "externalpq/setExternalPqData").filter { $0["payload"]?["dataOpt"] == 2 }
        #expect(resets.count == 7)
        #expect(resets.allSatisfy { $0["payload"]?["data"] == "" && $0["payload"]?["dataCount"] == 0 && $0["payload"]?["dataType"] != nil })
        await fake.stop()
    }

    @Test func readbackRoundTripsUploads() async throws {
        let (fake, _, cal) = try await connected()
        // Nothing uploaded yet: the TV's "no file path" error.
        let none = await lgError { _ = try await cal.read(.lut1D) }
        guard case .server(500, _, let payload) = none else {
            Issue.record("expected 500")
            return
        }
        #expect(payload["errorText"] == "no file path from tvservice")

        let curve = (0..<1024).map { pow(Double($0) / 1023, 1.1) }
        let lut = LUT1D(red: curve, green: curve.map { $0 * 0.98 }, blue: curve)
        var lut3D = LUT3D.identity(size: 17)
        lut3D[3, 5, 7] = RGB(r: 1, g: 0, b: 0.5)
        let m = Matrix3(rows: (0.4, 0.3, 0.2), (0.2, 0.4, 0.3), (0.3, 0.2, 0.4))
        try await cal.start(.expert2)
        try await cal.upload1DLUT(lut)
        try await cal.upload3DLUT(lut3D)
        try await cal.uploadMatrix(m)
        try await cal.setValue(.degamma22Enable, 1)
        try await cal.end()

        let r1 = try await cal.read(.lut1D)
        #expect(r1.raw == (try ExternalPQEncoder.lut1D(lut)).values && r1.isPlausible)
        guard case .lut1D(let back) = r1.value else {
            Issue.record("not a 1D LUT")
            return
        }
        #expect(zip(back.green, lut.green).allSatisfy { abs($0 - $1) < 1.0 / 32767 })

        let r3 = try await cal.read(.lut3D)
        guard case .lut3D(let back3) = r3.value else {
            Issue.record("not a 3D LUT")
            return
        }
        #expect(
            back3.size == 17 && back3[3, 5, 7] == RGB(r: 4095.0 / 4096, g: 0, b: 0.5)
                && back3[16, 0, 0] == RGB(r: 4095.0 / 4096, g: 0, b: 0))
        #expect(r3.isPlausible)

        guard case .matrix(let mBack) = try await cal.read(.gamut).value else {
            Issue.record("not a matrix")
            return
        }
        #expect(zip(mBack.m, m.m).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(try await cal.read(.degamma22).value == .flag(true))
        await fake.stop()
    }

    @Test func readbackDecodesSpecFixtureAndFlagsImplausibleData() throws {
        let g = try ExternalPQReadback(
            getter: .gamut,
            payload: [
                "returnValue": true, "data": "zczMPpqZmT7NzEw+zcxMPs3MzD6amZk+mpmZPs3MTD7NzMw+",
                "dataCount": 9, "dataType": "float",
            ])
        guard case .matrix(let m) = g.value else {
            Issue.record("not a matrix")
            return
        }
        #expect(abs(m[0, 1] - 0.3) < 1e-6 && abs(m[1, 0] - 0.2) < 1e-6 && g.isPlausible)
        let zeros = ExternalPQEncoder.le(Array(repeating: 0, count: 3072)).base64EncodedString()
        let crushed = try ExternalPQReadback(
            getter: .lut1D, payload: ["data": .string(zeros), "dataCount": 3072, "dataType": "unsigned integer16"])
        #expect(!crushed.isPlausible)
        #expect(throws: LGError.self) {
            try ExternalPQReadback(getter: .lut1D, payload: ["data": "AAA=", "dataCount": 1, "dataType": "unsigned integer16"])
        }
        #expect(ExternalPQReadback.label == "TV readback (processed, not a factory backup)")
    }

    @Test func picModeMapping() {
        #expect(LGPicMode(pictureMode: "dolbyHdrCinema") == .dolbyCinemaDark)
        #expect(LGPicMode(pictureMode: "hdrFilmMaker") == .hdrFilmMaker)
        #expect(LGPicMode(pictureMode: "vivid") == nil)
        #expect(LGPicMode.dolbyCinemaDark.rawValue == "dolby_cinema_dark" && LGPicMode.dolbyGame.dolbyConfigIndex == 4)
        #expect(LGPicMode.hdrGame.signalClass == .hdr10 && LGPicMode.filmMaker.signalClass == .sdr)
    }
}
