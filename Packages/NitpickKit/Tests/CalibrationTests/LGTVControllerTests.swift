import ColorScience
import Foundation
import LGControl
import Testing

@testable import Calibration

/// `LGTVController` against LGControl's `FakeWebOSServer` (plain ws on 127.0.0.1, no settle or read-back delays).
@Suite(.timeLimit(.minutes(1))) struct LGTVControllerTests {
    static func fakeTV(_ configuration: FakeWebOSServer.Configuration = .init(), settle: Duration = .zero) async throws -> (
        FakeWebOSServer, LGTVController
    ) {
        let fake = FakeWebOSServer(configuration: configuration)
        let port = try await fake.start()
        let tv = LGTVController(
            host: "127.0.0.1", credentials: InMemoryTVCredentialStore(),
            options: .init(
                connection: .init(port: port, allowInsecure: true, connectTimeout: .seconds(2), requestTimeout: .seconds(2)),
                promptTimeout: .seconds(3), readbackDelay: .zero, calibrationSettleDelay: settle))
        return (fake, tv)
    }

    static func pqFrames(_ fake: FakeWebOSServer) async -> [JSON] {
        await fake.requests.filter { $0["uri"]?.stringValue == "ssap://externalpq/setExternalPqData" }.compactMap { $0["payload"] }
    }

    static func pqCommands(_ fake: FakeWebOSServer) async -> [String] { await pqFrames(fake).compactMap { $0["command"]?.stringValue } }

    static let resetCommands = [
        "1D_2_2_EN", "1D_0_45_EN", "BT709_3BY3_GAMUT_DATA", "BT2020_3BY3_GAMUT_DATA", "BT709_3D_LUT_DATA", "BT2020_3D_LUT_DATA",
        "1D_DPG_DATA",
    ]

    @Test func connectsAndReadsAndWritesPictureSettings() async throws {
        let (fake, tv) = try await Self.fakeTV()
        defer { Task { await fake.stop() } }
        try await tv.connect()
        let caps = try #require(await tv.capabilities)
        #expect(caps.modelName == "OLED65B4PUA" && caps.lut3DSize == 17 && caps.supportsCalibrationAPI)
        #expect(caps.webOSVersion?.contains("webOS 25") == true)
        #expect(caps.inputs.map(\.id) == ["HDMI_1", "HDMI_2", "HDMI_3", "HDMI_4"])

        let before = try await tv.readPictureSettings(pictureMode: nil)
        #expect(before.pictureMode == "expert2" && before.int(PictureKey.backlight) == 34)
        #expect(PictureKey.decodeTwentyPoint(before.values[PictureKey.twentyPoint]) == PictureKey.zeroTwentyPoint)

        try await tv.writePictureSettings([PictureKey.backlight: .number(40), "whiteBalanceRedGain": .number(-3)])
        #expect(await fake.pictureSetting("backlight")?.intValue == 40)
        #expect(await fake.pictureSetting("whiteBalanceRedGain")?.intValue == -3)

        // The engine's 20-point table lands on LG's 22-point arrays (index 0 = 2.5 IRE … 21 = 100 IRE).
        var table = PictureKey.zeroTwentyPoint
        table[0] = [1, 2, 3]  // 5 IRE
        table[19] = [-4, 5, -6]  // 100 IRE
        try await tv.writePictureSettings([PictureKey.twentyPoint: PictureKey.encodeTwentyPoint(table)])
        let red = try #require(await fake.pictureSetting("whiteBalanceRed")?.arrayValue?.compactMap { $0.intValue })
        #expect(red.count == 22 && red[1] == 1 && red[21] == -4 && red[0] == 0 && red[2] == 0)
        #expect(await fake.pictureSetting("whiteBalanceMethod") == "22code")
        let after = try await tv.readPictureSettings(pictureMode: nil)
        #expect(PictureKey.decodeTwentyPoint(after.values[PictureKey.twentyPoint]) == table)

        await #expect(throws: CalibrationError.outOfRange(key: "contrast", value: "101")) {
            try await tv.writePictureSettings([PictureKey.contrast: .number(101)])
        }
        // Bank ids select the matching `pictureMode` value.
        try await tv.setPictureMode("hdr_cinema")
        #expect(await fake.pictureSetting("pictureMode") == "hdrCinema")
        try await tv.setPictureMode("expert1")
        #expect(try await tv.readPictureSettings(pictureMode: nil).pictureMode == "expert1")
        try await tv.switchInput("HDMI_1")
        #expect(await fake.input == "hdmi1")
    }

    @Test func twentyPointMergesIntoTheCurrentArrays() throws {
        let array = JSON.array((0..<22).map { .number(Double($0 % 3)) })
        let current: [String: JSON] = ["whiteBalanceRed": array, "whiteBalanceGreen": array, "whiteBalanceBlue": array]
        var rows = PictureKey.zeroTwentyPoint
        rows[1] = [7, 8, 9]  // 10 IRE = LG index 3
        // A restore names the method explicitly: it must win over the multi-point method the table implies.
        let out = try LGTVController.lgSettings(
            [PictureKey.twentyPoint: PictureKey.encodeTwentyPoint(rows), "whiteBalanceMethod": .string("2")], current: current)
        #expect(out["whiteBalanceMethod"] == "2")
        let red = try #require(out["whiteBalanceRed"]?.arrayValue?.compactMap { $0.intValue })
        #expect(red[3] == 7 && red[1] == 0 && red[0] == 0 && red[2] == 2, "2.5 and 7.5 IRE keep their current values")
        #expect(out["whiteBalanceBlue"]?[3]?.intValue == 9)
        #expect(throws: CalibrationError.self) { try LGTVController.lgSettings([PictureKey.twentyPoint: .string("x")], current: current) }
    }

    @Test func uploadsNeedASessionForTheSameBank() async throws {
        let (fake, tv) = try await Self.fakeTV()
        defer { Task { await fake.stop() } }
        try await tv.connect()
        await #expect(throws: CalibrationError.self) { try await tv.sendCalibration(.upload1DLUT(.identity(), pictureMode: "expert1")) }
        await #expect(throws: CalibrationError.self) { try await tv.sendCalibration(.end(pictureMode: "expert1")) }
        #expect(await Self.pqCommands(fake).isEmpty, "nothing reached the TV")

        // 33³ cube whose red output is half the input: after resampling to the B4's 17³ grid, node (16, 0, 0) is 2048.
        let cube = LUT3D(size: 33, nodes: LUT3D.identity(size: 33).nodes.map { RGB(r: $0.r / 2, g: $0.g, b: $0.b) })
        try await tv.sendCalibration(.start(pictureMode: "expert1"))
        try await tv.sendCalibration(.upload1DLUT(.identity(), pictureMode: "expert1"))
        try await tv.sendCalibration(.upload3DLUT(cube, colorimetry: .bt709, pictureMode: "expert1"))
        await #expect(throws: CalibrationError.self) { try await tv.sendCalibration(.upload1DLUT(.identity(), pictureMode: "expert2")) }
        try await tv.sendCalibration(.end(pictureMode: "expert1"))
        #expect(await Self.pqCommands(fake) == ["CAL_START", "1D_DPG_DATA", "BT709_3D_LUT_DATA", "CAL_END"])
        let stored = try #require(await fake.uploads["expert1"]?["BT709_3D_LUT_DATA"])
        #expect(stored.count == 17 * 17 * 17 * 3)
        #expect(Array(stored.values[48..<51]) == [2048, 0, 0], "red fastest: node (16, 0, 0) is element 3·16")
        #expect(await Self.pqFrames(fake).allSatisfy { $0["picMode"] == "expert1" })

        // Reset outside a session opens and closes its own; inside one it must name the open bank.
        try await tv.sendCalibration(.resetCalibration(pictureMode: "expert1"))
        #expect(await Self.pqCommands(fake).suffix(9) == ["CAL_START"] + Self.resetCommands + ["CAL_END"])
        #expect(await fake.uploads["expert1"]?.isEmpty == true)
        #expect(await fake.calibrationSession == nil)
        try await tv.sendCalibration(.start(pictureMode: "expert1"))
        await #expect(throws: CalibrationError.self) { try await tv.sendCalibration(.resetCalibration(pictureMode: "expert2")) }
        try await tv.sendCalibration(.resetCalibration(pictureMode: "expert1"))
        try await tv.sendCalibration(.end(pictureMode: "expert1"))
        #expect(await fake.calibrationSession == nil)
    }

    @Test func webOS26HasNoCalibrationAPI() async throws {
        let (fake, tv) = try await Self.fakeTV(.init(platform: .webOS26))
        defer { Task { await fake.stop() } }
        try await tv.connect()
        let caps = try #require(await tv.capabilities)
        #expect(!caps.supportsCalibrationAPI)
        let error = await #expect(throws: CalibrationError.self) { try await tv.sendCalibration(.start(pictureMode: "expert1")) }
        guard case .refused(let message)? = error else {
            Issue.record("expected refused, got \(String(describing: error))")
            return
        }
        #expect(message.contains("webOS 26"))
        #expect(await Self.pqCommands(fake).isEmpty)
    }

    /// The whole engine with the real LG adapter: simulated meter and pattern source, `FakeWebOSServer` as the TV.
    /// The simulated panel does not see the LG uploads, so the result is not judged — only the TV-side protocol is.
    /// LG settles after every externalpq command (3 s by default; 0.2 s here), so a bank reset (9 commands) outlasts the
    /// per-call device timeout (10 s by default; 1 s here): calibration commands need their own, longer deadline.
    @Test func movieSDRWorkflowDrivesTheLGTV() async throws {
        let rig = Rig(seed: 23)
        let (fake, tv) = try await Self.fakeTV(settle: .milliseconds(200))
        defer { Task { await fake.stop() } }
        var events: [WorkflowEvent] = []
        let stream = WorkflowRunner(deviceTimeout: .seconds(1)).run(
            profile: .movieSDR, devices: (rig.meter, rig.source, tv), session: CalibrationSession(profile: .movieSDR), sleeper: rig.clock)
        for try await event in stream { events.append(event) }
        let result = try #require(events.result, "\(events.failure ?? "no result")")

        #expect(
            await Self.pqCommands(fake)
                == ["CAL_START"] + Self.resetCommands + [
                    "CAL_END", "CAL_START", "1D_DPG_DATA", "CAL_END", "CAL_START", "BT709_3D_LUT_DATA", "CAL_END",
                ])
        #expect(await Self.pqFrames(fake).allSatisfy { $0["picMode"] == "expert1" })
        #expect(result.lutsUploaded == ["1D LUT expert1", "3D LUT 33³ bt709 expert1"])
        #expect(await fake.uploads["expert1"].map { Set($0.keys) } == ["1D_DPG_DATA", "BT709_3D_LUT_DATA"])
        #expect(await fake.calibrationSession == nil)
        #expect(await fake.input == "hdmi1")
        #expect(await fake.pictureSetting("pictureMode") == "expert1")
        #expect(result.adjustments.contains { $0.control == PictureKey.backlight })
        #expect(result.restorePoint?.settings.pictureMode == "expert1")
    }
}
