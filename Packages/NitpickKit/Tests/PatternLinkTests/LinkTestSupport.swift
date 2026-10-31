import ColorScience
import Foundation
import Network

@testable import PatternLink

struct TestTimeout: Error {}

/// Polls `probe` until it returns a value or `timeout` passes.
func eventually<T>(timeout: Duration = .seconds(3), _ probe: () async -> T?) async throws -> T {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if let value = await probe() { return value }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw TestTimeout()
}

func testCapabilities() -> DeviceCapabilities {
  DeviceCapabilities(
    deviceName: "Test TV", model: "AppleTV14,1", systemVersion: "18.0", frameWidth: 3840,
    frameHeight: 2160,
    supportsDisplayCriteria: true, displayMode: DisplayModeState(matchingEnabled: true))
}

/// Plays the tvOS app: reads server events, answers forwarded requests, and keeps a log.
actor FakeTVApp {
  let server: PatternLinkServer
  var answerShows = true
  /// When the display-mode switch finishes; nil = never.
  var switchDuration: Duration? = .milliseconds(200)
  private(set) var log: [PatternLinkServer.ServerEvent] = []

  init(server: PatternLinkServer) { self.server = server }

  func run() {
    Task { for await event in server.events { await handle(event) } }
  }

  func configure(answerShows: Bool = true, switchDuration: Duration? = .milliseconds(200)) {
    self.answerShows = answerShows
    self.switchDuration = switchDuration
  }

  private func handle(_ event: PatternLinkServer.ServerEvent) async {
    log.append(event)
    guard case .message(let id, let message) = event else { return }
    switch message {
    case .show(let sequence, _) where answerShows:
      await server.send(
        .shown(ShowAck(sequence: sequence, enqueuedAt: Date(), centerCodes: [940, 940, 940])),
        to: id)
    case .setDisplayMode(let request):
      await server.send(
        .displayMode(DisplayModeState(requested: request, switching: true, matchingEnabled: true)),
        to: id)
      if let switchDuration {
        let server = server
        Task {
          try? await Task.sleep(for: switchDuration)
          await server.send(
            .displayMode(
              DisplayModeState(requested: request, switching: false, matchingEnabled: true)), to: id
          )
        }
      }
    default:
      break
    }
  }

  func identities() -> [String] {
    log.compactMap { if case .clientConnected(_, let identity) = $0 { identity } else { nil } }
  }

  func pairedClients() -> [UUID] {
    log.compactMap { if case .paired(_, let id) = $0 { id } else { nil } }
  }
}

/// A started server on 127.0.0.1 (not advertised) with a fake app attached.
func startServer(store: PairingStore = InMemoryPairingStore()) async throws -> (
  PatternLinkServer, FakeTVApp, NWEndpoint
) {
  let server = PatternLinkServer(
    deviceName: "Test TV", capabilitiesProvider: { testCapabilities() }, pairingStore: store)
  let app = FakeTVApp(server: server)
  await app.run()
  try await server.start(port: .any, advertise: false)
  let port = try await eventually { await server.port }
  return (server, app, PatternLinkBrowser.endpoint(host: "127.0.0.1", port: port))
}

func makeClient(_ store: ClientCredentialStore = InMemoryCredentialStore()) -> PatternLinkClient {
  PatternLinkClient(clientName: "Test Mac", clientID: UUID(), credentialStore: store)
}

// MARK: - Raw connection helpers

func sendRaw(_ connection: NWConnection, _ data: Data) async throws {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    connection.send(
      content: data,
      completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
  }
}

func receiveRaw(_ connection: NWConnection, count: Int) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    connection.receive(minimumIncompleteLength: count, maximumLength: count) {
      content, _, _, error in
      if let content, error == nil {
        continuation.resume(returning: content)
      } else {
        continuation.resume(throwing: error ?? TestTimeout())
      }
    }
  }
}

func receiveFrame(_ connection: NWConnection) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    connection.receiveMessage { content, _, _, error in
      if let content, error == nil {
        continuation.resume(returning: content)
      } else {
        continuation.resume(throwing: error ?? TestTimeout())
      }
    }
  }
}

func lengthPrefix(_ count: Int) -> Data {
  withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
}
