import Foundation
import Testing

@testable import LGControl

@Suite struct SettingsTests {
    @Test func systemInfoAndModelProfile() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        let info = try await tv.systemInfo()
        #expect(info.modelName == "OLED65B4PUA")
        let sw = try #require(info.software)
        #expect(sw.modelToken == "HE_DTV_W24H_AFADATAA" && sw.firmwareVersion == "33.31.75")
        #expect(sw.release == WebOSRelease(major: 10, minor: 3))
        #expect(info.profile == LGModelProfile(modelName: "W24H"))
        #expect(info.profile?.lut3DSize == 17 && info.profile?.dolbyConfigFormat == .v2019 && info.profile?.supportsGamutMatrix == true)
        #expect(try await tv.macAddresses() == LGMACAddresses(wired: "a8:23:fe:00:11:22", wifi: "a8:23:fe:00:11:23"))
        try await tv.toast("Calibrating")
        #expect(await fake.toasts == ["Calibrating"])
        await fake.stop()
    }

    @Test func modelProfileTable() {
        #expect(LGModelProfile(modelName: "HE_DTV_W24H_AFADATAA")?.chipType == "W24H")
        #expect(LGModelProfile(modelName: "HE_DTV_W24H_AFADATAA")?.lut3DSize == 17)
        #expect(LGModelProfile(modelName: "W24O")?.lut3DSize == 33)
        #expect(LGModelProfile(modelName: "W25G")?.lut3DSize == 33)
        #expect(LGModelProfile(modelName: "W18H")?.dolbyConfigFormat == .v2018)
        #expect(LGModelProfile(modelName: "W18O")?.lut3DSize == 33)
        #expect(LGModelProfile(modelName: "W17H")?.lut3DSize == nil)
        #expect(LGModelProfile(modelName: "W19H")?.supportsHDRGamutMatrix == true)
        #expect(LGModelProfile(modelName: "W24H")?.supportsHDRGamutMatrix == false)
        #expect(LGModelProfile(modelName: "W27H") == nil)
        #expect(LGModelProfile(modelName: "garbage") == nil)
        #expect(WebOSRelease(firmwareMajor: "43")?.major == 11)
        #expect(WebOSRelease(firmwareMajor: "23")?.marketingVersion == 24)
        #expect(WebOSRelease(version: "webOSTV 10.3") == WebOSRelease(major: 10, minor: 3))
        #expect(WebOSRelease(version: "11.1.0")?.blocksThirdPartyCalibration == true)
    }

    @Test func readPictureSettings() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        let s = try await tv.getPictureSettings()
        #expect(s.count == LGPictureKeys.calibrationRelevant.count)
        #expect(s["pictureMode"] == "expert2" && s["backlight"] == "34" && s["blackLevel"]?["paln"] == "high")
        #expect(try LGWhiteBalance2Point(settings: s) == LGWhiteBalance2Point())
        #expect(try LGWhiteBalanceMultiPoint(settings: s).pointCount == 22)
        #expect(try await tv.currentPictureMode() == "expert2")
        // An unknown key is dropped and the rest re-read (errorKey handling).
        let partial = try await tv.getPictureSettings(keys: ["backlight", "hgig"])
        #expect(partial == ["backlight": "34"])
        let frame = try #require(await requests(fake, uri: "settings/getSystemSettings").last)
        #expect(frame["payload"] == ["category": "picture", "keys": ["backlight"]])
        await fake.stop()
    }

    @Test func lunaBridgeWriteIsVerifiedByReadBack() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        let result = try await tv.setPictureSettings(["backlight": "40", "contrast": 85])
        #expect(result.isVerified && result.applied == ["backlight", "contrast"])
        #expect(await fake.pictureSetting("backlight") == "40")

        // createAlert carries the luna call in buttons, onclose and onfail (SPEC §3.7), then closeAlert fires it.
        let alert = try #require(await requests(fake, uri: "system.notifications/createAlert").first)
        let params: JSON = ["category": "picture", "settings": ["backlight": "40", "contrast": 85]]
        #expect(alert["payload"]?["onclose"] == ["uri": "luna://com.webos.settingsservice/setSystemSettings", "params": params])
        #expect(alert["payload"]?["onfail"] == alert["payload"]?["onclose"])
        #expect(alert["payload"]?["buttons"]?[0]?["onClick"] == "luna://com.webos.settingsservice/setSystemSettings")
        #expect(alert["payload"]?["message"] == " ")
        let close = try #require(await requests(fake, uri: "system.notifications/closeAlert").first)
        #expect(close["payload"]?["alertId"]?.stringValue?.hasPrefix("com.webos.service.apiadapter-") == true)
        await fake.stop()
    }

    @Test func closeAlertFallsBackToRawID() async throws {
        let (fake, tv) = try await makeTV(.init(acceptsRewrittenAlertID: false))
        try await tv.connect(host: "127.0.0.1")
        let result = try await tv.setPictureSetting(key: "brightness", value: 52)
        #expect(result.isVerified)
        let ids = await requests(fake, uri: "system.notifications/closeAlert").compactMap { $0["payload"]?["alertId"]?.stringValue }
        #expect(
            ids.count == 2 && ids[0].hasPrefix("com.webos.service.apiadapter-") && ids[1].hasPrefix("com.webos.service.apiadapter.pub-"))
        await fake.stop()
    }

    @Test func unappliedWriteIsReported() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        // `gammaLevel` is valid (webOS 25+) but this fake's picture store does not hold it: the luna call is a no-op.
        let r = try await tv.setPictureSettings(["gammaLevel": 1, "contrast": 90])
        #expect(r.applied == ["contrast"] && r.notApplied == ["gammaLevel"] && !r.isVerified)
        // Dimension writes cannot be read back over SSAP.
        let d = try await tv.setSystemSettings(category: "picture$hdmi1.expert2.2d.x", settings: ["backlight": "10"])
        #expect(d.readBack.isEmpty && !d.isVerified)
        #expect(await fake.pictureSetting("backlight") == "34")  // hdmi2 untouched
        await fake.stop()
    }

    @Test func pictureModeSetAndInputDimension() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        #expect(try await tv.setPictureMode("cinema").isVerified)
        #expect(try await tv.currentPictureMode() == "cinema")
        try await tv.switchInput("HDMI_1")
        #expect(try await tv.foregroundApp() == "com.webos.app.hdmi1")
        #expect(try await tv.currentPictureMode() == "expert2")  // per [input, dynamicRange]
        _ = fake
        await fake.stop()
    }

    @Test func rangeValidation() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        await #expect(throws: LGError.outOfRange(key: "backlight", value: "101", allowed: "integer 0…100")) {
            _ = try await tv.setPictureSetting(key: "backlight", value: 101)
        }
        let cases: [(String, JSON)] = [
            ("tint", -51), ("whiteBalanceRedGain", 51), ("colorTemperature", "x"), ("gamma", "2.4"), ("contrast", 50.5),
            ("pictureMode", "turbo"), ("whiteBalanceRed", .array(Array(repeating: 0, count: 21))), ("DtmMastering1k", 55),
            ("colorManagementHueRed", 31), ("blackLevel", ["ntsc": "full"]), ("whiteBalanceLuminance", 40),
        ]
        for (key, value) in cases {
            #expect(throws: LGError.self, "\(key)=\(value)") { try LGPictureKeys.validate(key: key, value: value) }
        }
        #expect(throws: LGError.unsupported("no documented range for picture key DtmMasteringFoo")) {
            try LGPictureKeys.validate(key: "DtmMasteringFoo", value: 1)
        }
        try LGPictureKeys.validate(key: "whiteBalanceBlueOffset", value: "-50")
        try LGPictureKeys.validate(key: "hdrDynamicToneMapping", value: "HGIG")
        try LGPictureKeys.validate(key: "whiteBalanceGreen", value: .array(Array(repeating: 3, count: 24)))
        #expect(await requests(fake, uri: "system.notifications/createAlert").isEmpty)  // nothing was sent
        await fake.stop()
    }

    @Test func whiteBalanceEncoders() throws {
        let two = LGWhiteBalance2Point(redGain: -3, greenGain: 0, blueGain: 5, redOffset: 1, greenOffset: -2, blueOffset: 0)
        let s = try two.settings()
        #expect(s["whiteBalanceRedGain"] == "-3" && s["whiteBalanceBlueGain"] == "5" && s.count == 6)
        #expect(try LGWhiteBalance2Point(settings: s) == two)
        #expect(throws: LGError.self) { try LGWhiteBalance2Point(redGain: 60).settings() }

        let red = [0, 2, 0, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -2, -2, -2, -1, -1, -2, 0, 0]
        let multi = try LGWhiteBalanceMultiPoint(red: red, green: Array(repeating: 0, count: 22), blue: Array(repeating: 1, count: 22))
        let m = try multi.settings()
        #expect(m["whiteBalanceMethod"] == "22code" && m["whiteBalanceRed"] == .array(red.map { .number(Double($0)) }))
        #expect(try LGWhiteBalanceMultiPoint(settings: m) == multi)
        #expect(LGWhiteBalanceMultiPoint.ireLevels(count: 22)?.first == 2.5 && LGWhiteBalanceMultiPoint.ireLevels(count: 22)?.last == 100)
        #expect(LGWhiteBalanceMultiPoint.ireLevels(count: 24)?.count == 24 && LGWhiteBalanceMultiPoint.ireLevels(count: 10)?.count == 10)
        let ten = try LGWhiteBalanceMultiPoint(
            red: Array(repeating: 1, count: 10), green: Array(repeating: 0, count: 10), blue: Array(repeating: 0, count: 10))
        #expect(try ten.settings()["whiteBalanceRed10pt"] != nil)
        #expect(throws: LGError.self) { try LGWhiteBalanceMultiPoint(red: [1], green: [1], blue: [1]) }
    }
}
