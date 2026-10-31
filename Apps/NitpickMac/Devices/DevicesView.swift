import SwiftUI

/// The Devices screen: demo mode, then one card per device.
struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hub = model.devices
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(hub)
                if hub.network.denied {
                    Banner(
                        style: .warning, title: "Local network access is off",
                        message: "Nitpick cannot find or reach the Apple TV and the LG TV.", nextStep: ErrorText.localNetworkHint
                    ) { OpenLocalNetworkSettingsButton() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    TVCard(device: hub.tv, localNetworkDenied: hub.network.denied)
                    MeterCard(device: hub.meter)
                    PatternCard(device: hub.pattern, localNetworkDenied: hub.network.denied)
                }
            }
            .padding(24)
        }
        .navigationTitle("Devices")
        // The local network prompt and its denied state only matter once a real TV or Apple TV is in use.
        .onChange(of: hub.tv.kind == .real || hub.pattern.kind == .real, initial: true) { _, real in
            if real { hub.network.start() }
        }
    }

    private func header(_ hub: DeviceHub) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Devices").font(.largeTitle.weight(.semibold))
                Text(hub.allConnected ? "All three devices are ready." : "Connect a TV, a meter and a pattern generator, or use demo mode.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: Binding(get: { hub.demoMode }, set: { on in Task { await hub.setDemoMode(on) } })) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Demo mode").font(.headline)
                    Text("Simulated TV, meter and Apple TV on one virtual panel").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .help("Replace all three devices with simulated ones that share one virtual OLED panel")
        }
    }
}

/// The Real/Simulated picker at the top of a device card.
struct KindPicker<Kind: Hashable & Identifiable & Sendable>: View {
    let title: String
    let kinds: [Kind]
    let label: (Kind) -> String
    let selection: Kind
    let select: @MainActor (Kind) async -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: { kind in Task { await select(kind) } })) {
            ForEach(kinds) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(title)
    }
}

/// A selectable row of a discovery list.
struct DiscoveryRow: View {
    let title: String
    var detail: String?
    var tag: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).lineLimit(1)
                    if let tag {
                        Text(tag).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: .capsule)
                    }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action).controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// Timestamped state lines for a diagnostics disclosure.
struct HistoryList: View {
    let entries: [StateEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries.suffix(12).reversed()) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit()
                    Text(entry.text).lineLimit(2)
                }
            }
            if entries.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .textSelection(.enabled)
    }
}
