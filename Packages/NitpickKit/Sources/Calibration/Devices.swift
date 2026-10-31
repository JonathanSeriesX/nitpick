import Foundation
import ColorScience
import PatternLink

/// Static facts about a connected meter.
public struct MeterInfo: Hashable, Codable, Sendable {
    public var model: String
    public var serialNumber: String
    public var firmware: String?
    /// cd/m²; HL models read far brighter than the original i1Display Pro.
    public var maximumLuminance: Double
    public var isSimulated: Bool

    public init(model: String, serialNumber: String, firmware: String? = nil, maximumLuminance: Double, isSimulated: Bool = false) {
        self.model = model; self.serialNumber = serialNumber; self.firmware = firmware
        self.maximumLuminance = maximumLuminance; self.isSimulated = isSimulated
    }
}

/// A colorimeter. Implementations: `I1D3Meter` (MeterKit, real USB device) and `SimulatedMeter`.
public protocol Meter: AnyObject, Sendable {
    var info: MeterInfo { get async }
    func connect() async throws
    func disconnect() async
    /// One reading of the screen the meter is pointed at. `expectedLuminance` lets the driver pick an integration time.
    /// Must honour task cancellation.
    func measure(expectedLuminance: Double?) async throws -> MeterReading
    /// Applies (or clears) a colorimeter correction for the display's spectral characteristics.
    func setCorrection(_ correction: ColorimeterCorrection?) async throws
}

/// A pattern generator. Implementations: `RemotePatternSource` (Apple TV over PatternLink) and `SimulatedPatternSource`.
public protocol PatternSource: AnyObject, Sendable {
    var capabilities: DeviceCapabilities? { get async }
    func connect() async throws
    func disconnect() async
    /// Shows a pattern and returns once the device acknowledges the frame was enqueued. Callers add their own settling delay.
    func show(_ pattern: PatternSpec) async throws -> ShowAck
    /// Requests an output mode and returns once the device reports the switch finished (or that it cannot switch).
    func setDisplayMode(_ request: DisplayModeRequest) async throws -> DisplayModeState
    func blank() async throws
}

/// Mode-independent description of what a TV can do, discovered after connecting.
public struct TVCapabilities: Hashable, Codable, Sendable {
    public var modelName: String
    public var firmwareVersion: String
    public var webOSVersion: String?
    public var inputs: [TVInput]
    /// externalpq calibration API believed available (true for 2018+ LG OLEDs; confirmed only when CAL_START succeeds).
    public var supportsCalibrationAPI: Bool
    public var lut3DSize: Int
    public var supportsGamutMatrix: Bool
    public var isSimulated: Bool

    public init(modelName: String, firmwareVersion: String, webOSVersion: String? = nil, inputs: [TVInput],
                supportsCalibrationAPI: Bool, lut3DSize: Int = 33, supportsGamutMatrix: Bool = true, isSimulated: Bool = false) {
        self.modelName = modelName; self.firmwareVersion = firmwareVersion; self.webOSVersion = webOSVersion; self.inputs = inputs
        self.supportsCalibrationAPI = supportsCalibrationAPI; self.lut3DSize = lut3DSize
        self.supportsGamutMatrix = supportsGamutMatrix; self.isSimulated = isSimulated
    }
}

public struct TVInput: Hashable, Codable, Sendable, Identifiable {
    /// webOS input id, e.g. "HDMI_1".
    public var id: String
    public var label: String
    public var isConnected: Bool
    public init(id: String, label: String, isConnected: Bool) { self.id = id; self.label = label; self.isConnected = isConnected }
}

/// A snapshot of picture settings. Keys are webOS settings keys (e.g. "pictureMode", "backlight", "whiteBalanceRedGain").
/// Values keep the TV's own JSON representation so unknown keys round-trip unchanged.
public struct PictureSettings: Hashable, Codable, Sendable {
    public var pictureMode: String
    public var values: [String: JSONValue]
    public var capturedAt: Date

    public init(pictureMode: String, values: [String: JSONValue], capturedAt: Date = Date()) {
        self.pictureMode = pictureMode; self.values = values; self.capturedAt = capturedAt
    }

    public func int(_ key: String) -> Int? { values[key]?.intValue }
    public func string(_ key: String) -> String? { values[key]?.stringValue }
}

/// Minimal JSON value type used to round-trip TV settings without inventing schemas.
public enum JSONValue: Hashable, Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public var intValue: Int? {
        switch self {
        case .number(let d): Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }
    public var doubleValue: Double? { if case .number(let d) = self { d } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Parameters for the TV's HDR10 tone mapping (LG externalpq "tonemap params").
public struct ToneMapParameters: Hashable, Codable, Sendable {
    /// Target display peak the TV should map to, cd/m².
    public var displayLuminance: Int
    /// Mastering peak assumed for the content, cd/m².
    public var masteringPeak: Int
    /// Roll-off start as a percentage of the display peak.
    public var rolloffPoint: Int
    public init(displayLuminance: Int, masteringPeak: Int, rolloffPoint: Int) {
        self.displayLuminance = displayLuminance; self.masteringPeak = masteringPeak; self.rolloffPoint = rolloffPoint
    }
}

/// Dolby Vision "golden reference" display configuration uploaded to the TV.
public struct DolbyVisionConfig: Hashable, Codable, Sendable {
    public var whiteLevel: Double   // cd/m²
    public var blackLevel: Double   // cd/m²
    public var gamma: Double
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var white: Chromaticity
    public init(whiteLevel: Double, blackLevel: Double, gamma: Double, red: Chromaticity, green: Chromaticity, blue: Chromaticity, white: Chromaticity) {
        self.whiteLevel = whiteLevel; self.blackLevel = blackLevel; self.gamma = gamma
        self.red = red; self.green = green; self.blue = blue; self.white = white
    }
}

/// Commands of the LG internal-calibration (externalpq) API, expressed independently of the wire encoding.
/// `pictureMode` is the webOS picture mode id the data applies to (e.g. "expert1", "hdr_cinema", "dolby_cinema_dark", "game").
public enum CalibrationCommand: Hashable, Sendable {
    case start(pictureMode: String)
    case end(pictureMode: String)
    case upload1DLUT(LUT1D, pictureMode: String)
    case upload3DLUT(LUT3D, colorimetry: Colorimetry, pictureMode: String)
    case setGamutMatrix([Double], colorimetry: Colorimetry, pictureMode: String)   // 9 values, row-major
    case setToneMap(ToneMapParameters, pictureMode: String)
    case setDolbyVisionConfig(DolbyVisionConfig, pictureMode: String)
    /// Restores unity LUTs / default calibration data for the mode (LG "ddc reset").
    case resetCalibration(pictureMode: String)
}

/// A television we can read, adjust and calibrate. Implementations: `LGTVController` (webOS) and `SimulatedTVController`.
public protocol TVController: AnyObject, Sendable {
    var capabilities: TVCapabilities? { get async }
    func connect() async throws
    func disconnect() async
    /// Picture settings for the current input/signal (or for `pictureMode` where the TV supports a dimension query).
    func readPictureSettings(pictureMode: String?) async throws -> PictureSettings
    /// Writes individual picture settings for the current input/signal. Bounded by the caller.
    func writePictureSettings(_ changes: [String: JSONValue]) async throws
    func setPictureMode(_ mode: String) async throws
    func switchInput(_ inputID: String) async throws
    func sendCalibration(_ command: CalibrationCommand) async throws
}
