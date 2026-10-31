import Foundation
import ColorScience

/// Wire protocol version. Bump on incompatible changes; the server rejects mismatches with `LinkError.code == "version"`.
public let patternLinkProtocolVersion = 1

/// Bonjour service type advertised by the Apple TV app and browsed by the Mac.
public let patternLinkServiceType = "_nitpick._tcp"

public struct Hello: Hashable, Codable, Sendable {
    public var clientName: String
    public var clientID: UUID
    public var protocolVersion: Int
    public init(clientName: String, clientID: UUID, protocolVersion: Int = patternLinkProtocolVersion) {
        self.clientName = clientName; self.clientID = clientID; self.protocolVersion = protocolVersion
    }
}

/// Requested HDMI output mode. The TV app translates it into `AVDisplayCriteria`.
public struct DisplayModeRequest: Hashable, Codable, Sendable {
    public var dynamicRange: DynamicRange
    /// Hz; nil = leave the refresh rate alone.
    public var refreshRate: Double?
    public init(dynamicRange: DynamicRange, refreshRate: Double? = nil) {
        self.dynamicRange = dynamicRange; self.refreshRate = refreshRate
    }
}

/// What the TV app knows about its output state. Nothing here proves what is on the HDMI cable; see the commissioning checklist.
public struct DisplayModeState: Hashable, Codable, Sendable {
    public var requested: DisplayModeRequest?
    /// `AVDisplayManager.isDisplayModeSwitchInProgress`
    public var switching: Bool
    /// `AVDisplayManager.isDisplayCriteriaMatchingEnabled` (user's Match Content setting). False means requests are ignored by tvOS.
    public var matchingEnabled: Bool
    /// `UIScreen.currentEDRHeadroom` / `potentialEDRHeadroom` when available (> 1 suggests HDR output is active).
    public var currentEDRHeadroom: Double?
    public var potentialEDRHeadroom: Double?
    public var note: String?

    public init(requested: DisplayModeRequest? = nil, switching: Bool = false, matchingEnabled: Bool = false,
                currentEDRHeadroom: Double? = nil, potentialEDRHeadroom: Double? = nil, note: String? = nil) {
        self.requested = requested; self.switching = switching; self.matchingEnabled = matchingEnabled
        self.currentEDRHeadroom = currentEDRHeadroom; self.potentialEDRHeadroom = potentialEDRHeadroom; self.note = note
    }
}

public struct DeviceCapabilities: Hashable, Codable, Sendable {
    public var deviceName: String
    public var model: String
    public var systemVersion: String
    public var protocolVersion: Int
    public var frameWidth: Int
    public var frameHeight: Int
    public var supportsDisplayCriteria: Bool
    public var displayMode: DisplayModeState

    public init(deviceName: String, model: String, systemVersion: String, protocolVersion: Int = patternLinkProtocolVersion,
                frameWidth: Int, frameHeight: Int, supportsDisplayCriteria: Bool, displayMode: DisplayModeState) {
        self.deviceName = deviceName; self.model = model; self.systemVersion = systemVersion; self.protocolVersion = protocolVersion
        self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.supportsDisplayCriteria = supportsDisplayCriteria
        self.displayMode = displayMode
    }
}

/// Acknowledgement that a pattern frame was handed to the display pipeline.
public struct ShowAck: Hashable, Codable, Sendable {
    public var sequence: UInt32
    /// Device clock time when the frame was enqueued for display.
    public var enqueuedAt: Date
    /// Code values actually written for the centre colour (after quantisation), when the pattern has one.
    public var centerCodes: [Int]?
    public init(sequence: UInt32, enqueuedAt: Date, centerCodes: [Int]?) {
        self.sequence = sequence; self.enqueuedAt = enqueuedAt; self.centerCodes = centerCodes
    }
}

public struct PairRequest: Hashable, Codable, Sendable {
    public var clientName: String
    public var clientID: UUID
    public init(clientName: String, clientID: UUID) { self.clientName = clientName; self.clientID = clientID }
}

/// Long-term credential issued by the TV after a PIN-authenticated session; stored in the Mac Keychain.
public struct PairResponse: Hashable, Codable, Sendable {
    public var token: Data
    public var deviceID: UUID
    public init(token: Data, deviceID: UUID) { self.token = token; self.deviceID = deviceID }
}

public struct LinkError: Error, Hashable, Codable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Mac → Apple TV.
public enum ClientMessage: Hashable, Codable, Sendable {
    case hello(Hello)
    case pair(PairRequest)
    case show(sequence: UInt32, pattern: PatternSpec)
    case setDisplayMode(DisplayModeRequest)
    case blank
    case queryStatus
    case ping
}

/// Apple TV → Mac.
public enum ServerMessage: Hashable, Codable, Sendable {
    case welcome(DeviceCapabilities)
    case paired(PairResponse)
    case shown(ShowAck)
    case displayMode(DisplayModeState)
    case error(LinkError)
    case pong
}
