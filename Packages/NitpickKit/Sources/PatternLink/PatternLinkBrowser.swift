import Foundation
import Network

/// Finds Apple TVs running the pattern generator (`_nitpick._tcp`), including over peer-to-peer Wi-Fi.
///
/// The host app needs `NSLocalNetworkUsageDescription` and `_nitpick._tcp` in `NSBonjourServices`.
public actor PatternLinkBrowser {
  public struct DiscoveredDevice: Hashable, Sendable, Identifiable {
    /// Bonjour service name. Pass it as `serviceName` to `PatternLinkClient.connect` (it salts the PIN key).
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    /// The TV's pairing id from the TXT record (`id`); look up a stored token with it before asking for a PIN.
    public let deviceID: UUID?
  }

  /// The current device list after every change; empty after `stop()`. Single consumer, newest value kept.
  public nonisolated let devices: AsyncStream<[DiscoveredDevice]>
  private let sink: AsyncStream<[DiscoveredDevice]>.Continuation
  private let queue = DispatchSerialQueue(label: "PatternLinkBrowser")
  private var browser: NWBrowser?

  public init() {
    (devices, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  deinit {
    browser?.cancel()
    sink.finish()
  }

  public func start() {
    guard browser == nil else { return }
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(type: patternLinkServiceType, domain: nil), using: parameters)
    let sink = sink
    browser.browseResultsChangedHandler = { results, _ in
      var devices: [String: DiscoveredDevice] = [:]
      for result in results {
        guard case .service(let name, _, _, _) = result.endpoint, devices[name] == nil else {
          continue
        }
        var deviceID: UUID?
        if case .bonjour(let txt) = result.metadata {
          deviceID = txt["id"].flatMap(UUID.init(uuidString:))
        }
        devices[name] = DiscoveredDevice(
          id: name, name: name, endpoint: result.endpoint, deviceID: deviceID)
      }
      sink.yield(
        devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  public func stop() {
    browser?.cancel()
    browser = nil
    sink.yield([])
  }

  /// An endpoint for a manually entered host and port.
  public static func endpoint(host: String, port: UInt16) -> NWEndpoint {
    .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
  }
}
