import Foundation

/// webOS platform release. Platform 9 = webOS 24, 10 = webOS 25, 11 = webOS 26 (SPEC §1).
public struct WebOSRelease: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int = 0) {
        self.major = major
        self.minor = minor
    }

    /// From `deviceOSReleaseVersion` (`"10.3.0"`) or `product_name` (`"webOSTV 10.3"`).
    public init?(version: String) {
        let numeric = version.split(separator: " ").last.map(String.init) ?? version
        let parts = numeric.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        self.init(major: major, minor: parts.count > 1 ? parts[1] : 0)
    }

    /// From the firmware major version of 2024+ firmware families: `23` → 9, `33` → 10, `43` → 11.
    public init?(firmwareMajor: String) {
        guard let n = Int(firmwareMajor), n >= 23, n % 10 == 3 else { return nil }
        self.init(major: (n - 3) / 10 + 7)
    }

    /// Marketing name year: 24 for platform 9.
    public var marketingVersion: Int { major + 15 }
    /// webOS 26 (platform ≥ 11) blocks third-party calibration and blacklists the signed manifest (SPEC §0).
    public var blocksThirdPartyCalibration: Bool { major >= 11 }
    public var description: String { "\(major).\(minor) (webOS \(marketingVersion))" }

    public static func < (a: WebOSRelease, b: WebOSRelease) -> Bool { (a.major, a.minor) < (b.major, b.minor) }
}

/// Calibration capabilities derived from the chip type (`model_name[7..<11]`, e.g. `W24H` from `HE_DTV_W24H_AFADATAA`),
/// per bscpylgtv `calibration_support_info` (SPEC §5.5).
public struct LGModelProfile: Sendable, Hashable {
    public enum DolbyConfigFormat: String, Sendable, Hashable {
        /// Unbracketed `PictureMode = N` + `ColorPrimaries` + `TLMS2RGBmat`.
        case v2018
        /// Bracketed `[PictureMode = N]` + `TPrimaries`.
        case v2019
    }

    /// e.g. `W24H` (B4/C4 class α8/α9 H chips), `W24O`, `W24G`.
    public var chipType: String
    /// 3D LUT grid points per axis (17 or 33); nil = no 3D LUT upload.
    public var lut3DSize: Int?
    public var dolbyConfigFormat: DolbyConfigFormat?
    /// `BT709_3BY3_GAMUT_DATA` / `BT2020_3BY3_GAMUT_DATA` (every chip bscpylgtv lists).
    public var supportsGamutMatrix: Bool
    /// `HDR_3BY3_GAMUT_DATA` ("only used in 2019 models").
    public var supportsHDRGamutMatrix: Bool
    /// `1D_TONEMAP_PARAM` (2019 and newer).
    public var supportsToneMapParameters: Bool

    /// From the full firmware model token (`HE_DTV_W24H_AFADATAA`) or a bare chip type (`W24H`). Nil for unknown chips.
    public init?(modelName: String) {
        let chars = Array(modelName)
        let chip = chars.count >= 11 ? String(chars[7..<11]) : modelName
        guard chip.count == 4, chip.first == "W", let year = Int(chip.dropFirst().prefix(2)), let kind = chip.last else { return nil }
        chipType = chip
        supportsGamutMatrix = true
        supportsHDRGamutMatrix = year == 19
        supportsToneMapParameters = year >= 19
        switch (year, kind) {
        case (17, "H"), (17, "O"):
            lut3DSize = nil
            dolbyConfigFormat = nil
        case (18, "H"):
            lut3DSize = 17
            dolbyConfigFormat = .v2018
        case (18, "O"):
            lut3DSize = 33
            dolbyConfigFormat = .v2018
        case (19...26, "H"):
            lut3DSize = 17
            dolbyConfigFormat = .v2019
        case (19...26, "O"), (24...26, "G"):
            lut3DSize = 33
            dolbyConfigFormat = .v2019
        default:
            return nil
        }
    }
}
