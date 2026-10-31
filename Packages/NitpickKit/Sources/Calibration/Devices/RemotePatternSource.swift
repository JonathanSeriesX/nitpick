import Foundation
import Network
import PatternLink

/// The Apple TV pattern generator over PatternLink, as a `PatternSource`.
public actor RemotePatternSource: PatternSource {
    public let client: PatternLinkClient
    private let endpoint: NWEndpoint
    private let serviceName: String
    private let credential: PatternLinkClient.Credential
    public var showTimeout: Duration = .seconds(5)
    /// HDMI mode switches can take many seconds on some TVs.
    public var modeTimeout: Duration = .seconds(25)
    public private(set) var capabilities: DeviceCapabilities?

    public init(client: PatternLinkClient, endpoint: NWEndpoint, serviceName: String, credential: PatternLinkClient.Credential) {
        self.client = client; self.endpoint = endpoint; self.serviceName = serviceName; self.credential = credential
    }

    public func connect() async throws {
        capabilities = try await client.connect(to: endpoint, serviceName: serviceName, credential: credential)
    }

    public func disconnect() async {
        await client.disconnect()
        capabilities = nil
    }

    public func show(_ pattern: PatternSpec) async throws -> ShowAck { try await client.show(pattern, timeout: showTimeout) }

    public func setDisplayMode(_ request: DisplayModeRequest) async throws -> DisplayModeState {
        let state = try await client.setDisplayMode(request, timeout: modeTimeout)
        capabilities?.displayMode = state
        return state
    }

    public func blank() async throws { try await client.blank() }
}
