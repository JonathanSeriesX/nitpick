import Foundation

/// webOS picture-setting keys the engine reads and writes. Where the real LG key is not known for certain the name
/// is our choice and the simulated TV uses the same one; `LGTVController` maps them to the wire names.
///
/// Value conventions (as the simulated TV validates them):
/// - `backlight` (OLED light), `contrast`, `brightness`, `color`: integers 0…100 (contrast default 85, others 50).
/// - `gamma`: "low" (1.9), "medium" (2.2), "high1" (2.4), "high2" (2.6), "bt1886" — SDR modes only.
/// - `colorTemperature`: "warm0"…"warm50", "cool0"…"cool50" or "medium"; "warm50" ≈ D65 in expert modes.
/// - 2-point white balance gains/offsets: integers −50…50.
/// - `whiteBalance20pt`: 20 objects `{ire, red, green, blue}`, ire 5…100 in 5 % steps, channels −50…50.
/// - `hdrDynamicToneMapping`: "off" | "on" | "HGIG" — HDR10 modes only.
/// - `peakBrightness`: "off" | "low" | "medium" | "high".
public enum PictureKey {
    public static let backlight = "backlight"
    public static let contrast = "contrast"
    public static let brightness = "brightness"
    public static let color = "color"
    public static let gamma = "gamma"
    public static let colorTemperature = "colorTemperature"
    public static let gains = ["whiteBalanceRedGain", "whiteBalanceGreenGain", "whiteBalanceBlueGain"]
    public static let offsets = ["whiteBalanceRedOffset", "whiteBalanceGreenOffset", "whiteBalanceBlueOffset"]
    public static let twentyPoint = "whiteBalance20pt"
    public static let hdrDynamicToneMapping = "hdrDynamicToneMapping"
    public static let peakBrightness = "peakBrightness"

    /// IRE (stimulus %) of each 20-point entry.
    public static let twentyPointIRE = Array(stride(from: 5, through: 100, by: 5))

    /// 20 × [red, green, blue] (index = ire / 5 − 1) as the TV's JSON.
    public static func encodeTwentyPoint(_ values: [[Int]]) -> JSONValue {
        .array(zip(twentyPointIRE, values).map { ire, rgb in
            .object(["ire": .number(Double(ire)), "red": .number(Double(rgb[0])),
                     "green": .number(Double(rgb[1])), "blue": .number(Double(rgb[2]))])
        })
    }

    /// Inverse of `encodeTwentyPoint`; nil unless it is exactly 20 entries covering every IRE once with integer channels.
    public static func decodeTwentyPoint(_ json: JSONValue?) -> [[Int]]? {
        guard case .array(let entries)? = json, entries.count == 20 else { return nil }
        var out = [[Int]](repeating: [], count: 20)
        for entry in entries {
            guard case .object(let o) = entry, let ire = o["ire"]?.intValue, ire % 5 == 0, (5...100).contains(ire),
                  out[ire / 5 - 1].isEmpty else { return nil }
            let channels = ["red", "green", "blue"].compactMap { key -> Int? in
                guard let d = o[key]?.doubleValue, d == d.rounded() else { return nil }
                return Int(d)
            }
            guard channels.count == 3 else { return nil }
            out[ire / 5 - 1] = channels
        }
        return out
    }

    static let zeroTwentyPoint = [[Int]](repeating: [0, 0, 0], count: 20)
}
