import Foundation

/// Errors thrown by `PatternLinkClient`.
public enum PatternLinkError: Error, Hashable, Sendable {
  /// No answer within the call's timeout.
  case timeout
  /// The TLS-PSK handshake failed: wrong PIN, or a token the Apple TV no longer knows. Pair again with the PIN.
  case authenticationFailed
  /// The Apple TV app speaks a different `patternLinkProtocolVersion`. Update one side.
  case versionMismatch
  /// The connection dropped (or `disconnect()` was called) while the call was pending.
  case disconnected
  /// The Apple TV answered with an error.
  case remote(LinkError)
  /// The call needs an established session.
  case notConnected
  /// The Apple TV could not be reached (connection refused, no route, …).
  case connectionFailed(String)
}
