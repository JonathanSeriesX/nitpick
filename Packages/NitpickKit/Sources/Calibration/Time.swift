import Foundation
import Synchronization

/// Source of time for the engine. Every wait (settling, integration, mode switches) goes through it so that a
/// `VirtualClock` can run whole sessions deterministically without real waiting.
public protocol Sleeper: Sendable {
    /// Waits `duration`; throws `CancellationError` when the task is cancelled.
    func sleep(for duration: Duration) async throws
    var now: Date { get }
}

/// Real time: `Task.sleep` on the continuous clock and the wall-clock `Date()`.
public struct RealSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    public var now: Date { Date() }
}

/// Deterministic virtual time: `sleep` advances `now` instantly. Shared by the simulated devices, so settling,
/// ABL and meter integration dynamics are evaluated against the same timeline without real waiting.
public final class VirtualClock: Sleeper {
    private let current: Mutex<Date>

    /// Starts at a fixed date so runs are reproducible.
    public init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) { current = Mutex(start) }

    public var now: Date { current.withLock { $0 } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        advance(by: duration)
        await Task.yield()
        try Task.checkCancellation()
    }

    public func advance(by duration: Duration) {
        current.withLock { $0 = $0.addingTimeInterval(duration.timeInterval) }
    }
}

/// SplitMix64: a tiny, fast, deterministic generator for simulated noise and verification patches.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }

    /// Standard normal deviate (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = Swift.max(uniform(), .leastNonzeroMagnitude)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * uniform())
    }
}
