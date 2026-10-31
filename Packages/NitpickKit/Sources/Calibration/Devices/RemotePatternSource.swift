import Foundation
import Network
import PatternLink

/// The Apple TV pattern generator over PatternLink, as a `PatternSource`.
///
/// PatternLink errors surface as `CalibrationError`, like the simulated source's, so the workflow reports them alike:
/// - `connect()` to an Apple TV that cannot be reached (connection refused, no route) throws `.notConnected`; one that
///   accepts TCP but never completes the handshake throws `.timeout` after `connectTimeout`. A wrong PIN or a token the
///   TV no longer knows throws `.refused` (pair again); a protocol mismatch throws `.precondition` (update one side).
/// - `show` without an ack within `showTimeout` throws `.timeout("Pattern generator")`; the link stays usable and the
///   late ack is ignored. `setDisplayMode` returns the last state it saw at `modeTimeout`, or throws `.timeout` if none.
/// - A dropped link fails pending calls with `.notConnected` while the client reconnects on its own.
/// - Cancellation propagates as `CancellationError`.
public actor RemotePatternSource: PatternSource {
    public let client: PatternLinkClient
    private let endpoint: NWEndpoint
    private let serviceName: String
    private let credential: PatternLinkClient.Credential
    public let connectTimeout: Duration
    public let showTimeout: Duration
    /// HDMI mode switches can take many seconds on some TVs.
    public let modeTimeout: Duration
    public private(set) var capabilities: DeviceCapabilities?

    public init(
        client: PatternLinkClient, endpoint: NWEndpoint, serviceName: String, credential: PatternLinkClient.Credential,
        connectTimeout: Duration = .seconds(10), showTimeout: Duration = .seconds(5), modeTimeout: Duration = .seconds(25)
    ) {
        self.client = client
        self.endpoint = endpoint
        self.serviceName = serviceName
        self.credential = credential
        self.connectTimeout = connectTimeout
        self.showTimeout = showTimeout
        self.modeTimeout = modeTimeout
    }

    public func connect() async throws {
        capabilities = try await link {
            try await client.connect(to: endpoint, serviceName: serviceName, credential: credential, timeout: connectTimeout)
        }
    }

    public func disconnect() async {
        await client.disconnect()
        capabilities = nil
    }

    public func show(_ pattern: PatternSpec) async throws -> ShowAck {
        try await link { try await client.show(pattern, timeout: showTimeout) }
    }

    public func setDisplayMode(_ request: DisplayModeRequest) async throws -> DisplayModeState {
        let state = try await link { try await client.setDisplayMode(request, timeout: modeTimeout) }
        capabilities?.displayMode = state
        return state
    }

    public func blank() async throws { try await link { try await client.blank() } }

    private func link<T: Sendable>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as PatternLinkError {
            throw Self.engineError(error, endpoint: endpoint)
        }
    }

    static func engineError(_ error: PatternLinkError, endpoint: NWEndpoint) -> CalibrationError {
        switch error {
        case .timeout: .timeout("Pattern generator")
        case .connectionFailed: .notConnected("Pattern generator at \(endpoint)")
        case .notConnected, .disconnected: .notConnected("Pattern generator")
        case .authenticationFailed: .refused("The Apple TV rejected the PIN or pairing token; pair again with the PIN on screen")
        case .versionMismatch: .precondition("The Mac and Apple TV apps speak different PatternLink versions; update both")
        case .remote(let e): .deviceFailure("Apple TV: \(e.message)")
        }
    }
}
