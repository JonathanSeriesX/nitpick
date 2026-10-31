import Foundation
import Network

/// A local fake LG B4 for tests and the app's "fake LG TV" demo: plain `ws://127.0.0.1:<port>` (connect with
/// `allowInsecure`), replaying the SPEC §(c) fixtures. Models pairing (PROMPT → accept/deny/ignore), webOS 24/25/26
/// rights, settings with a loose `[input, pictureMode]` dimension model, the createAlert luna bridge, and externalpq with
/// `CAL_START…CAL_END` ordering, payload checks and readback of stored uploads. Records every client frame.
public actor FakeWebOSServer {
    public enum Platform: Sendable {
        /// Release 9.2.2, firmware 23.x.
        case webOS24
        /// Release 10.3.0, firmware 33.31.75 (the fixture B4).
        case webOS25
        /// Release 11.1.0, firmware 43.x: signed manifest → `403 … blacklisted`; no calibration, settings or SW-info rights.
        case webOS26
    }

    public enum Pairing: Sendable {
        case accept(after: Duration)
        case deny(after: Duration)
        /// Never answers the prompt (client times out).
        case ignore
    }

    public struct Configuration: Sendable {
        public var platform: Platform
        public var pairing: Pairing
        /// Signal class on screen: `sdr`, `hdr` or `dolbyHdr`; decides which calibration banks accept `CAL_START`.
        public var dynamicRange: String
        /// False makes `closeAlert` accept only the raw `…apiadapter.pub-<n>` id.
        public var acceptsRewrittenAlertID: Bool
        /// False omits `deviceOSReleaseVersion` from hello (the client then cannot pick the manifest up front).
        public var reportsReleaseInHello: Bool

        public init(
            platform: Platform = .webOS25, pairing: Pairing = .accept(after: .milliseconds(50)),
            dynamicRange: String = "sdr", acceptsRewrittenAlertID: Bool = true, reportsReleaseInHello: Bool = true
        ) {
            (self.platform, self.pairing, self.dynamicRange) = (platform, pairing, dynamicRange)
            (self.acceptsRewrittenAlertID, self.reportsReleaseInHello) = (acceptsRewrittenAlertID, reportsReleaseInHello)
        }
    }

    private struct Peer {
        var registered = false
        var fullRights = false
    }

    public var configuration: Configuration
    public private(set) var port: UInt16?
    /// Every client frame, in arrival order.
    public private(set) var requests: [JSON] = []
    /// Client keys this TV issued → manifest kind.
    public private(set) var issuedKeys: [String: SSAPManifestKind] = [:]
    /// Open externalpq session (picMode).
    public private(set) var calibrationSession: String?
    /// Stored externalpq uploads: picMode → command → (dataType, bytes).
    public private(set) var uploads: [String: [String: ExternalPQData]] = [:]
    public private(set) var toasts: [String] = []
    public private(set) var input = "hdmi2"
    public private(set) var powerState = "Active"

    private let queue = DispatchSerialQueue(label: "FakeWebOSServer")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: (connection: NWConnection, state: Peer)] = [:]
    private var subscriptions: [(connection: NWConnection, id: JSON, uri: String)] = []
    private var modeStore: [String: String] = [:]
    private var pictureStore: [String: [String: JSON]] = [:]
    private var otherStore: [String: [String: JSON]] = ["network": ["wolwowlOnOff": "true"], "aiPicture": ["ai_Picture": "off"]]
    private var alerts: [Int: JSON] = [:]
    private var nextAlert = 1_786_895_965_205

    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    public func setConfiguration(_ configuration: Configuration) { self.configuration = configuration }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 << 20
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] c in self?.assumeIsolated { $0.accept(c) } }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    let p = listener.port?.rawValue ?? 0
                    self?.assumeIsolated { $0.port = p }
                    continuation.resume(returning: p)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
        subscriptions.removeAll()
    }

    /// A picture setting in the current `[input, pictureMode]` context.
    public func pictureSetting(_ key: String) -> JSON? { readPicture(key) }

    /// Drops every open client socket (simulates the TV going away).
    public func dropConnections() {
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        peers[ObjectIdentifier(connection)] = (connection, Peer())
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.assumeIsolated { $0.peers[ObjectIdentifier(connection)] = nil } }
            if case .cancelled = state { self?.assumeIsolated { $0.peers[ObjectIdentifier(connection)] = nil } }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            self?.assumeIsolated { me in
                guard error == nil, me.peers[ObjectIdentifier(connection)] != nil else { return }
                if let data, let frame = try? JSON.decode(data) { me.handle(frame, from: connection) }
                me.receive(connection)
            }
        }
    }

    private func send(_ frame: JSON, to connection: NWConnection) {
        guard let data = try? frame.encoded() else { return }
        let context = NWConnection.ContentContext(identifier: "ssap", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func reply(_ id: JSON, _ payload: [String: JSON], to connection: NWConnection) {
        send(["type": "response", "id": id, "payload": .object(payload)], to: connection)
    }

    private func fail(_ id: JSON, _ fixture: String, to connection: NWConnection) {
        var frame = FakeWebOSFixtures.frame(fixture).objectValue!
        frame["id"] = id
        send(.object(frame), to: connection)
    }

    private func fail(_ id: JSON, error: String, to connection: NWConnection) {
        send(["type": "error", "id": id, "error": .string(error), "payload": [:]], to: connection)
    }

    // MARK: - Dispatch

    private func handle(_ frame: JSON, from connection: NWConnection) {
        requests.append(frame)
        let key = ObjectIdentifier(connection)
        guard let peer = peers[key]?.state, let id = frame["id"] else { return }
        let payload = frame["payload"]?.objectValue ?? [:]
        switch frame["type"]?.stringValue {
        case "hello":
            var hello = FakeWebOSFixtures.payload("hello")
            hello["deviceOSReleaseVersion"] = .string(release)
            if !configuration.reportsReleaseInHello { hello.removeValue(forKey: "deviceOSReleaseVersion") }
            send(["type": "hello", "id": id, "payload": .object(hello)], to: connection)
        case "register":
            register(id, payload, connection)
        case "unsubscribe":
            subscriptions.removeAll { $0.connection === connection && $0.id == id }
        case let type where type == "request" || type == "subscribe":
            let uri = (frame["uri"]?.stringValue ?? "").replacingOccurrences(of: "ssap://", with: "")
            guard peer.registered || uri == "system/getSystemInfo" else {
                return fail(id, error: "401 insufficient permissions (not registered)", to: connection)
            }
            if type == "subscribe" { subscriptions.append((connection, id, uri)) }
            route(uri, id, payload, peer, connection, subscribed: type == "subscribe")
        default:
            break
        }
    }

    private var release: String {
        switch configuration.platform {
        case .webOS24: "9.2.2"
        case .webOS25: "10.3.0"
        case .webOS26: "11.1.0"
        }
    }

    private func register(_ id: JSON, _ payload: [String: JSON], _ connection: NWConnection) {
        let signed = payload["manifest"]?["signatures"] != nil
        let kind: SSAPManifestKind = signed ? .signedLegacy : .unsigned
        if signed, configuration.platform == .webOS26 { return fail(id, "registerBlacklisted", to: connection) }
        let grant = { [configuration] (me: isolated FakeWebOSServer, key: String) in
            me.issuedKeys[key] = kind
            me.peers[ObjectIdentifier(connection)]?.state = Peer(registered: true, fullRights: signed && configuration.platform != .webOS26)
            me.send(["type": "registered", "id": id, "payload": ["client-key": .string(key)]], to: connection)
        }
        if let key = payload["client-key"]?.stringValue, issuedKeys[key] == kind { return grant(self, key) }
        var prompt = FakeWebOSFixtures.frame("registerPrompt").objectValue!
        prompt["id"] = id
        send(.object(prompt), to: connection)
        switch configuration.pairing {
        case .accept(let delay):
            Task {
                try? await Task.sleep(for: delay)
                grant(self, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
            }
        case .deny(let delay):
            Task {
                try? await Task.sleep(for: delay)
                fail(id, "registerDeclined", to: connection)
            }
        case .ignore:
            break
        }
    }

    private func route(_ uri: String, _ id: JSON, _ p: [String: JSON], _ peer: Peer, _ c: NWConnection, subscribed: Bool) {
        var out: [String: JSON]
        switch uri {
        case "system/getSystemInfo":
            out = FakeWebOSFixtures.payload("getSystemInfo")
        case "com.webos.service.update/getCurrentSWInformation":
            guard peer.fullRights else { return fail(id, "insufficientPermissions", to: c) }
            out = FakeWebOSFixtures.payload("getCurrentSWInformation")
            let (product, major, minor) =
                switch configuration.platform {
                case .webOS24: ("webOSTV 9.2", "23", "23.30")
                case .webOS25: ("webOSTV 10.3", "33", "31.75")
                case .webOS26: ("webOSTV 11.1", "43", "21.71")
                }
            (out["product_name"], out["major_ver"], out["minor_ver"]) = (.string(product), .string(major), .string(minor))
        case "tv/getExternalInputList":
            out = FakeWebOSFixtures.payload("getExternalInputList")
        case "tv/switchInput":
            guard let inputID = p["inputId"]?.stringValue, inputID.hasPrefix("HDMI_") else {
                return fail(id, error: "500 Application error", to: c)
            }
            input = "hdmi" + inputID.dropFirst(5)
            out = ["returnValue": true]
        case "com.webos.applicationManager/getForegroundAppInfo":
            out = FakeWebOSFixtures.payload("getForegroundAppInfo")
            out["appId"] = .string("com.webos.app." + input)
        case "com.webos.service.tvpower/power/getPowerState":
            out = FakeWebOSFixtures.payload("getPowerState")
            out["state"] = .string(powerState)
        case "system/turnOff":
            powerState = "Power Off"
            for s in subscriptions where s.uri == "com.webos.service.tvpower/power/getPowerState" {
                reply(s.id, ["returnValue": true, "subscribed": true, "state": .string(powerState), "processing": ""], to: s.connection)
            }
            out = ["returnValue": true]
        case "system.notifications/createToast":
            toasts.append(p["message"]?.stringValue ?? "")
            out = ["returnValue": true, "toastId": .string("com.webos.service.apiadapter.pub-toast-\(toasts.count)")]
        case "com.webos.service.connectionmanager/getinfo":
            out = FakeWebOSFixtures.payload("getinfo")
        case "system.notifications/createAlert":
            guard peer.fullRights else { return fail(id, "insufficientPermissions", to: c) }
            nextAlert += 1
            alerts[nextAlert] = p["onclose"] ?? .null
            out = ["returnValue": true, "alertId": .string("com.webos.service.apiadapter.pub-\(nextAlert)")]
        case "system.notifications/closeAlert":
            let alertID = p["alertId"]?.stringValue ?? ""
            let raw = alertID.hasPrefix("com.webos.service.apiadapter.pub-")
            guard raw || (configuration.acceptsRewrittenAlertID && alertID.hasPrefix("com.webos.service.apiadapter-")),
                let n = alertID.split(separator: "-").last.flatMap({ Int($0) }), let action = alerts.removeValue(forKey: n)
            else {
                return fail(id, error: "500 Application error", to: c)
            }
            if action["uri"]?.stringValue == "luna://com.webos.settingsservice/setSystemSettings" { applyLuna(action["params"] ?? [:]) }
            out = ["returnValue": true]
        case "settings/getSystemSettings":
            let category = p["category"]?.stringValue ?? ""
            var settings: [String: JSON] = [:]
            var unknown: [JSON] = []
            for key in p["keys"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                if let v = category == "picture" ? readPicture(key) : otherStore[category]?[key] {
                    settings[key] = v
                } else {
                    unknown.append(.string(key))
                }
            }
            out = [
                "category": .string(category), "returnValue": .bool(unknown.isEmpty), "subscribed": false, "settings": .object(settings),
            ]
            if !unknown.isEmpty { out["errorKey"] = .array(unknown) }
        case "settings/setSystemSettings":
            guard peer.fullRights else { return fail(id, "setSystemSettingsNotAllowed", to: c) }
            applyLuna(.object(p))
            out = FakeWebOSFixtures.payload("setSystemSettings")
        case "externalpq/setExternalPqData", "externalpq/getExternalPqData":
            guard peer.fullRights else { return fail(id, "insufficientPermissions", to: c) }
            let isSet = uri == "externalpq/setExternalPqData"
            guard let result = isSet ? pqSet(p) : pqGet(p) else {
                return fail(id, isSet ? "externalPQDriverError" : "externalPQNoData", to: c)
            }
            out = result
        default:
            return fail(id, "unknownURI", to: c)
        }
        if subscribed { out["subscribed"] = true }
        reply(id, out, to: c)
    }

    // MARK: - Settings model

    private var signalContext: String { "\(input).\(configuration.dynamicRange)" }

    private var currentMode: String {
        modeStore[signalContext] ?? ["hdr": "hdrCinema", "dolbyHdr": "dolbyHdrCinema"][configuration.dynamicRange] ?? "expert2"
    }

    private func readPicture(_ key: String, mode: String? = nil) -> JSON? {
        if key == "pictureMode" { return .string(currentMode) }
        guard let fallback = FakeWebOSFixtures.payload("getSystemSettingsPicture")["settings"]?[key] else { return nil }
        return pictureStore["\(input).\(mode ?? currentMode)"]?[key] ?? fallback
    }

    /// Applies luna `setSystemSettings` params. `picture$<input>.<mode>.<3d>.<range>` targets that dimension;
    /// keys the picture store does not know are ignored (the luna call fails silently on a real TV).
    private func applyLuna(_ params: JSON) {
        guard let category = params["category"]?.stringValue, let settings = params["settings"]?.objectValue else { return }
        let parts = category.split(separator: "$", maxSplits: 1).map(String.init)
        guard parts[0] == "picture" else { return otherStore[parts[0], default: [:]].merge(settings) { $1 } }
        let dims = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        let targetInput = dims.first ?? input
        for (key, value) in settings {
            if key == "pictureMode" {
                let range = dims.count == 4 && dims[3] != "x" ? dims[3] : configuration.dynamicRange
                modeStore["\(targetInput).\(range)"] = value.stringValue
            } else if readPicture(key) != nil {
                let mode = dims.count >= 2 && dims[1] != "x" ? dims[1] : currentMode
                pictureStore["\(targetInput).\(mode)", default: [:]][key] = value
            }
        }
    }

    // MARK: - externalpq model

    private func pqSet(_ p: [String: JSON]) -> [String: JSON]? {
        guard let command = p["command"]?.stringValue.flatMap(ExternalPQCommand.init(rawValue:)) else { return nil }
        let picMode = p["picMode"]?.stringValue
        switch command {
        case .calStart:
            let prefix = ["hdr": "hdr_", "dolbyHdr": "dolby_"][configuration.dynamicRange]
            guard let picMode, let mode = LGPicMode(rawValue: picMode),
                prefix.map(picMode.hasPrefix) ?? (mode.signalClass == .sdr)
            else { return nil }
            calibrationSession = picMode
            pictureStore["\(input).\(currentMode)", default: [:]].merge(["colorTemperature": "50", "colorGamut": "wide"]) { $1 }
        case .calEnd:
            guard calibrationSession != nil else { return nil }
            calibrationSession = nil
        default:
            guard let session = calibrationSession, picMode == nil || picMode == session else { return nil }
            if p["dataOpt"]?.intValue == 2 {
                uploads[session]?[command.rawValue] = nil
                return ["returnValue": true]
            }
            guard let type = p["dataType"]?.stringValue.flatMap(ExternalPQDataType.init(rawValue:)), type == command.dataType,
                let bytes = p["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), let count = p["dataCount"]?.intValue,
                count > 0, bytes.count == count * type.byteWidth
            else { return nil }
            let data = ExternalPQData(command: command, dataType: type, bytes: bytes, count: count)
            let limit: Double? =
                switch command {
                case .lut1D: 32767
                case .bt709LUT3D, .bt2020LUT3D: 4095
                case .bt709Gamut, .bt2020Gamut, .hdrGamut: 1024
                default: nil
                }
            if let limit, data.values.contains(where: { !$0.isFinite || abs($0) > limit }) { return nil }
            if command == .bt709LUT3D || command == .bt2020LUT3D, count != 17 * 17 * 17 * 3 { return nil }  // B4 grid
            uploads[session, default: [:]][command.rawValue] = data
        }
        return ["returnValue": true]
    }

    /// Serves what was last uploaded for the bank of the picture mode on screen.
    private func pqGet(_ p: [String: JSON]) -> [String: JSON]? {
        let source: [String: String] = [
            "GET_1D_DPG_DATA": "1D_DPG_DATA", "GET_3D_LUT_DATA": "BT709_3D_LUT_DATA", "GET_1D_2_2_EN": "1D_2_2_EN",
            "GET_1D_0_45_EN": "1D_0_45_EN", "GET_3BY3_GAMUT_DATA": "BT709_3BY3_GAMUT_DATA",
            "GET_HDR_3BY3_GAMUT_DATA": "HDR_3BY3_GAMUT_DATA",
        ]
        guard let command = p["command"]?.stringValue.flatMap({ source[$0] }), let bank = LGPicMode(pictureMode: currentMode)?.rawValue,
            let data = uploads[bank]?[command]
        else { return nil }
        return [
            "returnValue": true, "data": .string(data.base64), "dataCount": .number(Double(data.count)),
            "dataType": .string(data.dataType.rawValue),
        ]
    }
}
