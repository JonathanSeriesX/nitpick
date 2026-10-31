import SwiftUI

/// Where a device card gets its device from.
nonisolated enum DeviceKind: String, CaseIterable, Identifiable {
    case real, simulated
    var id: String { rawValue }
}

nonisolated enum MeterKind: String, CaseIterable, Identifiable {
    /// i1d3-family colorimeter on USB.
    case usb
    /// The real i1d3 driver on a virtual USB device fed by the simulated panel.
    case virtual
    /// `SimulatedMeter` reading the simulated panel.
    case simulated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .usb: "USB meter"
        case .virtual: "Virtual i1d3"
        case .simulated: "Simulated"
        }
    }
}

/// Connection phase shared by the three device cards.
enum DevicePhase: Equatable {
    case idle
    case connecting
    /// LG: the TV shows its Accept prompt. Apple TV: waiting for the PIN.
    case waitingForUser
    case connected
    case reconnecting(Int)
    case failed

    var title: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .waitingForUser: "Waiting for you"
        case .connected: "Connected"
        case .reconnecting(let n): "Reconnecting (\(n))…"
        case .failed: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .connecting, .reconnecting: .blue
        case .waitingForUser: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

/// A timestamped line for a device's diagnostics.
struct StateEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}
