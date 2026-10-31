import Foundation

/// Picture-settings keys (`com.webos.settingsservice`, category `picture`). SPEC §4.4/§4.5.
public enum LGPictureKeys {
    /// The keys a calibration workflow reads before and after a run (the fixture read of SPEC §(c)).
    public static let calibrationRelevant: [String] = [
        "pictureMode", "backlight", "contrast", "brightness", "color", "tint", "sharpness", "colorGamut", "gamma",
        "colorTemperature", "dynamicContrast", "peakBrightness", "hdrDynamicToneMapping", "smoothGradation",
        "noiseReduction", "mpegNoiseReduction", "superResolution", "realCinema", "truMotionMode", "motionEyeCare",
        "energySaving", "dynamicColor", "blackLevel", "whiteBalanceMethod", "whiteBalancePoint", "whiteBalanceRedGain",
        "whiteBalanceGreenGain", "whiteBalanceBlueGain", "whiteBalanceRedOffset", "whiteBalanceGreenOffset",
        "whiteBalanceBlueOffset", "whiteBalanceIre", "whiteBalanceCodeValue", "whiteBalanceRed", "whiteBalanceGreen",
        "whiteBalanceBlue", "adjustingLuminance", "whiteBalanceLuminance",
    ]

    /// `pictureMode` setting values (webOS 24 enum, plus webOS 26 `creator` modes).
    public static let pictureModes: [String] = [
        "personalized", "hdrPersonalized", "dolbyHdrPersonalized", "vivid", "hdrVivid", "normal", "eco", "cinema",
        "hdrStandard", "hdrEco", "hdrCinemaBright", "hdrCinema", "sports", "game", "photo", "hdrGame", "filmMaker",
        "hdrFilmMaker", "dolbyHdrVivid", "dolbyHdrStandard", "dolbyHdrCinemaBright", "dolbyHdrCinema", "dolbyHdrGame",
        "expert1", "expert2", "dolbyHdrDarkAmazon", "hdrExternal", "creator", "hdrCreator", "dolbyHdrCreator",
    ]
}

/// Documented value domain of a picture key; `validate` refuses anything else with `LGError.outOfRange`.
public enum LGSettingRule: Sendable {
    case integer(ClosedRange<Int>, step: Int = 1)
    /// Integer arrays of one of the allowed lengths, every element in range.
    case integers(counts: Set<Int>, ClosedRange<Int>)
    case enumeration([String])
    /// `blackLevel`: object of the 8 colour systems → `auto`/`low`/`high`.
    case blackLevel

    public func validate(_ key: String, _ value: JSON) throws {
        func refuse(_ allowed: String) -> LGError { .outOfRange(key: key, value: Self.describe(value), allowed: allowed) }
        switch self {
        case .integer(let range, let step):
            guard let n = value.intValue, range.contains(n), (n - range.lowerBound) % step == 0 else {
                throw refuse("integer \(range.lowerBound)…\(range.upperBound)" + (step > 1 ? " step \(step)" : ""))
            }
        case .integers(let counts, let range):
            let items = value.arrayValue?.compactMap(\.intValue) ?? []
            guard counts.contains(items.count), items.count == value.arrayValue?.count, items.allSatisfy(range.contains) else {
                throw refuse("\(counts.sorted()) integers, each \(range.lowerBound)…\(range.upperBound)")
            }
        case .enumeration(let allowed):
            guard let s = value.stringValue ?? value.intValue.map(String.init), allowed.contains(s) else {
                throw refuse(allowed.joined(separator: ", "))
            }
        case .blackLevel:
            let systems = ["ntsc", "ntsc443", "pal", "pal60", "palm", "paln", "secam", "unknown"]
            guard let o = value.objectValue, !o.isEmpty,
                o.allSatisfy({ systems.contains($0.key) && ["auto", "low", "high"].contains($0.value.stringValue ?? "") })
            else {
                throw refuse("{\(systems.joined(separator: ","))} → auto|low|high")
            }
        }
    }

    static func describe(_ value: JSON) -> String {
        (try? value.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
    }
}

extension LGPictureKeys {
    /// Ranges and enums from SPEC §4.4/§4.5 (webOS 24 G4 dump, webOS 25/26 additions).
    public static let rules: [String: LGSettingRule] = {
        var r: [String: LGSettingRule] = [
            "pictureMode": .enumeration(pictureModes),
            "backlight": .integer(0...100), "contrast": .integer(0...100), "brightness": .integer(0...100),
            "color": .integer(0...100), "tint": .integer(-50...50),
            "sharpness": .integer(0...50), "hSharpness": .integer(0...50), "vSharpness": .integer(0...50),
            "colorGamut": .enumeration(["auto", "native", "wide", "extended", "dynamic"]),
            "gamma": .enumeration(["low", "medium", "high1", "high2", "mediumHavingLevel"]),
            "gammaLevel": .integer(-3...3),
            "colorTemperature": .integer(-50...50),
            "whiteBalanceColorTemperature": .enumeration(["cool", "medium", "warm1", "warm2"]),
            "dynamicContrast": .enumeration(["off", "low", "medium", "high"]),
            "peakBrightness": .enumeration(["off", "low", "medium", "high"]),
            "hdrDynamicToneMapping": .enumeration(["on", "off", "HGIG"]),
            "DtmMastering1k": .integer(10...100, step: 10), "DtmMastering4k": .integer(10...100, step: 10),
            "DtmMastering10k": .integer(10...100, step: 10),
            "hgig": .enumeration(["on", "off"]),
            "smoothGradation": .enumeration(["off", "low", "medium", "high"]),
            "noiseReduction": .enumeration(["off", "low", "medium", "high", "auto"]),
            "mpegNoiseReduction": .enumeration(["off", "low", "medium", "high", "auto"]),
            "superResolution": .enumeration(["off", "low", "medium", "high"]),
            "realCinema": .enumeration(["on", "off"]),
            "truMotionMode": .enumeration(["off", "cinemaClear", "natural", "smooth", "user", "clear"]),
            "motionProOLED": .enumeration(["off", "low", "medium", "high", "auto"]),
            "motionEyeCare": .enumeration(["on", "off"]),
            "blackLevel": .blackLevel,
            "energySaving": .enumeration(["auto", "off", "min", "med", "max", "screen_off"]),
            "dynamicColor": .enumeration(["off", "low", "medium", "high", "user"]),
            "nearBlackDetail": .integer(-10...10),
            "adjustingLuminance": .integers(counts: [22, 24], -50...50),
            "adjustingLuminance10pt": .integers(counts: [10], -50...50),
            "whiteBalanceMethod": .enumeration(["2", "10", "22", "10code", "22code", "24", "24code"]),
            "whiteBalancePoint": .enumeration(["low", "high"]),
            "whiteBalanceLuminance": .integer(50...500),
        ]
        for c in ["Red", "Green", "Blue"] {
            r["whiteBalance\(c)Gain"] = .integer(-50...50)
            r["whiteBalance\(c)Offset"] = .integer(-50...50)
            r["whiteBalance\(c)"] = .integers(counts: [22, 24], -50...50)
            r["whiteBalance\(c)10pt"] = .integers(counts: [10], -50...50)
        }
        for axis in ["Hue", "Saturation", "Luminance"] {
            for c in ["Red", "Green", "Blue", "Cyan", "Magenta", "Yellow"] { r["colorManagement\(axis)\(c)"] = .integer(-30...30) }
        }
        return r
    }()

    /// Throws `LGError.outOfRange` for a value outside the documented domain, `LGError.unsupported` for unknown keys.
    public static func validate(key: String, value: JSON) throws {
        guard let rule = rules[key] else { throw LGError.unsupported("no documented range for picture key \(key)") }
        try rule.validate(key, value)
    }
}

/// 2-point white balance: gain = high end, offset = low end; each −50…50 (SPEC §4.5).
public struct LGWhiteBalance2Point: Sendable, Hashable {
    public var redGain = 0, greenGain = 0, blueGain = 0
    public var redOffset = 0, greenOffset = 0, blueOffset = 0

    public init(redGain: Int = 0, greenGain: Int = 0, blueGain: Int = 0, redOffset: Int = 0, greenOffset: Int = 0, blueOffset: Int = 0) {
        (self.redGain, self.greenGain, self.blueGain) = (redGain, greenGain, blueGain)
        (self.redOffset, self.greenOffset, self.blueOffset) = (redOffset, greenOffset, blueOffset)
    }

    private var pairs: [(String, Int)] {
        [
            ("whiteBalanceRedGain", redGain), ("whiteBalanceGreenGain", greenGain), ("whiteBalanceBlueGain", blueGain),
            ("whiteBalanceRedOffset", redOffset), ("whiteBalanceGreenOffset", greenOffset), ("whiteBalanceBlueOffset", blueOffset),
        ]
    }

    /// Picture settings to write. Values are strings, as webOS 24/25 store them.
    public func settings() throws -> [String: JSON] {
        var out: [String: JSON] = [:]
        for (key, v) in pairs {
            try LGPictureKeys.validate(key: key, value: .number(Double(v)))
            out[key] = .string(String(v))
        }
        return out
    }

    /// Decodes a settings read (strings or numbers).
    public init(settings: [String: JSON]) throws {
        func v(_ k: String) throws -> Int {
            guard let n = settings[k]?.intValue else { throw LGError.malformedResponse("missing \(k)") }
            return n
        }
        try self.init(
            redGain: v("whiteBalanceRedGain"), greenGain: v("whiteBalanceGreenGain"), blueGain: v("whiteBalanceBlueGain"),
            redOffset: v("whiteBalanceRedOffset"), greenOffset: v("whiteBalanceGreenOffset"), blueOffset: v("whiteBalanceBlueOffset"))
    }
}

/// Multi-point white balance: per-channel corrections −50…50 at 10, 22 (webOS 24/25) or 24 (webOS 26) stimulus levels.
public struct LGWhiteBalanceMultiPoint: Sendable, Hashable {
    public var red: [Int], green: [Int], blue: [Int]

    /// Stimulus levels in IRE for each point count; index 0 is the darkest point.
    public static func ireLevels(count: Int) -> [Double]? {
        let tens = stride(from: 10.0, through: 100, by: 5).map { $0 }
        switch count {
        case 10: return stride(from: 10.0, through: 100, by: 10).map { $0 }
        case 22: return [2.5, 5, 7.5] + tens
        case 24: return [1, 2, 3, 5, 7.5] + tens
        default: return nil
        }
    }

    public init(red: [Int], green: [Int], blue: [Int]) throws {
        guard red.count == green.count, green.count == blue.count, Self.ireLevels(count: red.count) != nil else {
            throw LGError.invalidPayload("white balance needs 10, 22 or 24 points per channel")
        }
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    public var pointCount: Int { red.count }
    private var suffix: String { pointCount == 10 ? "10pt" : "" }

    /// Settings to write: the three arrays plus `whiteBalanceMethod` (`"<n>code"` as bscpylgtv's presets use).
    public func settings() throws -> [String: JSON] {
        var out: [String: JSON] = ["whiteBalanceMethod": .string("\(pointCount)code")]
        for (name, values) in [("Red", red), ("Green", green), ("Blue", blue)] {
            let key = "whiteBalance\(name)\(suffix)"
            let value = JSON.array(values.map { .number(Double($0)) })
            try LGPictureKeys.validate(key: key, value: value)
            out[key] = value
        }
        return out
    }

    /// Decodes a settings read; `pointCount` 10 reads the `…10pt` keys, otherwise the length of the arrays read decides.
    public init(settings: [String: JSON], tenPoint: Bool = false) throws {
        let suffix = tenPoint ? "10pt" : ""
        func v(_ c: String) throws -> [Int] {
            guard let a = settings["whiteBalance\(c)\(suffix)"]?.arrayValue?.compactMap(\.intValue) else {
                throw LGError.malformedResponse("missing whiteBalance\(c)\(suffix)")
            }
            return a
        }
        try self.init(red: v("Red"), green: v("Green"), blue: v("Blue"))
    }
}
