import AppKit
import SwiftUI

/// A titled, rounded panel used by device cards, charts and result sections.
struct Card<Accessory: View, Content: View>: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A coloured dot and label, e.g. "Connected".
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
    }
}

/// An inline message with an optional next step and action, for errors, warnings and prompts.
struct Banner<Actions: View>: View {
    enum Style { case error, warning, info, prompt }
    let style: Style
    let title: String
    var message: String?
    var nextStep: String?
    @ViewBuilder var actions: Actions

    private var color: Color {
        switch style {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .prompt: .accentColor
        }
    }

    private var symbol: String {
        switch style {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .prompt: "hand.raised.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let nextStep { Text(nextStep).font(.callout).fixedSize(horizontal: false, vertical: true) }
                HStack { actions }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(style: Style, title: String, message: String? = nil, nextStep: String? = nil) {
        self.init(style: style, title: title, message: message, nextStep: nextStep, actions: { EmptyView() })
    }
}

/// An `ErrorText` as a dismissible banner; the local-network case gets a button to System Settings.
struct ErrorBanner: View {
    let error: ErrorText
    var dismiss: (() -> Void)?

    var body: some View {
        Banner(style: .error, title: error.title, message: error.message, nextStep: error.nextStep) {
            if error.isLocalNetwork { OpenLocalNetworkSettingsButton() }
            if let dismiss { Button("Dismiss", action: dismiss).controlSize(.small) }
        }
    }
}

struct OpenLocalNetworkSettingsButton: View {
    var body: some View {
        Button("Open Privacy Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") {
                NSWorkspace.shared.open(url)
            }
        }
        .controlSize(.small)
        .help("Opens System Settings ▸ Privacy & Security ▸ Local Network")
    }
}

/// Label/value rows in two aligned columns.
struct InfoRows: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(rows[i].1).textSelection(.enabled).lineLimit(2)
                }
            }
        }
        .font(.callout)
    }
}

extension EnvironmentValues {
    /// Snapshot rendering lays the window out without `NavigationSplitView` (its sidebar does not draw off screen).
    @Entry var snapshotMode = false
}
