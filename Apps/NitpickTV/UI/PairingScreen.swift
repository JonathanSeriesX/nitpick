import SwiftUI

/// Shown while no Mac is connected: the PIN to type on the Mac, where the TV listens, and the way into the
/// built-in patterns. Sized for reading from about 3 m.
struct PairingScreen: View {
    let link: LinkCoordinator
    let openPatterns: () -> Void

    var body: some View {
        VStack(spacing: 56) {
            VStack(spacing: 8) {
                Text("Nitpick").font(.largeTitle.weight(.bold))
                Text(link.deviceName).font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text("Pairing code").font(.headline).foregroundStyle(.secondary)
                Text(pinText)
                    .font(.system(size: 150, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Pairing code \(link.pin.map(String.init).joined(separator: " "))")
            }
            VStack(spacing: 12) {
                Text("Waiting for Nitpick on your Mac…").font(.title3)
                Text("“\(link.serviceName)” · \(endpoint)")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(link.status).font(.callout).foregroundStyle(.secondary)
            }
            Button("Patterns", systemImage: "square.grid.3x3", action: openPatterns)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06).ignoresSafeArea())
    }

    private var pinText: String {
        link.pin.count == 6 ? "\(link.pin.prefix(3)) \(link.pin.suffix(3))" : "––– –––"
    }

    private var endpoint: String {
        "\(link.address ?? "no IPv4 address"):\(link.port.map(String.init) ?? "–")"
    }
}
