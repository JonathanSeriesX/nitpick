import Foundation
import Network
import Synchronization

@testable import LGControl

/// A fake TV on a free loopback port plus a client configured for it (plain ws, short timeouts, no settle delays).
func makeTV(
    _ configuration: FakeWebOSServer.Configuration = .init(), store: InMemoryTVCredentialStore = .init(),
    promptTimeout: Duration = .seconds(3)
) async throws -> (FakeWebOSServer, LGTV) {
    let fake = FakeWebOSServer(configuration: configuration)
    let port = try await fake.start()
    let tv = LGTV(
        credentials: store,
        options: .init(
            connection: .init(port: port, allowInsecure: true, connectTimeout: .seconds(2), requestTimeout: .seconds(2)),
            promptTimeout: promptTimeout, readbackDelay: .zero, calibrationSettleDelay: .zero))
    return (fake, tv)
}

func sha256(_ data: Data) -> String { CertificatePinning.fingerprint(der: data) }

/// Frames the fake received with this `uri` (without `ssap://`).
func requests(_ fake: FakeWebOSServer, uri: String) async -> [JSON] {
    await fake.requests.filter { $0["uri"]?.stringValue == "ssap://" + uri }
}

func lgError(_ body: () async throws -> Void) async -> LGError? {
    do { try await body() } catch let e as LGError { return e } catch { return nil }
    return nil
}

/// Accepts TCP connections and never answers (the WebSocket upgrade never completes).
final class SilentListener: Sendable {
    private let listener: NWListener
    private let held = Mutex<[NWConnection]>([])
    private let queue = DispatchQueue(label: "SilentListener")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] c in
            c.start(queue: queue)
            held.withLock { $0.append(c) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                }
                if case .failed(let e) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: e)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        held.withLock { $0.forEach { $0.cancel() } }
    }
}
