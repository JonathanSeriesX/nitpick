import PatternLink
import SwiftUI

/// Pattern generator card: Bonjour discovery and PIN pairing of the Apple TV, or the simulated Apple TV; display mode,
/// a manual test pattern and link diagnostics.
struct PatternCard: View {
    @Bindable var device: PatternDevice
    let localNetworkDenied: Bool

    var body: some View {
        Card(
            title: "Pattern generator", symbol: "appletv",
            subtitle: device.kind == .simulated ? "Simulated Apple TV" : "Nitpick on Apple TV"
        ) {
            StatusBadge(text: device.phase.title, color: device.phase.color)
        } content: {
            KindPicker(
                title: "Pattern source", kinds: DeviceKind.allCases, label: { $0 == .real ? "Apple TV" : "Simulated" },
                selection: device.kind
            ) { await device.setKind($0) }
            if let error = device.error { ErrorBanner(error: error) { device.error = nil } }
            if let target = device.pinTarget {
                PinEntry(device: device, name: target.name)
            } else if device.phase == .connected || device.phase.isReconnecting, let caps = device.capabilities {
                connected(caps)
            } else if device.kind == .real {
                discovery
            }
            if device.kind == .real { PatternDiagnostics(device: device) }
        }
    }

    @ViewBuilder private func connected(_ caps: DeviceCapabilities) -> some View {
        InfoRows(rows: [
            ("Device", device.connectedName ?? caps.deviceName),
            ("Model", "\(caps.model) · \(caps.systemVersion)"),
            ("Frame", "\(caps.frameWidth) × \(caps.frameHeight)"),
        ])
        DisplayModeSection(device: device, state: caps.displayMode)
        Divider()
        TestPatternSection(device: device)
        HStack {
            Spacer()
            Button("Disconnect") { Task { await device.disconnect() } }
        }
    }

    @ViewBuilder private var discovery: some View {
        Text("On this network").font(.subheadline.weight(.semibold))
        if device.discovered.isEmpty {
            Text("No Apple TV found. Open Nitpick on the Apple TV, or enter its address below.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(device.discovered) { tv in
            let paired = device.hasToken(tv)
            DiscoveryRow(title: tv.name, tag: paired ? "Paired" : nil, actionTitle: paired ? "Connect" : "Pair…") {
                Task { await device.select(tv) }
            }
            .disabled(device.phase == .connecting)
        }
        DisclosureGroup("Enter address manually") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Host", text: $device.manualHost, prompt: Text("192.168.1.30")).accessibilityLabel("Apple TV host")
                    TextField("Port", text: $device.manualPort, prompt: Text("Port")).frame(width: 70).accessibilityLabel("Apple TV port")
                }
                TextField("Name", text: $device.manualName, prompt: Text("Name shown on the Apple TV"))
                    .accessibilityLabel("Apple TV name")
                    .onSubmit { Task { await device.selectManual() } }
                Button("Connect") { Task { await device.selectManual() } }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 4)
        }
    }
}

extension DevicePhase {
    var isReconnecting: Bool { if case .reconnecting = self { true } else { false } }
}

private struct PinEntry: View {
    @Bindable var device: PatternDevice
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the code shown on “\(name)”").font(.callout.weight(.semibold))
            PinField(pin: $device.pin) { Task { await device.submitPIN() } }
            HStack {
                Button("Connect") { Task { await device.submitPIN() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(device.pin.count != 6 || device.phase == .connecting)
                Button("Cancel") { device.cancelPIN() }
                    .keyboardShortcut(.cancelAction)
                if device.phase == .connecting { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
        .background(.background, in: .rect(cornerRadius: 10))
    }
}

private struct DisplayModeSection: View {
    let device: PatternDevice
    let state: DisplayModeState

    var body: some View {
        HStack {
            Text("Display mode").font(.subheadline.weight(.semibold))
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await device.refreshDisplayMode() } }
                .labelStyle(.iconOnly)
                .help("Ask the Apple TV for its current output mode")
        }
        InfoRows(rows: [
            ("Requested", state.requested.map { $0.dynamicRange.displayName } ?? "Nothing yet"),
            ("Match Content", state.matchingEnabled ? "On" : "Off"),
            ("Switching", state.switching ? "In progress" : "No"),
            ("EDR headroom", state.currentEDRHeadroom.map { Fmt.num($0, 1) } ?? "–"),
        ])
        if !state.matchingEnabled {
            Text("Enable Match Dynamic Range on the Apple TV: Settings ▸ Video and Audio ▸ Match Content")
                .font(.callout).foregroundStyle(.orange)
        }
        if let note = state.note { Text(note).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct TestPatternSection: View {
    @Bindable var device: PatternDevice
    private static let windows: [(String, Double)] = [("2 %", 0.02), ("5 %", 0.05), ("10 %", 0.10), ("25 %", 0.25), ("Full", 1.0)]

    var body: some View {
        Text("Send test pattern").font(.subheadline.weight(.semibold))
        HStack {
            Text("Grey").foregroundStyle(.secondary)
            Slider(value: $device.testLevel, in: 0...100, step: 1).accessibilityLabel("Grey level")
            Text("\(Int(device.testLevel)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        HStack {
            Picker("Window", selection: $device.testWindow) {
                ForEach(Self.windows.indices, id: \.self) { Text(Self.windows[$0].0).tag(Self.windows[$0].1) }
            }
            .fixedSize()
            Spacer()
            Picker("Format", selection: $device.testHDR) {
                Text("SDR").tag(false)
                Text("HDR10").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .accessibilityLabel("Signal format")
        }
        HStack {
            Spacer()
            Button("Show Pattern") { Task { await device.showTestPattern() } }
            Button("Blank") { Task { await device.blank() } }
        }
    }
}

private struct PatternDiagnostics: View {
    let device: PatternDevice

    var body: some View {
        DisclosureGroup("Diagnostics") {
            let d = device.diagnostics
            VStack(alignment: .leading, spacing: 8) {
                InfoRows(rows: [
                    ("Endpoint", d.endpoint ?? "–"),
                    ("Connected since", d.connectedSince.map { $0.formatted(date: .omitted, time: .standard) } ?? "–"),
                    ("Round trip", d.lastRoundTrip.map { $0.formatted(.units(allowed: [.milliseconds], width: .abbreviated)) } ?? "–"),
                    ("Cipher", d.cipherSuite.map { $0 == 0xCCAC ? "ECDHE-PSK-CHACHA20-POLY1305" : String(format: "0x%04X", $0) } ?? "–"),
                    ("Acks", "\(d.acksReceived)"),
                    (
                        "Traffic",
                        "\(d.bytesOut.formatted(.byteCount(style: .binary))) out · \(d.bytesIn.formatted(.byteCount(style: .binary))) in"
                    ),
                    ("Reconnect attempts", "\(device.reconnectAttempts)"),
                    ("Last error", d.lastError ?? device.error?.message ?? "None"),
                ])
                HistoryList(entries: device.history)
                Button("Ping") { Task { await device.ping() } }
                    .controlSize(.small)
                    .disabled(device.phase != .connected)
            }
            .padding(.top, 4)
        }
    }
}
