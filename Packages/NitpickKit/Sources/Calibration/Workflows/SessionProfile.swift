import Foundation
import ColorScience

/// What a session calibrates and how. Each preset has its own workflow; corrections are measured per mode, never copied.
public struct SessionProfile: Codable, Hashable, Sendable {
    public enum Usage: String, Codable, Hashable, Sendable { case movie, game }

    public var name: String
    public var usage: Usage
    public var dynamicRange: DynamicRange
    /// webOS input the Apple TV is plugged into.
    public var inputID: String
    /// webOS picture mode id to calibrate.
    public var pictureMode: String
    public var target: CalibrationTarget
    /// Use the externalpq API (1D/3D LUT, tonemap, DV config). Off = picture controls only.
    public var useInternalLUTs: Bool
    /// SDR movie: also build and upload a 3D LUT after the 1D LUT.
    public var cubeLUT: Bool
    public var cubeSize: Int
    /// Measured device grid per axis for the 3D LUT (5 → 125 patches, 9 → 729).
    public var cubeGridLevels: Int
    public var measurement: MeasurementSettings
    public var bounds: ControlBounds
    public var tolerances: Tolerances
    /// After a cancel/failure, also send `resetCalibration` for the mode if LUTs were uploaded this session.
    public var restoreLUTsOnCancel: Bool
    /// Dolby Vision: the completed HDR10 movie session whose measurements define the DV config.
    public var sourceSessionID: UUID?

    public init(name: String, usage: Usage, dynamicRange: DynamicRange, inputID: String = "HDMI_1", pictureMode: String,
                target: CalibrationTarget, useInternalLUTs: Bool, cubeLUT: Bool = false, cubeSize: Int = 33, cubeGridLevels: Int = 5,
                measurement: MeasurementSettings, bounds: ControlBounds = ControlBounds(), tolerances: Tolerances = Tolerances(),
                restoreLUTsOnCancel: Bool = false, sourceSessionID: UUID? = nil) {
        self.name = name; self.usage = usage; self.dynamicRange = dynamicRange; self.inputID = inputID
        self.pictureMode = pictureMode; self.target = target; self.useInternalLUTs = useInternalLUTs; self.cubeLUT = cubeLUT
        self.cubeSize = cubeSize; self.cubeGridLevels = cubeGridLevels; self.measurement = measurement; self.bounds = bounds
        self.tolerances = tolerances; self.restoreLUTsOnCancel = restoreLUTsOnCancel; self.sourceSessionID = sourceSessionID
    }

    /// Expert (Dark), BT.1886 100 cd/m²: OLED light/contrast, 2-point WB, 1D LUT, optional 3D LUT.
    public static let movieSDR = SessionProfile(name: "Movie SDR", usage: .movie, dynamicRange: .sdr, pictureMode: "expert1",
                                                target: .sdrMovie, useInternalLUTs: true, cubeLUT: true, measurement: .sdr)
    /// Game Optimizer, gamma 2.2 150 cd/m²: OLED light/contrast, 2-point and 20-point WB only.
    public static let gameSDR = SessionProfile(name: "Game SDR", usage: .game, dynamicRange: .sdr, pictureMode: "game",
                                               target: .sdrGame, useInternalLUTs: false, measurement: .sdr)
    /// HDR Cinema: tone analysis, tonemap parameters, 20-point WB below the knee.
    public static let movieHDR10 = SessionProfile(name: "Movie HDR10", usage: .movie, dynamicRange: .hdr10, pictureMode: "hdr_cinema",
                                                  target: .hdr10Movie, useInternalLUTs: true, measurement: .hdr)
    /// HDR Game Optimizer with HGIG: 2-point and 20-point WB, no uploads.
    public static let gameHDR10 = SessionProfile(name: "Game HDR10", usage: .game, dynamicRange: .hdr10, pictureMode: "hdr_game",
                                                 target: .hdr10Game, useInternalLUTs: false, measurement: .hdr)
    /// Dolby Vision Cinema Dark: config derived from a completed HDR10 movie session, then verified.
    public static func dolbyVision(source: UUID?) -> SessionProfile {
        SessionProfile(name: "Dolby Vision", usage: .movie, dynamicRange: .dolbyVision, pictureMode: "dolby_cinema_dark",
                       target: .dolbyVision, useInternalLUTs: true, measurement: .hdr, sourceSessionID: source)
    }
}
