import ColorScience
import Foundation
import PatternLink

/// Synthetic error profile and factory defaults of one simulated picture mode.
///
/// All numbers are invented to resemble typical uncalibrated LG WOLED behaviour; none were measured on a real B4.
struct ModeProfile: Sendable {
    struct Bump: Sendable {
        var center: Double
        var width: Double
        var amplitude: RGB
    }

    var id: String
    var path: DynamicRange
    var isGame = false
    /// SDR: actual exponent = gamma setting + offset.
    var gammaOffset = 0.0
    /// SDR: relative deviation `sCurve · sin(2πv)` (S-shaped: brighter below 50 %, darker above, for sCurve > 0).
    var sCurve = 0.0
    /// HDR10: relative over-brightness on 10–60 % PQ stimulus (trapezoid, 5 % ramps).
    var tracking = 0.0
    /// Per-channel Gaussian deviations ("20-point bumps").
    var bumps: [Bump] = []
    /// Relative per-channel excess near black, decaying as exp(−v / 0.08).
    var lowEndTint = RGB(gray: 0)
    /// White the factory white balance produces.
    var white: Chromaticity
    /// Δx, Δy for R, G, B: error of the content primaries the factory gamut mapping assumes.
    var primaryShift: [Double] = [0, 0, 0, 0, 0, 0]
    var defaults: [String: JSONValue]

    /// Relative luminance deviation of `channel` at signal `v`.
    func deviation(_ v: Double, channel c: Int) -> Double {
        var d = lowEndTint[c] * exp(-v / 0.08)
        if path == .sdr { d += sCurve * sin(2 * .pi * v) }
        if path == .hdr10 { d += tracking * ((v - 0.05) / 0.05).clamped(0, 1) * ((0.65 - v) / 0.05).clamped(0, 1) }
        for b in bumps { d += b.amplitude[c] * exp(-pow((v - b.center) / b.width, 2)) }
        return d
    }

    static let all: [String: ModeProfile] = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })

    static let list: [ModeProfile] = [
        ModeProfile(
            id: "expert1", path: .sdr, gammaOffset: -0.10, sCurve: 0.03,
            bumps: [
                Bump(center: 0.45, width: 0.09, amplitude: RGB(r: 0.025, g: 0, b: -0.01)),
                Bump(center: 0.75, width: 0.08, amplitude: RGB(r: 0, g: -0.015, b: 0.012)),
            ],
            lowEndTint: RGB(r: 0, g: 0, b: 0.10), white: Chromaticity(x: 0.3155, y: 0.3290),
            primaryShift: [0.004, -0.002, -0.005, 0.010, -0.002, -0.004], defaults: settings(backlight: 30, gamma: "bt1886")),
        ModeProfile(
            id: "expert2", path: .sdr, gammaOffset: -0.06, sCurve: 0.02,
            bumps: [Bump(center: 0.5, width: 0.1, amplitude: RGB(r: 0.015, g: 0, b: 0))],
            lowEndTint: RGB(r: 0, g: 0, b: 0.06), white: Chromaticity(x: 0.3145, y: 0.3300),
            primaryShift: [0.003, -0.001, -0.003, 0.006, -0.001, -0.002], defaults: settings(backlight: 50, gamma: "bt1886")),
        ModeProfile(
            id: "cinema", path: .sdr, gammaOffset: 0.05, sCurve: -0.02, white: Chromaticity(x: 0.3170, y: 0.3310),
            primaryShift: [0.008, -0.004, -0.006, 0.015, 0.002, 0.006], defaults: settings(backlight: 60, gamma: "medium")),
        ModeProfile(
            id: "filmMaker", path: .sdr, gammaOffset: -0.04, sCurve: 0.015, white: Chromaticity(x: 0.3138, y: 0.3285),
            primaryShift: [0.002, 0, 0.003, 0.005, 0, 0.002], defaults: settings(backlight: 35, gamma: "bt1886")),
        ModeProfile(
            id: "game", path: .sdr, isGame: true, gammaOffset: -0.05, sCurve: 0.02,
            bumps: [
                Bump(center: 0.2, width: 0.08, amplitude: RGB(r: 0, g: -0.025, b: 0.01)),
                Bump(center: 0.6, width: 0.09, amplitude: RGB(r: 0.015, g: 0, b: 0.02)),
            ],
            lowEndTint: RGB(r: 0.04, g: 0, b: 0), white: Chromaticity(x: 0.3085, y: 0.3300),
            primaryShift: [0.012, -0.005, -0.010, 0.020, -0.002, 0.003], defaults: settings(backlight: 100, gamma: "medium")),
        ModeProfile(
            id: "hdr_cinema", path: .hdr10, tracking: 0.04,
            bumps: [Bump(center: 0.3, width: 0.08, amplitude: RGB(r: 0.01, g: -0.01, b: 0))],
            white: Chromaticity(x: 0.3120, y: 0.3320), defaults: settings(backlight: 100, toneMapping: "off")),
        ModeProfile(
            id: "hdr_filmMaker", path: .hdr10, tracking: 0.02, white: Chromaticity(x: 0.3135, y: 0.3305),
            defaults: settings(backlight: 100, toneMapping: "off")),
        ModeProfile(
            id: "hdr_game", path: .hdr10, isGame: true, tracking: 0.01,
            bumps: [Bump(center: 0.4, width: 0.1, amplitude: RGB(r: 0, g: 0.015, b: -0.01))],
            lowEndTint: RGB(r: 0.08, g: 0, b: 0.08), white: Chromaticity(x: 0.3110, y: 0.3270),
            defaults: settings(backlight: 100, toneMapping: "HGIG")),
        ModeProfile(
            id: "dolby_cinema_dark", path: .dolbyVision, white: Chromaticity(x: 0.3135, y: 0.3300),
            defaults: settings(backlight: 100)),
        ModeProfile(
            id: "dolby_game", path: .dolbyVision, isGame: true, white: Chromaticity(x: 0.3100, y: 0.3280),
            defaults: settings(backlight: 100)),
    ]

    private static func settings(backlight: Int, gamma: String? = nil, toneMapping: String? = nil) -> [String: JSONValue] {
        var s: [String: JSONValue] = [
            PictureKey.backlight: .number(Double(backlight)), PictureKey.contrast: .number(85),
            PictureKey.brightness: .number(50), PictureKey.color: .number(50),
            PictureKey.colorTemperature: .string("warm50"), PictureKey.peakBrightness: .string("off"),
            PictureKey.twentyPoint: PictureKey.encodeTwentyPoint(PictureKey.zeroTwentyPoint),
        ]
        for key in PictureKey.gains + PictureKey.offsets { s[key] = .number(0) }
        if let gamma { s[PictureKey.gamma] = .string(gamma) }
        if let toneMapping { s[PictureKey.hdrDynamicToneMapping] = .string(toneMapping) }
        return s
    }
}

/// Picture controls of one mode, parsed from its settings dictionary.
struct ModeControls {
    var backlight = 100.0, contrast = 85.0, brightness = 50.0, color = 50.0
    /// +50 = warm50 … −50 = cool50.
    var warmth = 50.0
    var gamma = 2.2
    var gains = RGB(gray: 0), offsets = RGB(gray: 0)
    var twentyPoint = PictureKey.zeroTwentyPoint
    var toneMapping = "off"

    static let gammaValues: [String: Double] = ["low": 1.9, "medium": 2.2, "high1": 2.4, "high2": 2.6, "bt1886": 2.4]

    init(_ s: [String: JSONValue]) {
        func num(_ key: String, _ fallback: Double) -> Double { s[key]?.doubleValue ?? fallback }
        backlight = num(PictureKey.backlight, 100)
        contrast = num(PictureKey.contrast, 85)
        brightness = num(PictureKey.brightness, 50)
        color = num(PictureKey.color, 50)
        warmth = s[PictureKey.colorTemperature]?.stringValue.flatMap(Self.warmth) ?? 50
        gamma = s[PictureKey.gamma]?.stringValue.flatMap { Self.gammaValues[$0] } ?? 2.2
        for c in 0..<3 {
            gains[c] = num(PictureKey.gains[c], 0)
            offsets[c] = num(PictureKey.offsets[c], 0)
        }
        twentyPoint = PictureKey.decodeTwentyPoint(s[PictureKey.twentyPoint]) ?? PictureKey.zeroTwentyPoint
        toneMapping = s[PictureKey.hdrDynamicToneMapping]?.stringValue ?? "off"
    }

    /// "warm50" → 50, "cool20" → −20, "medium" → 0; nil if malformed or beyond 50.
    static func warmth(_ value: String) -> Double? {
        if value == "medium" { return 0 }
        for (prefix, sign) in [("warm", 1.0), ("cool", -1.0)] where value.hasPrefix(prefix) {
            guard let n = Int(value.dropFirst(prefix.count)), (0...50).contains(n) else { return nil }
            return sign * Double(n)
        }
        return nil
    }
}

/// Calibration data uploaded to one picture mode through the (simulated) externalpq API.
public struct ModeCalibration: Hashable, Sendable {
    public internal(set) var lut1D: LUT1D?
    public internal(set) var lut3D: [Colorimetry: LUT3D] = [:]
    public internal(set) var gamutMatrix: [Colorimetry: Matrix3] = [:]
    public internal(set) var toneMap: ToneMapParameters?
    public internal(set) var dolbyVision: DolbyVisionConfig?

    public var isEmpty: Bool { self == ModeCalibration() }
}

/// The simulated signal chain. Assumed order (LG's real order is unknown):
/// brightness/contrast → 1D LUT → 3D LUT → gamut matrix → 20-point WB → 2-point WB → per-channel native EOTF with the
/// mode's deviations (SDR: power law; HDR10: PQ, tracking error, tone mapping) → colour control → factory gamut mapping
/// in linear light into the native WOLED primaries (BT.2020 content is clipped at the native gamut) → white-point
/// error → XYZ. Black is a constant 0.0005 cd/m² with a slight blue tint. ABL and settling are applied by the panel.
enum PanelPipeline {
    static let native = ColorSpacePrimaries(
        red: Chromaticity(x: 0.676, y: 0.316), green: Chromaticity(x: 0.253, y: 0.700),
        blue: Chromaticity(x: 0.145, y: 0.052), white: .d65)
    static let sdrPeak = 420.0
    static let hdrPeak = 800.0
    static let black = Chromaticity(x: 0.300, y: 0.315).xyz(Y: 0.0005)
    /// Internal signal headroom above reference white (≈ code 1019 of 10-bit limited).
    static let headroom = 1.09
    /// Native per-channel gamma the Dolby Vision engine drives.
    static let dolbyNativeGamma = 2.2
    /// What the TV's DV engine assumes before a config is uploaded (deliberately wrong for the simulated panel).
    static let factoryDolby = DolbyVisionConfig(
        whiteLevel: 700, blackLevel: 0.005, gamma: 2.4, red: HDR10StaticMetadata.p3D65.red,
        green: HDR10StaticMetadata.p3D65.green, blue: HDR10StaticMetadata.p3D65.blue, white: .d65)

    /// Peak scale for OLED light 0…100 (100 → 1).
    static func peakScale(backlight: Double) -> Double { 0.05 + 0.95 * pow((backlight / 100).clamped(0, 1), 1.2) }

    static func xyz(
        signal: SignalRGB, format: SignalFormat, metadata: HDR10StaticMetadata?, path: DynamicRange,
        profile: ModeProfile, controls: ModeControls, calibration: ModeCalibration
    ) -> XYZ {
        let scale = peakScale(backlight: controls.backlight)
        let w = Double(50 - controls.warmth)
        let whiteScale = native.linearRGB(from: profile.white.xyz(Y: 1)) * RGB(r: 1 - 0.002 * w, g: 1, b: 1 + 0.004 * w)

        if path == .dolbyVision {
            // Synthetic DV engine: it renders the content for the *declared* display, the panel shows it as it really is.
            let cfg = calibration.dolbyVision ?? factoryDolby
            let mapped = signal.rgb.map { ToneCurve.rollOff(PQ.eotf($0), knee: 0.7 * cfg.whiteLevel, peak: cfg.whiteLevel, source: 1000) }
            let desired = ColorSpacePrimaries.bt2020.xyz(fromLinear: mapped)
            let declared = ColorSpacePrimaries(red: cfg.red, green: cfg.green, blue: cfg.blue, white: cfg.white)
            let drive = (declared.linearRGB(from: desired) * (1 / cfg.whiteLevel)).map { pow($0.clamped(0, 1), 1 / cfg.gamma) }
            let linear = drive.map { pow($0, dolbyNativeGamma) }
            return native.xyz(fromLinear: linear * whiteScale) * (hdrPeak * scale) + black
        }

        let gain = 1 + 0.004 * (controls.contrast - 85)
        let lift = 0.002 * (controls.brightness - 50)
        var s = signal.rgb.map { ($0 * gain + lift).clamped(0, headroom) }
        if let lut = calibration.lut1D { s = lut.apply(s.clamped()) }
        if let lut = calibration.lut3D[format.colorimetry] { s = lut.apply(s.clamped()) }
        if let m = calibration.gamutMatrix[format.colorimetry] {
            s = (m * s.map { pow(max($0, 0), 2.2) }).map { pow(max($0, 0), 1 / 2.2) }
        }
        for c in 0..<3 {
            var v = s[c]
            for (i, k) in controls.twentyPoint.enumerated() where k[c] != 0 {
                let p = 0.05 * Double(i + 1)
                v += Double(k[c]) * 0.003 * p * max(0, 1 - abs(s[c] - p) / 0.075)
            }
            v = v * (1 + 0.003 * controls.gains[c]) + 0.0005 * controls.offsets[c] * (1 - v)
            s[c] = v.clamped(0, headroom)
        }

        var e = RGB(gray: 0)
        let peak: Double
        if path == .sdr {
            peak = sdrPeak * scale
            let gamma = controls.gamma + profile.gammaOffset
            for c in 0..<3 { e[c] = pow(s[c], gamma) * (1 + profile.deviation(s[c], channel: c)) }
        } else {
            peak = hdrPeak * scale
            for c in 0..<3 {
                let content = PQ.eotf(s[c]) * (1 + profile.deviation(s[c], channel: c))
                e[c] =
                    toneMap(content, style: controls.toneMapping, params: calibration.toneMap, metadata: metadata, panelPeak: peak) / peak
            }
        }
        let luma = 0.2126 * e.r + 0.7152 * e.g + 0.0722 * e.b
        e = e.map { luma + ($0 - luma) * controls.color / 50 }
        var linear = (factoryMatrix(profile, format.colorimetry) * e).map { max($0, 0) }
        if path == .hdr10 { linear = linear.map { min($0, 1) } }
        return native.xyz(fromLinear: linear * whiteScale) * peak + black
    }

    /// The TV's HDR10 static tone mapping. HGIG: hard clip at the panel peak. Otherwise roll-off toward the target
    /// peak (uploaded `displayLuminance`, else the panel peak) from a knee (uploaded roll-off %, else 70 %; 60 % with
    /// dynamic tone mapping "on"), mapping max(1000, MaxMDL) to the target peak.
    static func toneMap(_ L: Double, style: String, params: ToneMapParameters?, metadata: HDR10StaticMetadata?, panelPeak: Double) -> Double
    {
        if style == "HGIG" { return min(L, panelPeak) }
        let target = params.map { Double($0.displayLuminance) } ?? panelPeak
        let knee = (style == "on" ? 0.6 : params.map { Double($0.rolloffPoint) / 100 } ?? 0.7) * target
        let source = max(1000, metadata?.maxMasteringLuminance ?? 1000)
        return min(ToneCurve.rollOff(L, knee: knee, peak: target, source: source), panelPeak)
    }

    /// Content linear RGB → native linear RGB, assuming content primaries shifted by the mode's `primaryShift`.
    static func factoryMatrix(_ profile: ModeProfile, _ colorimetry: Colorimetry) -> Matrix3 {
        let base = ColorSpacePrimaries(colorimetry: colorimetry)
        let d = profile.primaryShift
        let assumed = ColorSpacePrimaries(
            red: Chromaticity(x: base.red.x + d[0], y: base.red.y + d[1]),
            green: Chromaticity(x: base.green.x + d[2], y: base.green.y + d[3]),
            blue: Chromaticity(x: base.blue.x + d[4], y: base.blue.y + d[5]), white: .d65)
        return native.xyzToRGB * assumed.rgbToXYZ
    }
}

extension PatternContent {
    /// The colour a meter at the screen centre sees; ramps and bars report their centre bar.
    var meteredColor: SignalRGB {
        if let c = centerColor { return c }
        switch self {
        case .ramp(let steps, let from, let to, _):
            let t = steps > 1 ? Double(steps / 2) / Double(steps - 1) : 0
            return SignalRGB(r: from.r + (to.r - from.r) * t, g: from.g + (to.g - from.g) * t, b: from.b + (to.b - from.b) * t)
        case .bars(let bars, let background): return bars.isEmpty ? background : bars[bars.count / 2]
        default: return .black
        }
    }

    /// Lit screen fraction used by the ABL model.
    var lightArea: Double {
        switch self {
        case .window(_, let window, _): window.areaFraction
        case .black: 0
        default: 1
        }
    }
}
