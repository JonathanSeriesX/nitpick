import ColorScience
import MeterKit
import SwiftUI
import UniformTypeIdentifiers

/// Meter card: USB i1d3 meters, the virtual i1d3 or the simulated meter; info and colorimeter correction.
struct MeterCard: View {
    @Bindable var device: MeterDevice
    @State private var importing = false

    private static let correctionTypes = ["ccss", "ccmx"].map { UTType(filenameExtension: $0) ?? .data }

    var body: some View {
        Card(title: "Meter", symbol: "camera.metering.center.weighted", subtitle: subtitle) {
            StatusBadge(text: device.phase.title, color: device.phase.color)
        } content: {
            KindPicker(title: "Meter source", kinds: MeterKind.allCases, label: \.title, selection: device.kind) {
                await device.setKind($0)
            }
            if let progress = device.progress {
                ProgressView("Reading the meter's calibration memory…", value: progress)
                    .font(.callout)
            }
            if let error = device.error { ErrorBanner(error: error) { device.error = nil } }
            if device.phase == .connected, let info = device.info {
                InfoRows(rows: [
                    ("Model", info.model),
                    ("Serial", info.serialNumber.isEmpty ? "–" : info.serialNumber),
                    ("Firmware", info.firmware ?? "–"),
                    ("Max luminance", info.maximumLuminance > 0 ? Fmt.nits(info.maximumLuminance) : "–"),
                ])
                HStack {
                    Spacer()
                    Button("Disconnect") { Task { await device.disconnect() } }
                }
            } else if device.kind == .usb {
                usbList
            }
            Divider()
            correction
            if !device.diagnostics.isEmpty {
                DisclosureGroup("Diagnostics") {
                    InfoRows(rows: device.diagnostics.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }).padding(.top, 4)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.correctionTypes) { result in
            switch result {
            case .success(let url): Task { await device.importCorrection(from: url) }
            case .failure(let error): device.error = ErrorText(error)
            }
        }
    }

    private var subtitle: String {
        switch device.kind {
        case .usb: "Calibrite / X-Rite i1d3 family over USB"
        case .virtual: "Real i1d3 driver on a virtual USB device"
        case .simulated: "Simulated Display Plus HL"
        }
    }

    @ViewBuilder private var usbList: some View {
        if device.hidDevices.isEmpty {
            Text("No meter found. Plug in a Display Plus HL, Display Pro HL or i1Display Pro.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(device.hidDevices) { meter in
            DiscoveryRow(title: meter.product ?? "i1d3 meter", detail: meter.serialNumber.map { "Serial \($0)" }, actionTitle: "Connect") {
                Task { await device.connect(meter) }
            }
            .disabled(device.phase == .connecting)
        }
    }

    private var correction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Correction").font(.subheadline.weight(.semibold))
            if let c = device.correction {
                Text([c.name, c.displayTechnology, c.source].compactMap { $0 }.joined(separator: " · ")).font(.callout).lineLimit(2)
            } else {
                Text("None: the meter's default matrix.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Import .ccss / .ccmx…") { importing = true }
                    .help("A colorimeter correction for your TV's display technology (Argyll CGATS format)")
                Button("Clear") { Task { await device.clearCorrection() } }
                    .disabled(device.correction == nil)
            }
            .controlSize(.small)
        }
    }
}
