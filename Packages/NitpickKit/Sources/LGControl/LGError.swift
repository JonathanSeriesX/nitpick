import Foundation

/// Errors from the LG client. `server` carries the TV's own error text (`"401 insufficient permissions"`).
public enum LGError: Error, Sendable, Equatable {
    case notConnected
    case connectionFailed(String)
    /// A request, the connection or the pairing prompt did not finish in time. The string names what timed out.
    case timeout(String)
    /// The TV's TLS leaf certificate differs from the one pinned at first pairing (SHA-256, lowercase hex).
    case certificateChanged(pinned: String, presented: String)
    /// The user pressed Decline on the TV (`403 cancelled`).
    case pairingDenied
    /// Registration failed for another reason (for example `403 Pairing rejected: blacklisted certificate detected`).
    case pairingRejected(String)
    /// `type:"error"` frame or `returnValue:false`. `code` is the leading number of the error string when present.
    case server(code: Int?, message: String, payload: JSON)
    /// The externalpq calibration API cannot be used with this TV/firmware/manifest.
    case calibrationUnavailable(reason: String)
    /// A settings value outside the documented range or enum.
    case outOfRange(key: String, value: String, allowed: String)
    /// A calibration payload refused by `PayloadValidator` (wrong count, range, NaN, non-monotonic, wrong session).
    case invalidPayload(String)
    case unsupported(String)
    /// The TV answered with something this client cannot parse.
    case malformedResponse(String)

    /// `server` error code, e.g. 401, 403, 404, 500.
    public var serverCode: Int? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }

    static func fromErrorFrame(_ frame: JSON) -> LGError {
        let message = frame["error"]?.stringValue ?? frame["payload"]?["errorText"]?.stringValue ?? "unknown error"
        return .server(code: Int(message.prefix { $0.isNumber }), message: message, payload: frame["payload"] ?? .null)
    }
}
