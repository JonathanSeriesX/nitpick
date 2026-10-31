import Foundation
import ColorScience
import LGControl

/// `TVController` backed by a real LG webOS TV over SSAP (LGControl). Picture-mode ids are webOS calibration-bank
/// names ("expert1", "hdr_cinema", "dolby_cinema_dark", "game"); settings-style names ("hdrCinema") are accepted too.
public final class LGTVController: TVController, @unchecked Sendable {
    public let host: String
    public let tvID: String?
    private let tv: LGTV
    private let lock = NSLock()
    private var _capabilities: TVCapabilities?
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
        let registration = try await tv.connect(host: host, id: tvID)
        let info = try await tv.systemInfo()
        let inputs = (try? await tv.externalInputs()) ?? []
        let release = registration.release
        let blocked = release?.blocksThirdPartyCalibration ?? false
        let caps = TVCapabilities(
            modelName: info.modelName,
            firmwareVersion: info.software?.firmwareVersion ?? "",
            webOSVersion: release?.description,
            inputs: inputs.map { TVInput(id: $0.id, label: $0.label, isConnected: $0.connected) },
            supportsCalibrationAPI: registration.calibrationAPIAvailable && !blocked,
            lut3DSize: info.profile?.lut3DSize ?? 17,
            supportsGamutMatrix: info.profile?.supportsGamutMatrix ?? true)
        lock.withLock { _capabilities = caps }
    }

    public func disconnect() async {
        await tv.disconnect()
        lock.withLock { _capabilities = nil; calibration = nil }
    }

    public func readPictureSettings(pictureMode: String?) async throws -> PictureSettings {
        let values = try await tv.getPictureSettings()
        var mode = values["pictureMode"]?.stringValue ?? ""
        if mode.isEmpty { mode = try await tv.currentPictureMode() }
        return PictureSettings(pictureMode: mode, values: try Self.convert(values))
    }

    public func writePictureSettings(_ changes: [String: JSONValue]) async throws {
        let result = try await tv.setPictureSettings(try Self.convert(changes))
        guard result.isVerified else {
            throw CalibrationError.refused("TV did not apply: \(result.notApplied.joined(separator: ", "))")
        }
    }

    public func setPictureMode(_ mode: String) async throws {
        let result = try await tv.setPictureMode(mode)
        guard result.isVerified else { throw CalibrationError.refused("TV did not switch to picture mode \(mode)") }
    }

    public func switchInput(_ inputID: String) async throws {
        try await tv.switchInput(inputID)
    }

    public func sendCalibration(_ command: CalibrationCommand) async throws {
        switch command {
        case .start(let mode):
            let cal = try await tv.calibration()
            try await cal.start(try Self.picMode(mode))
            lock.withLock { calibration = cal }
        case .end:
            try await session().end()
            lock.withLock { calibration = nil }
        case .upload1DLUT(let lut, _):
            try await session().upload1DLUT(lut)
        case .upload3DLUT(let lut, let colorimetry, _):
            try await session().upload3DLUT(lut, to: colorimetry == .bt709 ? .bt709LUT3D : .bt2020LUT3D)
        case .setGamutMatrix(let m, let colorimetry, _):
            guard m.count == 9 else { throw CalibrationError.invalidState("gamut matrix needs 9 values") }
            try await session().uploadMatrix(Matrix3(m), to: colorimetry == .bt709 ? .bt709Gamut : .bt2020Gamut)
        case .setToneMap(let p, _):
            try await session().uploadToneMap(LGToneMapParameters(panelPeak: p.displayLuminance, masteringPeak1: p.masteringPeak, rolloff1: p.rolloffPoint))
        case .setDolbyVisionConfig(let c, let mode):
            let config = DolbyVisionDisplayConfig(pictureMode: try Self.picMode(mode), tMax: c.whiteLevel, tMin: c.blackLevel, tGamma: c.gamma,
                                                  red: c.red, green: c.green, blue: c.blue)
            try await session().uploadDolbyConfig(config)
        case .resetCalibration(let mode):
            // Factory data for the bank; opens/closes a session if none is active.
            if let cal = lock.withLock({ calibration }) {
                try await cal.resetToFactory()
            } else {
                let cal = try await tv.calibration()
                try await cal.start(try Self.picMode(mode))
                defer { Task { try? await cal.end() } }
                try await cal.resetToFactory()
            }
        }
    }

    // MARK: - Helpers

    private func session() throws -> LGCalibration {
        guard let cal = lock.withLock({ calibration }) else {
            throw CalibrationError.invalidState("calibration upload outside a CAL_START…CAL_END session")
        }
        return cal
    }

    static func picMode(_ id: String) throws -> LGPicMode {
        if let m = LGPicMode(rawValue: id) ?? LGPicMode(pictureMode: id) { return m }
        throw CalibrationError.invalidState("\(id) has no LG calibration bank")
    }

    /// Both modules carry their own small JSON enum; a Codable round trip converts between them.
    static func convert(_ values: [String: JSON]) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(values))
    }

    static func convert(_ values: [String: JSONValue]) throws -> [String: JSON] {
        try JSONDecoder().decode([String: JSON].self, from: JSONEncoder().encode(values))
    }
}
