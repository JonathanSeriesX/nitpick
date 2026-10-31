import ColorScience
import Foundation

/// The externalpq calibration API (SPEC §5) on one connection. Get it from `LGTV.calibration()`, which refuses
/// webOS 26 and manifest-B pairings. Every data command needs an open `CAL_START…CAL_END` session tracked here, and
/// every payload passes `PayloadValidator` before it is sent. A `401` from the TV becomes `calibrationUnavailable`.
///
/// Typical run: `start(.expert2)` → `bypass()` → `setValue(.contrastUI, 85)` → `upload1DLUT` → `upload3DLUT` → `end()`.
public actor LGCalibration {
    public enum CalStartForm: Sendable {
        /// bscpylgtv form (no data); on `500` retry once with `.zeroFloats`.
        case automatic
        /// `{command, picMode, profileNo, programID}` only.
        case noData
        /// Calman form: plus nine zero floats, `dataOpt 1`.
        case zeroFloats
    }

    public nonisolated let profile: LGModelProfile?
    /// The bank between a confirmed `CAL_START` and `CAL_END`.
    public private(set) var session: LGPicMode?
    /// Wait after `CAL_START`, each upload and `CAL_END` (bscpylgtv scripts wait 3 s).
    public let settleDelay: Duration
    private let connection: SSAPConnection

    public init(connection: SSAPConnection, profile: LGModelProfile?, settleDelay: Duration = .seconds(3)) {
        self.connection = connection
        self.profile = profile
        self.settleDelay = settleDelay
    }

    // MARK: - Session

    /// Enters calibration mode for `picMode`. The TV must already show that picture mode with a matching signal
    /// (SDR / HDR10 / Dolby Vision in relative mode). `CAL_START` forces Warm 50 and `colorGamut` `wide`.
    /// After a timeout `CAL_END` is sent on the same socket; after an explicit rejection it is not (SPEC §5.4). After a
    /// cancellation the session stays open (the TV may be in calibration mode) until `end()`.
    public func start(_ picMode: LGPicMode, form: CalStartForm = .automatic) async throws {
        guard session == nil else {
            throw LGError.invalidPayload("calibration session for \(session!.rawValue) still open; call end() first")
        }
        // Cancelled before anything was sent: no session, so no stray CAL_END can close another client's (SPEC §5.4).
        try Task.checkCancellation()
        let forms: [CalStartForm] = form == .automatic ? [.noData, .zeroFloats] : [form]
        for (attempt, f) in forms.enumerated() {
            var payload = envelope(.calStart, picMode)
            if f == .zeroFloats { payload.merge(dataFields(ExternalPQEncoder.calStartZeros, option: .applyAndSave)) { $1 } }
            do {
                try await call(payload)
                session = picMode
                try await settle()
                return
            } catch LGError.timeout(let what) {
                _ = try? await call(envelope(.calEnd, picMode))
                throw LGError.timeout(what)
            } catch let error as LGError where error.serverCode == 500 && attempt + 1 < forms.count {
                continue
            } catch is CancellationError {
                // CAL_START may have reached the TV: keep the session so `end()` (from an uncancelled task) can close it.
                session = picMode
                throw CancellationError()
            }
        }
    }

    /// Leaves calibration mode and commits. The session is closed even if the TV errors; then restart the TV
    /// before the next session (SPEC §5.4).
    public func end() async throws {
        guard let picMode = session else { throw LGError.invalidPayload("CAL_END without CAL_START") }
        session = nil
        try await call(envelope(.calEnd, picMode))
        try await settle()
    }

    // MARK: - Uploads (inside a session)

    /// 1D LUT (`1D_DPG_DATA`). Use `.apply` while iterating and `.applyAndSave` for the final upload.
    public func upload1DLUT(_ lut: LUT1D, option: ExternalPQOption = .applyAndSave) async throws {
        try await send(ExternalPQEncoder.lut1D(lut), option: option)
    }

    /// 3D LUT into the BT.709 or BT.2020 slot. The LUT is resampled 33 → 17 when the TV needs 17 points.
    public func upload3DLUT(_ lut: LUT3D, to command: ExternalPQCommand = .bt709LUT3D, option: ExternalPQOption = .applyAndSave)
        async throws
    {
        guard let size = profile?.lut3DSize else { throw LGError.unsupported("3D LUT size unknown for this TV") }
        try await send(ExternalPQEncoder.lut3D(lut, size: size, command: command), option: option)
    }

    /// 3×3 matrix into `BT709_3BY3_GAMUT_DATA`, `BT2020_3BY3_GAMUT_DATA` or (2019 chips) `HDR_3BY3_GAMUT_DATA`.
    public func uploadMatrix(_ m: Matrix3, to command: ExternalPQCommand = .bt709Gamut, option: ExternalPQOption = .applyAndSave)
        async throws
    {
        if command == .hdrGamut, profile?.supportsHDRGamutMatrix != true {
            throw LGError.unsupported("HDR_3BY3_GAMUT_DATA is for 2019 chips only")
        }
        try await send(ExternalPQEncoder.matrix(m, command: command), option: option)
    }

    /// UI data (`BACKLIGHT_UI_DATA` etc., 0–100) or a flag (`1D_DPG_EN`, `1D_2_2_EN`, `1D_0_45_EN`, `3BY3_GAMUT_EN`, 0/1).
    public func setValue(_ command: ExternalPQCommand, _ value: Int, option: ExternalPQOption = .applyAndSave) async throws {
        try await send(ExternalPQEncoder.value(value, command: command), option: option)
    }

    /// HDR10 banks only.
    public func uploadToneMap(_ parameters: LGToneMapParameters, option: ExternalPQOption = .applyAndSave) async throws {
        guard session?.signalClass == .hdr10 else { throw LGError.invalidPayload("1D_TONEMAP_PARAM needs an HDR10 session") }
        try await send(ExternalPQEncoder.toneMap(parameters), option: option)
    }

    /// Dolby Vision banks only; the text format comes from the model profile (2019 for the B4).
    /// bscpylgtv marks the API path "not recommended on >=2020 models"; the USB file is the alternative.
    public func uploadDolbyConfig(_ config: DolbyVisionDisplayConfig, option: ExternalPQOption = .applyAndSave) async throws {
        guard session?.signalClass == .dolbyVision, config.pictureMode == session else {
            throw LGError.invalidPayload("DOLBY_CFG_DATA needs a Dolby Vision session for \(config.pictureMode.rawValue)")
        }
        guard let format = profile?.dolbyConfigFormat else { throw LGError.unsupported("no Dolby Vision config format for this TV") }
        try await send(ExternalPQEncoder.dolbyConfig(config.text(format: format)), option: option)
    }

    /// Bypass ("DDC reset", SPEC §5.8): unity data for the session's signal class.
    /// SDR: de-gamma off, re-gamma off, identity 3×3 ×2, unity 3D LUT ×2, then (optional) unity 1D LUT.
    /// HDR10 and Dolby Vision: unity 1D LUT.
    public func bypass(include1DLUT: Bool = true) async throws {
        guard let mode = session else { throw LGError.invalidPayload("bypass outside CAL_START…CAL_END") }
        if mode.signalClass == .sdr {
            try await setValue(.degamma22Enable, 0)
            try await setValue(.regamma045Enable, 0)
            try await uploadMatrix(.identity, to: .bt709Gamut)
            try await uploadMatrix(.identity, to: .bt2020Gamut)
            let size = profile?.lut3DSize ?? 17
            try await upload3DLUT(.identity(size: size), to: .bt709LUT3D)
            try await upload3DLUT(.identity(size: size), to: .bt2020LUT3D)
            if include1DLUT { try await upload1DLUT(.identity()) }
        } else {
            try await upload1DLUT(.identity())
        }
    }

    /// Factory reset of the session's bank (`dataOpt 2`, empty data). SDR: the seven bypass commands. HDR10: the same
    /// (+ `1D_TONEMAP_PARAM` when `includeOptional`). Dolby Vision: `1D_DPG_DATA` (+ `DOLBY_CFG_DATA`).
    public func resetToFactory(includeOptional: Bool = false) async throws {
        guard let mode = session else { throw LGError.invalidPayload("reset outside CAL_START…CAL_END") }
        let sdr: [ExternalPQCommand] = [.degamma22Enable, .regamma045Enable, .bt709Gamut, .bt2020Gamut, .bt709LUT3D, .bt2020LUT3D, .lut1D]
        let commands: [ExternalPQCommand] =
            switch mode.signalClass {
            case .sdr: sdr
            case .hdr10: sdr + (includeOptional ? [.toneMap] : [])
            case .dolbyVision: [.lut1D] + (includeOptional ? [.dolbyConfig] : [])
            }
        for command in commands {
            var payload = envelope(command, mode)
            payload.merge([
                "data": "", "dataCount": 0, "dataType": .string(command.dataType!.rawValue),
                "dataOpt": .number(Double(ExternalPQOption.resetToFactory.rawValue)),
            ]) { $1 }
            try await call(payload)
            try await settle()
        }
    }

    // MARK: - Readback (any time)

    /// Reads the active picture mode's data. See `ExternalPQReadback.label` for how to present it.
    public func read(_ getter: ExternalPQGetter) async throws -> ExternalPQReadback {
        try ExternalPQReadback(
            getter: getter, payload: await call(["command": .string(getter.rawValue)], uri: "externalpq/getExternalPqData"))
    }

    // MARK: - Wire

    private func send(_ data: ExternalPQData, option: ExternalPQOption) async throws {
        guard let mode = session else { throw LGError.invalidPayload("\(data.command.rawValue) outside CAL_START…CAL_END") }
        guard option != .resetToFactory else { throw LGError.invalidPayload("use resetToFactory() for dataOpt 2") }
        try PayloadValidator.validate(data, lut3DSize: profile?.lut3DSize)
        var payload = envelope(data.command, mode)
        payload.merge(dataFields(data, option: option)) { $1 }
        try await call(payload)
        try await settle()
    }

    /// `picMode` goes on every command, as Calman sends it (SPEC §5.1).
    private func envelope(_ command: ExternalPQCommand, _ picMode: LGPicMode) -> [String: JSON] {
        ["command": .string(command.rawValue), "picMode": .string(picMode.rawValue), "profileNo": 0, "programID": 1]
    }

    private func dataFields(_ data: ExternalPQData, option: ExternalPQOption) -> [String: JSON] {
        [
            "data": .string(data.base64), "dataCount": .number(Double(data.count)), "dataType": .string(data.dataType.rawValue),
            "dataOpt": .number(Double(option.rawValue)),
        ]
    }

    @discardableResult
    private func call(_ payload: [String: JSON], uri: String = "externalpq/setExternalPqData") async throws -> JSON {
        do {
            return try await connection.request(uri, payload: .object(payload))
        } catch let error as LGError where error.serverCode == 401 {
            if case .server(_, let message, _) = error { throw LGError.calibrationUnavailable(reason: message) }
            throw error
        }
    }

    private func settle() async throws {
        if settleDelay > .zero { try await Task.sleep(for: settleDelay) }
    }
}
