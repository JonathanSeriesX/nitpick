import Foundation

/// `system/getSystemInfo` plus, when permitted, `getCurrentSWInformation`.
public struct LGSystemInfo: Sendable, Equatable {
    /// Retail model, e.g. `OLED65B4PUA`.
    public var modelName: String
    public var receiverType: String?
    public var serialNumber: String?
    /// Nil when `getCurrentSWInformation` is denied (`401` on webOS 26 with manifest B).
    public var software: LGSoftwareInfo?
    /// Nil when the firmware token is unknown or unreadable.
    public var profile: LGModelProfile? { software.flatMap { LGModelProfile(modelName: $0.modelToken) } }
}

/// `com.webos.service.update/getCurrentSWInformation`.
public struct LGSoftwareInfo: Sendable, Equatable {
    /// `webOSTV 10.3`.
    public var productName: String
    /// Firmware model token, e.g. `HE_DTV_W24H_AFADATAA` (chip type = characters 7..<11).
    public var modelToken: String
    /// `33.31.75` (= `major_ver` + "." + `minor_ver`).
    public var firmwareVersion: String
    public var majorVersion: String
    public var country: String?
    public var deviceID: String?
    /// From `product_name`, else from the firmware family (`33` → 10).
    public var release: WebOSRelease? { WebOSRelease(version: productName) ?? WebOSRelease(firmwareMajor: majorVersion) }

    public init(payload p: JSON) {
        productName = p["product_name"]?.stringValue ?? ""
        modelToken = p["model_name"]?.stringValue ?? ""
        majorVersion = p["major_ver"]?.stringValue ?? ""
        firmwareVersion = majorVersion + "." + (p["minor_ver"]?.stringValue ?? "")
        country = p["country"]?.stringValue
        deviceID = p["device_id"]?.stringValue
    }
}

/// One entry of `tv/getExternalInputList`.
public struct LGInput: Sendable, Equatable, Identifiable {
    /// `HDMI_1`…; pass to `switchInput`.
    public var id: String
    public var label: String
    public var connected: Bool
    /// `com.webos.app.hdmi2`; matches `foregroundApp()` while that input shows.
    public var appID: String?
}

/// `getPowerState` `state`: `Active`, `Active Standby`, `Suspend`, `Screen Off`, `Screen Saver`, `Power Off`.
public struct LGPowerState: Sendable, Equatable {
    public var state: String
    public var processing: String?
    public var isOn: Bool { state == "Active" || state == "Screen Saver" }
}

/// Outcome of a settings write through the luna bridge, whose own result is invisible (SPEC fact 16).
public struct LGSettingsWriteResult: Sendable, Equatable {
    public var requested: [String: JSON]
    /// Values read back after the write. Empty when the category carries a dimension (`picture$hdmi2.expert2.2d.x`),
    /// which SSAP cannot read.
    public var readBack: [String: JSON]
    /// Requested keys whose read-back equals the requested value (ignoring string/number encoding).
    public var applied: [String] { requested.keys.filter { k in readBack[k].map { $0.looselyEquals(requested[k]!) } ?? false }.sorted() }
    public var notApplied: [String] { requested.keys.filter { !applied.contains($0) }.sorted() }
    public var isVerified: Bool { !readBack.isEmpty && notApplied.isEmpty }
}

/// MACs from `com.webos.service.connectionmanager/getinfo`, for Wake-on-LAN.
public struct LGMACAddresses: Sendable, Equatable {
    public var wired: String?
    public var wifi: String?
}

/// High-level LG TV client: pairing, system queries, inputs, power, settings, and access to the calibration API.
public actor LGTV {
    public struct Options: Sendable {
        public var connection: SSAPConnection.Options
        public var promptTimeout: Duration
        /// Wait before reading back a luna-bridge write (LG_Buddy uses about 1 s).
        public var readbackDelay: Duration
        /// Wait after each externalpq command (bscpylgtv scripts wait 3 s).
        public var calibrationSettleDelay: Duration

        public init(
            connection: SSAPConnection.Options = .init(), promptTimeout: Duration = .seconds(60),
            readbackDelay: Duration = .seconds(1), calibrationSettleDelay: Duration = .seconds(3)
        ) {
            self.connection = connection
            self.promptTimeout = promptTimeout
            self.readbackDelay = readbackDelay
            self.calibrationSettleDelay = calibrationSettleDelay
        }
    }

    /// Connection state across reconnects. Single consumer.
    public nonisolated let state: AsyncStream<SSAPState>
    public private(set) var registration: SSAPRegistrationResult?
    public private(set) var hello: SSAPHello?
    public let options: Options

    private let credentials: any TVCredentialStore
    private let stateSink: AsyncStream<SSAPState>.Continuation
    private var connection: SSAPConnection?

    public init(credentials: any TVCredentialStore, options: Options = .init()) {
        self.credentials = credentials
        self.options = options
        (state, stateSink) = AsyncStream.makeStream()
    }

    // MARK: - Connection

    /// Connects and pairs (the TV may show its prompt: `state` yields `.pairing`).
    /// - Parameter id: the TV's UDN from discovery, so a pinned certificate is enforced during the TLS handshake.
    @discardableResult
    public func connect(host: String, id: String? = nil) async throws -> SSAPRegistrationResult {
        disconnect()
        let options = options.connection
        do {
            let (connection, result) = try await SSAPRegistration.pair(
                tvID: id, store: credentials, promptTimeout: self.options.promptTimeout
            ) {
                [weak self] pinned in
                var o = options
                o.pinnedFingerprint = pinned
                let c = SSAPConnection(host: host, options: o)
                Task { [weak self] in for await s in c.state { await self?.relay(s, from: c) } }
                try await c.open()
                return c
            }
            self.connection = connection
            registration = result
            hello = await connection.hello
            return result
        } catch {
            stateSink.yield(.disconnected(error))
            throw error
        }
    }

    /// Forwards states of the current connection; hides the close of a superseded pairing socket.
    private func relay(_ s: SSAPState, from c: SSAPConnection) {
        if case .disconnected = s, c !== connection { return }
        stateSink.yield(s)
    }

    public func disconnect() {
        guard let connection else { return }
        self.connection = nil
        registration = nil
        Task { await connection.close() }
        stateSink.yield(.disconnected(nil))
    }

    /// webOS release from hello (or nil before connecting).
    public var webOSRelease: WebOSRelease? { registration?.release }

    /// Raw SSAP request; returns the reply payload.
    @discardableResult
    public func request(_ uri: String, payload: JSON = [:]) async throws -> JSON {
        guard let connection else { throw LGError.notConnected }
        return try await connection.request(uri, payload: payload)
    }

    public func subscribe(_ uri: String, payload: JSON = [:]) async throws -> AsyncStream<JSON> {
        guard let connection else { throw LGError.notConnected }
        return try await connection.subscribe(uri, payload: payload)
    }

    // MARK: - System

    public func systemInfo() async throws -> LGSystemInfo {
        let p = try await request("system/getSystemInfo")
        var software: LGSoftwareInfo?
        do { software = try await softwareInfo() } catch let e as LGError where e.serverCode == 401 { software = nil }
        return LGSystemInfo(
            modelName: p["modelName"]?.stringValue ?? "", receiverType: p["receiverType"]?.stringValue,
            serialNumber: p["serialNumber"]?.stringValue, software: software)
    }

    /// Needs `READ_UPDATE_INFO` (signed manifest); `401` on webOS 26 with manifest B.
    public func softwareInfo() async throws -> LGSoftwareInfo {
        LGSoftwareInfo(payload: try await request("com.webos.service.update/getCurrentSWInformation"))
    }

    public func externalInputs() async throws -> [LGInput] {
        let devices = try await request("tv/getExternalInputList")["devices"]?.arrayValue ?? []
        return devices.compactMap { d in
            guard let id = d["id"]?.stringValue else { return nil }
            return LGInput(
                id: id, label: d["label"]?.stringValue ?? id, connected: d["connected"]?.boolValue ?? false,
                appID: d["appId"]?.stringValue)
        }
    }

    /// `inputId` such as `HDMI_2`.
    public func switchInput(_ inputID: String) async throws {
        try await request("tv/switchInput", payload: ["inputId": .string(inputID)])
    }

    /// Foreground app id, e.g. `com.webos.app.hdmi2`; empty while powering down.
    public func foregroundApp() async throws -> String {
        try await request("com.webos.applicationManager/getForegroundAppInfo")["appId"]?.stringValue ?? ""
    }

    public func powerState() async throws -> LGPowerState {
        let p = try await request("com.webos.service.tvpower/power/getPowerState")
        return LGPowerState(state: p["state"]?.stringValue ?? "", processing: p["processing"]?.stringValue)
    }

    /// Does not wait for a reply: the TV often drops it while shutting down.
    public func turnOff() async throws {
        guard let connection else { throw LGError.notConnected }
        try await connection.send("system/turnOff")
    }

    public func toast(_ message: String) async throws {
        try await request("system.notifications/createToast", payload: ["message": .string(message)])
    }

    public func macAddresses() async throws -> LGMACAddresses {
        let p = try await request("com.webos.service.connectionmanager/getinfo")
        return LGMACAddresses(wired: p["wiredInfo"]?["macAddress"]?.stringValue, wifi: p["wifiInfo"]?["macAddress"]?.stringValue)
    }

    // MARK: - Settings

    /// Reads settings of the current context. Keys the TV refuses (`errorKey`) are dropped and the rest re-read once.
    public func getSystemSettings(category: String, keys: [String]) async throws -> [String: JSON] {
        do {
            return try await request(
                "settings/getSystemSettings", payload: ["category": .string(category), "keys": .array(keys.map(JSON.string))])["settings"]?
                .objectValue ?? [:]
        } catch LGError.server(let code, let message, let payload) {
            let refused = Set(payload["errorKey"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let rest = keys.filter { !refused.contains($0) }
            guard !refused.isEmpty, !rest.isEmpty, rest.count < keys.count else {
                throw LGError.server(code: code, message: message, payload: payload)
            }
            return try await getSystemSettings(category: category, keys: rest)
        }
    }

    /// Defaults to `LGPictureKeys.calibrationRelevant`.
    public func getPictureSettings(keys: [String] = LGPictureKeys.calibrationRelevant) async throws -> [String: JSON] {
        try await getSystemSettings(category: "picture", keys: keys)
    }

    public func currentPictureMode() async throws -> String {
        guard let mode = try await getPictureSettings(keys: ["pictureMode"])["pictureMode"]?.stringValue else {
            throw LGError.malformedResponse("no pictureMode in settings reply")
        }
        return mode
    }

    /// Writes any settings key through the createAlert luna bridge (SPEC §3.7), closes the alert, waits
    /// `readbackDelay`, and reads the keys back. `category` may carry a dimension (`picture$hdmi2.expert2.2d.x`);
    /// such writes are not read back. A blank alert may flash on screen: do not measure during a write.
    public func setSystemSettings(category: String, settings: [String: JSON]) async throws -> LGSettingsWriteResult {
        let luna: JSON = "luna://com.webos.settingsservice/setSystemSettings"
        let params: JSON = ["category": .string(category), "settings": .object(settings)]
        let alert = try await request(
            "system.notifications/createAlert",
            payload: [
                "message": " ",
                "buttons": [["label": "", "onClick": luna, "params": params]],
                "onclose": ["uri": luna, "params": params],
                "onfail": ["uri": luna, "params": params],
            ])
        guard let alertID = alert["alertId"]?.stringValue else { throw LGError.malformedResponse("createAlert without alertId") }
        try await closeAlert(alertID)
        guard !category.contains("$") else { return LGSettingsWriteResult(requested: settings, readBack: [:]) }
        if options.readbackDelay > .zero { try await Task.sleep(for: options.readbackDelay) }
        let read = try await getSystemSettings(category: category, keys: settings.keys.sorted())
        return LGSettingsWriteResult(requested: settings, readBack: read)
    }

    /// Closing fires the alert's `onclose` luna call. Which id form the TV wants is unconfirmed (SPEC (b)7): try
    /// `com.webos.service.apiadapter-<n>` first, then the raw `…apiadapter.pub-<n>`.
    private func closeAlert(_ alertID: String) async throws {
        let rewritten = alertID.replacingOccurrences(of: "com.webos.service.apiadapter.pub-", with: "com.webos.service.apiadapter-")
        if rewritten != alertID, (try? await request("system.notifications/closeAlert", payload: ["alertId": .string(rewritten)])) != nil {
            return
        }
        try await request("system.notifications/closeAlert", payload: ["alertId": .string(alertID)])
    }

    /// Validates every key against `LGPictureKeys.rules`, then writes them to the current picture context.
    public func setPictureSettings(_ settings: [String: JSON]) async throws -> LGSettingsWriteResult {
        for (key, value) in settings { try LGPictureKeys.validate(key: key, value: value) }
        return try await setSystemSettings(category: "picture", settings: settings)
    }

    public func setPictureSetting(key: String, value: JSON) async throws -> LGSettingsWriteResult {
        try await setPictureSettings([key: value])
    }

    /// Sets the current input's picture mode (a `pictureMode` setting value such as `expert2`).
    public func setPictureMode(_ mode: String) async throws -> LGSettingsWriteResult {
        try await setPictureSettings(["pictureMode": .string(mode)])
    }

    // MARK: - Calibration

    /// The externalpq calibration API for this connection.
    /// - Throws: `LGError.calibrationUnavailable` with manifest B or on webOS 26 (SPEC §0).
    public func calibration() async throws -> LGCalibration {
        guard let connection, let registration else { throw LGError.notConnected }
        guard registration.calibrationAPIAvailable else {
            let reason =
                registration.release?.blocksThirdPartyCalibration == true
                ? "webOS \(registration.release!.marketingVersion) blocks third-party calibration (LG removed it in webOS 26)"
                : "paired with the unsigned manifest; the TV does not grant calibration rights to it"
            throw LGError.calibrationUnavailable(reason: reason)
        }
        let profile = try await systemInfo().profile
        return LGCalibration(connection: connection, profile: profile, settleDelay: options.calibrationSettleDelay)
    }
}
