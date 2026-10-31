import CryptoKit
import Foundation
import Network
import Security

/// TLS 1.2 pre-shared-key transport security, after Apple's TicTacToe Network.framework sample.
///
/// Behaviour measured on loopback (macOS 27, Network.framework):
/// - PSK only negotiates with TLS 1.2. Pinning TLS 1.3 fails the handshake (`-9858`), with any ciphersuite.
/// - `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` works and is offered first: the ephemeral ECDH share means a
///   passively captured handshake cannot be brute-forced offline for the 6-digit PIN, and sessions get forward secrecy.
///   `TLS_PSK_WITH_AES_128_GCM_SHA256` is appended as the fallback the design asks for.
/// - On the server, `sec_protocol_options_set_pre_shared_key_selection_block` *does* fire, with the client's PSK
///   identity in the "hint" argument, and the identity it completes with is looked up among the keys added with
///   `sec_protocol_options_add_pre_shared_key`. The block alone cannot supply key material (no added keys = handshake
///   failure). So the server adds every known key up front and uses the block to map `pin:<uuid>` to its single PIN key
///   and to learn which identity each connection used. Keys are copied when the listener starts; the server rebuilds
///   its listener when they change (live connections survive that).
/// - Wrong key: the client sees `NWError.tls(-9820)` ("bad MAC"); unknown identity: `NWError.tls(-9864)`.
public enum LinkSecurity {
  /// Server-side identity that every `pin:<clientUUID>` client identity maps to.
  static let pinKeyIdentity = "pin"

  /// PSK identity for a first-contact session authenticated with the TV's on-screen PIN.
  public static func pinIdentity(_ clientID: UUID) -> String { "pin:\(clientID.uuidString)" }
  /// PSK identity for a reconnect authenticated with the token issued at pairing.
  public static func tokenIdentity(_ clientID: UUID) -> String { "tok:\(clientID.uuidString)" }

  /// The PIN-session key: HKDF-SHA256 of the PIN, salted with the Bonjour service name, info `nitpick-pin`.
  public static func pinKey(pin: String, serviceName: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(pin.utf8)), salt: Data(serviceName.utf8),
      info: Data("nitpick-pin".utf8), outputByteCount: 32)
  }

  /// Client parameters: TLS 1.2 PSK with `identity`, peer-to-peer allowed, link framer on top.
  public static func parameters(psk: Data, identity: String) -> NWParameters {
    tlsParameters {
      sec_protocol_options_add_pre_shared_key(
        $0, dispatchData(psk), dispatchData(Data(identity.utf8)))
    }
  }

  /// Server parameters.
  /// - Parameters:
  ///   - keys: PSK identity → key. Use `"pin"` for the current PIN key; any client identity `pin:<x>` maps to it.
  ///   - queue: queue the identity callback runs on.
  ///   - onClientIdentity: receives each handshake's client identity and its TLS metadata object, which is the same
  ///     object the accepted connection later reports, so the caller can tie the identity to the connection.
  public static func serverParameters(
    keys: [String: Data], queue: DispatchQueue,
    onClientIdentity: @escaping @Sendable (String, sec_protocol_metadata_t) -> Void
  ) -> NWParameters {
    let parameters = tlsParameters { options in
      for (identity, key) in keys {
        sec_protocol_options_add_pre_shared_key(
          options, dispatchData(key), dispatchData(Data(identity.utf8)))
      }
      sec_protocol_options_set_pre_shared_key_selection_block(
        options,
        { metadata, hint, complete in
          guard let hint else { return complete(nil) }
          let identity = String(decoding: Data(hint as DispatchData), as: UTF8.self)
          onClientIdentity(identity, metadata)
          complete(identity.hasPrefix("pin:") ? dispatchData(Data(pinKeyIdentity.utf8)) : hint)
        }, queue)
    }
    parameters.allowLocalEndpointReuse = true
    return parameters
  }

  private static func tlsParameters(_ configure: (sec_protocol_options_t) -> Void) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    configure(options)
    for suite in [
      UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256), UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256),
    ] {
      sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: suite)!)
    }
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    let parameters = NWParameters(tls: tls)
    parameters.includePeerToPeer = true
    return parameters.addingLinkFramer()
  }

  private static func dispatchData(_ data: Data) -> __DispatchData {
    data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
  }
}
