import Foundation

/// Calibration workflows, simulated devices and sessions.
public enum Calibration {}

/// Errors raised by the calibration engine and the simulated devices.
public enum CalibrationError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A setting value outside the range the device (or `ControlBounds`) accepts.
    case outOfRange(key: String, value: String)
    case unsupportedSetting(String)
    case notConnected(String)
    /// A device call did not finish within its deadline.
    case timeout(String)
    case deviceFailure(String)
    /// The device is in the wrong state for the request (wrong signal path, CAL_START missing, …).
    case invalidState(String)
    /// The device refused a calibration upload (e.g. Game Optimizer).
    case refused(String)
    /// A precondition of the workflow is not met (missing source session, missing capability, …).
    case precondition(String)

    public var description: String {
        switch self {
        case .outOfRange(let key, let value): "\(key) = \(value) is out of range"
        case .unsupportedSetting(let key): "Unsupported setting \(key)"
        case .notConnected(let device): "\(device) is not connected"
        case .timeout(let what): "\(what) did not respond in time"
        case .deviceFailure(let message): message
        case .invalidState(let message): message
        case .refused(let message): message
        case .precondition(let message): message
        }
    }
}

/// Runs `operation` with a wall-clock deadline and throws `CalibrationError.timeout(what)` when it expires.
///
/// The deadline is real time on purpose: it guards device I/O that may never return, which a virtual clock cannot
/// detect. Cancelling the caller cancels `operation`.
public func withTimeout<T: Sendable>(_ timeout: Duration, _ what: String,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CalibrationError.timeout(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

extension Duration {
    /// The duration in seconds.
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}

extension Double {
    func clamped(_ lower: Double, _ upper: Double) -> Double { Swift.min(Swift.max(self, lower), upper) }
}
