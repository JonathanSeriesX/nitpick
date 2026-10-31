import ColorScience
import Foundation

/// Calibration bank (`picMode` of externalpq), SPEC §4.3/§5.6.
public enum LGPicMode: String, Sendable, CaseIterable {
    case cinema, expert1, expert2, game, technicolorExpert, filmMaker
    case hdrCinema = "hdr_cinema"
    case hdrGame = "hdr_game"
    case hdrTechnicolorExpert = "hdr_technicolorExpert"
    case hdrFilmMaker = "hdr_filmMaker"
    case dolbyCinemaBright = "dolby_cinema_bright"
    case dolbyCinemaDark = "dolby_cinema_dark"
    case dolbyGame = "dolby_game"

    public enum SignalClass: Sendable { case sdr, hdr10, dolbyVision }

    public var signalClass: SignalClass {
        if rawValue.hasPrefix("hdr_") { return .hdr10 }
        if rawValue.hasPrefix("dolby_") { return .dolbyVision }
        return .sdr
    }

    /// From a `pictureMode` setting value; nil for modes without a calibration bank (vivid, normal, eco, …).
    public init?(pictureMode: String) {
        let map: [String: LGPicMode] = [
            "cinema": .cinema, "expert1": .expert1, "expert2": .expert2, "game": .game, "filmMaker": .filmMaker,
            "technicolor": .technicolorExpert, "hdrCinema": .hdrCinema, "hdrGame": .hdrGame, "hdrFilmMaker": .hdrFilmMaker,
            "dolbyHdrCinemaBright": .dolbyCinemaBright, "dolbyHdrCinema": .dolbyCinemaDark, "dolbyHdrGame": .dolbyGame,
        ]
        guard let mode = map[pictureMode] else { return nil }
        self = mode
    }

    /// `PictureMode = N` in the Dolby Vision config: 1 Cinema Home, 2 Cinema/FILMMAKER, 4 Game.
    public var dolbyConfigIndex: Int? {
        switch self {
        case .dolbyCinemaBright: 1
        case .dolbyCinemaDark: 2
        case .dolbyGame: 4
        default: nil
        }
    }
}

/// `externalpq/setExternalPqData` commands, SPEC §5.2.
public enum ExternalPQCommand: String, Sendable, CaseIterable {
    case calStart = "CAL_START"
    case calEnd = "CAL_END"
    /// uint16 × 1, 0–100.
    case backlightUI = "BACKLIGHT_UI_DATA"
    case contrastUI = "CONTRAST_UI_DATA"
    case brightnessUI = "BRIGHTNESS_UI_DATA"
    case colorUI = "COLOR_UI_DATA"
    /// uint16 × 3072: planar R[1024], G[1024], B[1024], 0–32767.
    case lut1D = "1D_DPG_DATA"
    /// uint16 × 1 flags (0/1): 1D LUT enable, de-gamma 2.2 before the 3×3, re-gamma 0.45 after it, 3×3 enable.
    case lut1DEnable = "1D_DPG_EN"
    case degamma22Enable = "1D_2_2_EN"
    case regamma045Enable = "1D_0_45_EN"
    case gamutEnable = "3BY3_GAMUT_EN"
    /// uint16 × N³ × 3, R fastest, 0–4095.
    case bt709LUT3D = "BT709_3D_LUT_DATA"
    case bt2020LUT3D = "BT2020_3D_LUT_DATA"
    /// float32 × 9 row-major, −1024…1024. `HDR_3BY3_GAMUT_DATA` is for 2019 chips only.
    case bt709Gamut = "BT709_3BY3_GAMUT_DATA"
    case bt2020Gamut = "BT2020_3BY3_GAMUT_DATA"
    case hdrGamut = "HDR_3BY3_GAMUT_DATA"
    /// uint16 × 7 (`LGToneMapParameters`), HDR10 banks only.
    case toneMap = "1D_TONEMAP_PARAM"
    /// ASCII text bytes with CRLF lines, Dolby Vision banks only.
    case dolbyConfig = "DOLBY_CFG_DATA"

    public var dataType: ExternalPQDataType? {
        switch self {
        case .calStart, .calEnd: nil
        case .bt709Gamut, .bt2020Gamut, .hdrGamut: .float32
        case .dolbyConfig: .uint8
        default: .uint16
        }
    }

    static let uiData: Set<ExternalPQCommand> = [.backlightUI, .contrastUI, .brightnessUI, .colorUI]
    static let flags: Set<ExternalPQCommand> = [.lut1DEnable, .degamma22Enable, .regamma045Enable, .gamutEnable]
    static let gamut: Set<ExternalPQCommand> = [.bt709Gamut, .bt2020Gamut, .hdrGamut]
    static let lut3D: Set<ExternalPQCommand> = [.bt709LUT3D, .bt2020LUT3D]
}

/// `dataType` strings. A numeric code fails on newer TVs ("not a string").
public enum ExternalPQDataType: String, Sendable {
    case uint8 = "unsigned char"
    case uint16 = "unsigned integer16"
    case float32 = "float"
    public var byteWidth: Int { self == .uint8 ? 1 : self == .uint16 ? 2 : 4 }
}

/// `dataOpt`.
public enum ExternalPQOption: Int, Sendable {
    case apply = 0
    case applyAndSave = 1
    /// Reset the command's data to factory (sent with empty data).
    case resetToFactory = 2
}

/// Encoded little-endian data for one externalpq command. Build it with `ExternalPQEncoder`.
public struct ExternalPQData: Sendable, Equatable {
    public let command: ExternalPQCommand
    public let dataType: ExternalPQDataType
    /// Raw little-endian bytes (the base64 in the request decodes to these).
    public let bytes: Data
    /// Element count (`dataCount`), not bytes.
    public let count: Int

    public init(command: ExternalPQCommand, dataType: ExternalPQDataType, bytes: Data, count: Int) {
        (self.command, self.dataType, self.bytes, self.count) = (command, dataType, bytes, count)
    }

    public var base64: String { bytes.base64EncodedString() }

    /// Decoded element values.
    public var values: [Double] { Self.decode(bytes, as: dataType) }

    /// Little-endian `bytes` as `type` elements.
    public static func decode(_ bytes: Data, as type: ExternalPQDataType) -> [Double] {
        let width = type.byteWidth
        return bytes.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - width + 1, by: width).map { i -> Double in
                switch type {
                case .uint8: Double(raw[i])
                case .uint16: Double(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt16.self)))
                case .float32: Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))))
                }
            }
        }
    }
}

/// HDR10 static tone curve (`1D_TONEMAP_PARAM`, SPEC §5.9). For content mastered at peak *k*, the TV tracks PQ up to
/// roll-off *k* % of the panel peak, then rolls off to it (interpretation UNCONFIRMED). All roll-offs at 100 disable
/// the internal tone mapping. Defaults are bscpylgtv's.
public struct LGToneMapParameters: Sendable, Hashable {
    /// [0] Panel peak luminance, cd/m², 100–4000 (measure 100 % white on a 10 % window).
    public var panelPeak: Int = 700
    /// [1] First mastering peak, cd/m², 100–10000.
    public var masteringPeak1: Int = 1000
    /// [2] Roll-off point for `masteringPeak1`, %, 0–100.
    public var rolloff1: Int = 70
    /// [3] Second mastering peak, cd/m², 100–10000.
    public var masteringPeak2: Int = 4000
    /// [4] Roll-off point for `masteringPeak2`, %, 0–100.
    public var rolloff2: Int = 60
    /// [5] Third mastering peak, cd/m², 100–10000.
    public var masteringPeak3: Int = 10000
    /// [6] Roll-off point for `masteringPeak3`, %, 0–100.
    public var rolloff3: Int = 50

    public init(
        panelPeak: Int = 700, masteringPeak1: Int = 1000, rolloff1: Int = 70, masteringPeak2: Int = 4000,
        rolloff2: Int = 60, masteringPeak3: Int = 10000, rolloff3: Int = 50
    ) {
        (self.panelPeak, self.masteringPeak1, self.rolloff1) = (panelPeak, masteringPeak1, rolloff1)
        (self.masteringPeak2, self.rolloff2, self.masteringPeak3, self.rolloff3) = (masteringPeak2, rolloff2, masteringPeak3, rolloff3)
    }

    public var values: [Int] { [panelPeak, masteringPeak1, rolloff1, masteringPeak2, rolloff2, masteringPeak3, rolloff3] }
    static let ranges: [ClosedRange<Double>] = [100...4000, 100...10000, 0...100, 100...10000, 0...100, 100...10000, 0...100]
}

/// Encoders from ColorScience types to externalpq data (SPEC §5.3). Every encoder refuses NaN and out-of-domain input
/// instead of clipping it; `PayloadValidator` re-checks the bytes before anything is sent.
public enum ExternalPQEncoder {
    static let tolerance = 1e-6

    /// `LUT1D` (any size ≥ 2; resampled linearly to 1024 points) → uint16 planar R,G,B × 1024, `round(v·32767)`.
    public static func lut1D(_ lut: LUT1D) throws -> ExternalPQData {
        var codes: [UInt16] = []
        codes.reserveCapacity(3072)
        for c in 0..<3 {
            let table = lut.channel(c)
            for i in 0..<1024 {
                let v = lut.size == 1024 ? table[i] : LUT1D.sample(table, at: Double(i) / 1023)
                codes.append(try quantize(v, scale: 32767, max: 32767, what: "1D LUT"))
            }
        }
        return ExternalPQData(command: .lut1D, dataType: .uint16, bytes: le(codes), count: codes.count)
    }

    /// `LUT3D` → uint16 N³×3 with RED fastest (LUT3D stores blue fastest), `min(round(v·4096), 4095)`.
    /// `size` is the TV's grid (17 on a B4). A 33-point LUT is resampled to 17 by trilinear sampling; other mismatches are refused.
    public static func lut3D(_ lut: LUT3D, size: Int, command: ExternalPQCommand = .bt709LUT3D) throws -> ExternalPQData {
        guard ExternalPQCommand.lut3D.contains(command) else { throw LGError.invalidPayload("\(command.rawValue) is not a 3D LUT command") }
        let source: LUT3D
        if lut.size == size {
            source = lut
        } else if lut.size == 33, size == 17 {
            source = resample(lut, to: 17)
        } else {
            throw LGError.invalidPayload("3D LUT has \(lut.size) points; this TV needs \(size)")
        }
        var codes: [UInt16] = []
        codes.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let node = source[r, g, b]
                    for v in [node.r, node.g, node.b] { codes.append(try quantize(v, scale: 4096, max: 4095, what: "3D LUT")) }
                }
            }
        }
        return ExternalPQData(command: command, dataType: .uint16, bytes: le(codes), count: codes.count)
    }

    /// Trilinear resampling onto a smaller grid (exact at shared nodes, so 33 → 17 keeps every even node).
    public static func resample(_ lut: LUT3D, to size: Int) -> LUT3D {
        let d = Double(size - 1)
        var nodes: [RGB] = []
        nodes.reserveCapacity(size * size * size)
        for r in 0..<size {
            for g in 0..<size {
                for b in 0..<size {
                    nodes.append(lut.apply(RGB(r: Double(r) / d, g: Double(g) / d, b: Double(b) / d)))
                }
            }
        }
        return LUT3D(size: size, nodes: nodes)
    }

    /// `Matrix3` → float32 × 9 row-major. Entries must be finite and within ±1024.
    public static func matrix(_ m: Matrix3, command: ExternalPQCommand = .bt709Gamut) throws -> ExternalPQData {
        guard ExternalPQCommand.gamut.contains(command) else { throw LGError.invalidPayload("\(command.rawValue) is not a 3×3 command") }
        guard m.m.allSatisfy({ $0.isFinite && abs($0) <= 1024 }) else {
            throw LGError.invalidPayload("3×3 entries must be finite, within ±1024")
        }
        return floats(m.m.map(Float.init), command: command)
    }

    /// UI data (0–100) or a flag (0/1) as uint16 × 1.
    public static func value(_ v: Int, command: ExternalPQCommand) throws -> ExternalPQData {
        let range = ExternalPQCommand.uiData.contains(command) ? 0...100 : ExternalPQCommand.flags.contains(command) ? 0...1 : nil
        guard let range else { throw LGError.invalidPayload("\(command.rawValue) does not take a single value") }
        guard range.contains(v) else { throw LGError.invalidPayload("\(command.rawValue) value \(v) outside \(range)") }
        return ExternalPQData(command: command, dataType: .uint16, bytes: le([UInt16(v)]), count: 1)
    }

    public static func toneMap(_ p: LGToneMapParameters) throws -> ExternalPQData {
        for (v, r) in zip(p.values, LGToneMapParameters.ranges) where !r.contains(Double(v)) {
            throw LGError.invalidPayload("tone-map value \(v) outside \(r)")
        }
        return ExternalPQData(command: .toneMap, dataType: .uint16, bytes: le(p.values.map { UInt16($0) }), count: 7)
    }

    /// Dolby Vision config text as `unsigned char` bytes (ASCII only).
    public static func dolbyConfig(_ text: String) throws -> ExternalPQData {
        guard let bytes = text.data(using: .ascii), !bytes.isEmpty else {
            throw LGError.invalidPayload("Dolby Vision config must be non-empty ASCII")
        }
        return ExternalPQData(command: .dolbyConfig, dataType: .uint8, bytes: bytes, count: bytes.count)
    }

    /// Nine zero floats: the `CAL_START` data Calman sends.
    public static let calStartZeros = floats(Array(repeating: 0, count: 9), command: .calStart)

    static func floats(_ values: [Float], command: ExternalPQCommand) -> ExternalPQData {
        var d = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return ExternalPQData(command: command, dataType: .float32, bytes: d, count: values.count)
    }

    static func le(_ values: [UInt16]) -> Data {
        var d = Data(capacity: values.count * 2)
        for v in values { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    private static func quantize(_ v: Double, scale: Double, max: Int, what: String) throws -> UInt16 {
        guard v.isFinite, v >= -tolerance, v <= 1 + tolerance else { throw LGError.invalidPayload("\(what) value \(v) outside 0…1") }
        return UInt16(Swift.min(Swift.max((v * scale).rounded(), 0), Double(max)))
    }
}
