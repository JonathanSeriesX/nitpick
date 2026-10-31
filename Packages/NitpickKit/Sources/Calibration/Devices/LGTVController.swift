import ColorScience
import Foundation
import LGControl

/// `TVController` backed by a real LG webOS TV over SSAP (LGControl).
///
/// - Picture-mode ids are webOS calibration-bank names ("expert1", "hdr_cinema", "dolby_cinema_dark", "game");
///   settings-style names ("hdrCinema") are accepted too. `setPictureMode` writes the matching `pictureMode` value.
/// - `PictureKey.twentyPoint` (5…100 % in 5 % steps) maps onto LG's 22-point (webOS 24/25) or 24-point (webOS 26)
///   `whiteBalanceRed/Green/Blue` arrays: reads synthesize it, writes merge it into the current arrays (points the engine
///   does not use keep their values) and select the multi-point method, as `LGWhiteBalanceMultiPoint` does.
/// - Calibration uploads need an open `.start` for the same bank; `.resetCalibration` outside a session opens and
///   closes one itself. `TVCapabilities.supportsCalibrationAPI` is false on webOS 26 and manifest-B pairings, where
///   `.start` throws `.refused`.
/// - LGControl errors surface as `CalibrationError` (TV timeouts as `.timeout("TV")`, write rejections as `.outOfRange`).
public final class LGTVController: TVController, @unchecked Sendable {
    public let host: String
    public let tvID: String?
    private let tv: LGTV
    private let lock = NSLock()
    private var _capabilities: TVCapabilities?
    /// The calibration API of the session opened by `.start`; kept even if `.start` was cancelled, so `.end` can close it.
    private var calibration: LGCalibration?

    public init(host: String, tvID: String? = nil, credentials: any TVCredentialStore, options: LGTV.Options = .init()) {
        self.host = host
        self.tvID = tvID
        self.tv = LGTV(credentials: credentials, options: options)
    }

    /// Pairing/connection state of the underlying SSAP connection, for the UI.
    public var state: AsyncStream<SSAPState> { tv.state }

    public var capabilities: TVCapabilities? {
        get async { lock.withLock { _capabilities } }
    }

    public func connect() async throws {
        try await lg {
            lock.withLock { calibration = nil }
            let registration = try await tv.connect(host: host, id: tvID)
            let info = try await tv.systemInfo()
            let inputs = try await tv.externalInputs()
            let caps = TVCapabilities(
                modelName: info.modelName,
                firmwareVersion: info.software?.firmwareVersion ?? "",
                webOSVersion: registration.release?.description,
                inputs: inputs.map { TVInput(id: $0.id, label: $0.label, isConnected: $0.connected) },
                supportsCalibrationAPI: registration.calibrationAPIAvailable,
                lut3DSize: info.profile?.lut3DSize ?? 17,
                supportsGamutMatrix: info.profile?.supportsGamutMatrix ?? true)
            lock.withLock { _capabilities = caps }
        }
    }

    public func disconnect() async {
        await tv.disconnect()
        lock.withLock {
            _capabilities = nil
            calibration = nil
        }
    }

    public func readPictureSettings(pictureMode: String?) async throws -> PictureSettings {
        try await lg {
            let values = try await tv.getPictureSettings()
            var mode = values["pictureMode"]?.stringValue ?? ""
            if mode.isEmpty { mode = try await tv.currentPictureMode() }
            var settings = try Self.convert(values)
            settings[PictureKey.twentyPoint] = Self.twentyPoint(from: values)
            return PictureSettings(pictureMode: mode, values: settings)
        }
    }

    public func writePictureSettings(_ changes: [String: JSONValue]) async throws {
        try await lg {
            let current = changes[PictureKey.twentyPoint] == nil ? [:] : try await tv.getPictureSettings(keys: Self.multiPointKeys)
            let result = try await tv.setPictureSettings(try Self.lgSettings(changes, current: current))
            guard result.isVerified else {
                throw CalibrationError.refused("TV did not apply: \(result.notApplied.joined(separator: ", "))")
            }
        }
    }

    public func setPictureMode(_ mode: String) async throws {
        let value = LGPicMode(rawValue: mode)?.pictureModeSetting ?? mode
        let result = try await lg { try await tv.setPictureMode(value) }
        guard result.isVerified else { throw CalibrationError.refused("TV did not switch to picture mode \(mode)") }
    }

    public func switchInput(_ inputID: String) async throws {
        try await lg { try await tv.switchInput(inputID) }
    }

    public func sendCalibration(_ command: CalibrationCommand) async throws {
        try await lg {
            switch command {
            case .start(let mode):
                let bank = try Self.picMode(mode)
                let cal = try await tv.calibration()
                lock.withLock { calibration = cal }
                try await cal.start(bank)
            case .end:
                guard let cal = lock.withLock({ calibration }) else {
                    throw CalibrationError.invalidState("No calibration session is open")
                }
                lock.withLock { calibration = nil }
                try await cal.end()
            case .upload1DLUT(let lut, let mode):
                try await session(mode).upload1DLUT(lut)
            case .upload3DLUT(let lut, let colorimetry, let mode):
                try await session(mode).upload3DLUT(lut, to: colorimetry == .bt709 ? .bt709LUT3D : .bt2020LUT3D)
            case .setGamutMatrix(let m, let colorimetry, let mode):
                guard m.count == 9 else { throw CalibrationError.outOfRange(key: "gamut matrix", value: "\(m.count) values") }
                try await session(mode).uploadMatrix(Matrix3(m), to: colorimetry == .bt709 ? .bt709Gamut : .bt2020Gamut)
            case .setToneMap(let p, let mode):
                try await session(mode).uploadToneMap(
                    LGToneMapParameters(panelPeak: p.displayLuminance, masteringPeak1: p.masteringPeak, rolloff1: p.rolloffPoint))
            case .setDolbyVisionConfig(let c, let mode):
                // LG's format has no white: the TV assumes D65 after its 1D LUT is calibrated.
                let config = DolbyVisionDisplayConfig(
                    pictureMode: try Self.picMode(mode), tMax: c.whiteLevel, tMin: c.blackLevel, tGamma: c.gamma,
                    red: c.red, green: c.green, blue: c.blue)
                try await session(mode).uploadDolbyConfig(config)
            case .resetCalibration(let mode):
                if let open = lock.withLock({ calibration }), await open.session != nil {
                    try await session(mode).resetToFactory()
                } else {
                    // Factory data needs a session: open a temporary one and always close it before returning.
                    let cal = try await tv.calibration()
                    try await cal.start(try Self.picMode(mode))
                    do { try await cal.resetToFactory() } catch {
                        try? await cal.end()
                        throw error
                    }
                    try await cal.end()
                }
            }
        }
    }

    // MARK: - Helpers

    /// The open session, which must be for `mode`'s bank: uploads never go to a bank other than the one named.
    private func session(_ mode: String) async throws -> LGCalibration {
        let bank = try Self.picMode(mode)
        guard let cal = lock.withLock({ calibration }), await cal.session == bank else {
            throw CalibrationError.invalidState("CAL_START for \(mode) is required before uploading")
        }
        return cal
    }

    static func picMode(_ id: String) throws -> LGPicMode {
        if let m = LGPicMode(rawValue: id) ?? LGPicMode(pictureMode: id) { return m }
        throw CalibrationError.invalidState("\(id) has no LG calibration bank")
    }

    static let multiPointKeys = ["whiteBalanceRed", "whiteBalanceGreen", "whiteBalanceBlue"]

    /// The engine's 20-point table from LG's multi-point arrays; nil when the TV reports none of a known length.
    static func twentyPoint(from values: [String: JSON]) -> JSONValue? {
        guard let wb = try? LGWhiteBalanceMultiPoint(settings: values),
            let levels = LGWhiteBalanceMultiPoint.ireLevels(count: wb.pointCount)
        else { return nil }
        let rows = PictureKey.twentyPointIRE.compactMap { ire in
            levels.firstIndex(of: Double(ire)).map { [wb.red[$0], wb.green[$0], wb.blue[$0]] }
        }
        return rows.count == 20 ? PictureKey.encodeTwentyPoint(rows) : nil
    }

    /// LG settings for `changes`; `PictureKey.twentyPoint` is merged into `current`'s multi-point arrays. Keys the caller
    /// names explicitly win over what the 20-point table implies (a restore writes the snapshot's own arrays and method).
    static func lgSettings(_ changes: [String: JSONValue], current: [String: JSON]) throws -> [String: JSON] {
        let explicit = try convert(changes.filter { $0.key != PictureKey.twentyPoint })
        guard let table = changes[PictureKey.twentyPoint] else { return explicit }
        guard let rows = PictureKey.decodeTwentyPoint(table) else {
            throw CalibrationError.outOfRange(key: PictureKey.twentyPoint, value: "\(table)")
        }
        var wb = try LGWhiteBalanceMultiPoint(settings: current.merging(explicit) { $1 })
        let levels = LGWhiteBalanceMultiPoint.ireLevels(count: wb.pointCount) ?? []
        for (row, ire) in zip(rows, PictureKey.twentyPointIRE) {
            guard let i = levels.firstIndex(of: Double(ire)) else {
                throw CalibrationError.unsupportedSetting("\(PictureKey.twentyPoint) on a \(wb.pointCount)-point white balance")
            }
            (wb.red[i], wb.green[i], wb.blue[i]) = (row[0], row[1], row[2])
        }
        return try wb.settings().merging(explicit) { $1 }
    }

    /// Both modules carry their own small JSON enum; a Codable round trip converts between them.
    static func convert(_ values: [String: JSON]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(values))
    }

    static func convert(_ values: [String: JSONValue]) throws -> [String: JSON] {
        try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(values))
    }

    /// Runs an LGControl call and rethrows its errors as `CalibrationError`.
    private func lg<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as LGError { throw Self.engineError(error) }
    }

    static func engineError(_ error: LGError) -> CalibrationError {
        switch error {
        case .notConnected: .notConnected("TV")
        case .connectionFailed(let why): .notConnected("TV (\(why))")
        case .timeout: .timeout("TV")
        case .certificateChanged: .refused("The TV presented a different certificate than at pairing; pair it again if this is expected")
        case .pairingDenied: .refused("Pairing was declined on the TV")
        case .pairingRejected(let why): .refused("The TV rejected pairing: \(why)")
        case .server(_, let message, _): .deviceFailure("TV: \(message)")
        case .calibrationUnavailable(let reason): .refused("The TV's calibration API is unavailable: \(reason)")
        case .outOfRange(let key, let value, _): .outOfRange(key: key, value: value)
        case .invalidPayload(let why): .invalidState(why)
        case .unsupported(let why): .unsupportedSetting(why)
        case .malformedResponse(let why): .deviceFailure("TV: \(why)")
        }
    }
}
