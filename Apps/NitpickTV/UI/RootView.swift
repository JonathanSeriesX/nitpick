import PatternLink
import SwiftUI

/// The video layer is always at the bottom; at most one screen sits on top of it. While a pattern is up (from the
/// Mac or the built-in menu) nothing visible is drawn over the layer.
struct RootView: View {
    let renderer: PatternRenderer
    let link: LinkCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var screen = Screen.pairing
    @State private var lastPattern: BuiltInPattern.ID?

    enum Screen: Equatable {
        case pairing, menu
        case pattern(BuiltInPattern)
    }

    var body: some View {
        ZStack {
            PatternView(renderer: renderer).ignoresSafeArea()
            if link.isConnected {
                ConnectedOverlay(link: link, renderer: renderer)
            } else {
                switch screen {
                case .pairing:
                    PairingScreen(link: link) { screen = .menu }
                case .menu:
                    StandaloneMenu(lastSelected: lastPattern, select: open) { screen = .pairing }
                case .pattern:
                    Color.clear
                        .contentShape(Rectangle())
                        .focusable()
                        .onExitCommand { screen = .menu }
                }
            }
        }
        .onAppear {
            #if DEBUG
                // Simulator checks without a remote: `simctl launch … -debugScreen menu` or `-debugScreen "<pattern id>"`.
                switch UserDefaults.standard.string(forKey: "debugScreen") {
                case "menu": screen = .menu
                case let id?: BuiltInPattern.sections.flatMap(\.patterns).first { $0.id == id }.map(open)
                case nil: break
                }
            #endif
        }
        .onChange(of: link.isConnected) { _, connected in
            if connected { screen = .pairing }
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                link.start()
                renderer.recover()
            case .background:
                link.stop()
            default:
                break
            }
        }
    }

    /// The screen saver would ruin a measurement: keep it off while a Mac is connected or a pattern is up.
    private var keepsScreenAwake: Bool {
        guard scenePhase == .active else { return false }
        if case .pattern = screen { return true }
        return link.isConnected
    }

    private func open(_ pattern: BuiltInPattern) {
        lastPattern = pattern.id
        screen = .pattern(pattern)
        Task {
            _ = try? renderer.show(.black(format: pattern.spec.format))
            _ = await renderer.requestDisplayMode(DisplayModeRequest(dynamicRange: pattern.dynamicRange))
            guard screen == .pattern(pattern) else { return }  // the user went back during the switch
            _ = try? renderer.show(pattern.spec)
        }
    }
}
