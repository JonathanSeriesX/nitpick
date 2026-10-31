import AppKit
import Calibration
import SwiftUI

/// TV card: LG discovery and pairing, or the simulated TV; capabilities, picture settings and a settings snapshot.
struct TVCard: View {
    @Bindable var device: TVDevice
    let localNetworkDenied: Bool
    @State private var showSettings = true

    var body: some View {
        Card(title: "TV", symbol: "tv", subtitle: device.kind == .simulated ? "Simulated LG TV (OLED panel model)" : "LG webOS TV") {
            StatusBadge(text: device.phase.title, color: device.phase.color)
        } content: {
            KindPicker(
                title: "TV source", kinds: DeviceKind.allCases, label: { $0 == .real ? "LG webOS" : "Simulated" },
                selection: device.kind
            ) { await device.setKind($0) }
            if device.phase == .waitingForUser {
                Banner(
                    style: .prompt, title: "Accept the pairing prompt on your TV",
                    message: "Choose Accept with the TV remote. Nitpick waits up to 60 seconds.")
            }
            if let error = device.error { ErrorBanner(error: error) { device.error = nil } }
            if device.phase == .connected, let caps = device.capabilities {
                connected(caps)
            } else if device.kind == .real {
                discovery
            }
            diagnostics
        }
    }

    @ViewBuilder private func connected(_ caps: TVCapabilities) -> some View {
        if let release = device.release, release.blocksThirdPartyCalibration {
            Banner(
                style: .warning, title: "webOS \(release.marketingVersion): calibration API unavailable",
                message:
                    "This webOS release blocks third-party calibration, so 1D/3D LUT, tone-map and Dolby Vision uploads are not possible.",
                nextStep: "Settings-only workflows (OLED light, contrast, 2- and 20-point white balance) are still offered.")
        }
        InfoRows(rows: [
            ("Model", caps.modelName),
            ("Firmware", caps.firmwareVersion.isEmpty ? "–" : caps.firmwareVersion),
            ("webOS", device.release?.description ?? caps.webOSVersion ?? "–"),
            ("Calibration API", caps.supportsCalibrationAPI ? "Available (\(caps.lut3DSize)³ 3D LUT)" : "Unavailable"),
            ("Inputs", caps.inputs.map { $0.label + ($0.isConnected ? " (in use)" : "") }.joined(separator: ", ")),
            ("Picture mode", device.settings.map { PictureModes.name($0.pictureMode) } ?? "–"),
        ])
        if let settings = device.settings {
            DisclosureGroup("Picture settings (\(settings.values.count))", isExpanded: $showSettings) {
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(settings.values.keys.sorted(), id: \.self) { key in
                            GridRow {
                                Text(key).foregroundStyle(.secondary).lineLimit(1)
                                Text(Fmt.json(settings.values[key]!)).monospacedDigit()
                            }
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
            }
        }
        Button(RestorePoint.label, systemImage: "camera") { Task { await device.takeSnapshot() } }
            .fixedSize()
            .help("Saves the current picture settings as JSON. The TV's LUTs cannot be read back, so this is not a backup.")
        HStack {
            Button("Refresh Settings", systemImage: "arrow.clockwise") { Task { await device.refreshSettings() } }
                .help("Read the picture settings again")
            Spacer()
            Button("Disconnect") { Task { await device.disconnect() } }
        }
        if let note = device.snapshotNote {
            HStack {
                Label(note, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                if let url = device.snapshotURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var discovery: some View {
        HStack {
            Text("On this network").font(.subheadline.weight(.semibold))
            if device.isSearching { ProgressView().controlSize(.small) }
            Spacer()
            Button("Search Again", systemImage: "arrow.clockwise") { Task { await device.discover() } }
                .labelStyle(.iconOnly)
                .disabled(device.isSearching)
                .help("Search the network for LG TVs again")
        }
        if device.discovered.isEmpty {
            Text(device.isSearching ? "Searching…" : "No LG TVs found. Turn the TV on, or enter its IP address below.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(device.discovered) { tv in
            DiscoveryRow(
                title: tv.name, detail: [tv.model, tv.host].filter { !$0.isEmpty }.joined(separator: " · "), actionTitle: "Connect"
            ) {
                Task { await device.connect(host: tv.host, id: tv.id) }
            }
            .disabled(device.phase == .connecting || device.phase == .waitingForUser)
        }
        HStack {
            TextField("IP address", text: $device.manualHost, prompt: Text("192.168.1.20"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await device.connect(host: device.manualHost, id: nil) } }
                .accessibilityLabel("TV IP address")
            Button("Connect") { Task { await device.connect(host: device.manualHost, id: nil) } }
                .disabled(device.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var diagnostics: some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                InfoRows(rows: [
                    ("Host", device.host ?? device.lastHost ?? "–"),
                    ("Last error", device.error.map { "\($0.title): \($0.message)" } ?? "None"),
                ])
                HistoryList(entries: device.history)
                if device.kind == .real {
                    Button("Forget TV") { Task { await device.forget() } }
                        .controlSize(.small)
                        .help("Delete the stored pairing key so the next connection shows the TV's pairing prompt again")
                }
            }
            .padding(.top, 4)
        }
    }
}
