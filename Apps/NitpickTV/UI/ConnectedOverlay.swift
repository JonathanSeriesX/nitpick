import SwiftUI

/// While a Mac is connected the screen shows only the video layer. A 2-second toast announces the connection;
/// Menu shows a small status sheet that hides itself after 6 seconds.
struct ConnectedOverlay: View {
  let link: LinkCoordinator
  let renderer: PatternRenderer
  @State private var showsStatus = false

  var body: some View {
    ZStack(alignment: .top) {
      // Invisible focus target, so Menu reaches the app instead of leaving it.
      Color.clear
        .contentShape(Rectangle())
        .focusable()
        .onExitCommand { showsStatus.toggle() }
      if let toast = link.toast {
        Text(toast)
          .font(.headline)
          .padding(.horizontal, 40)
          .padding(.vertical, 20)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 60)
          .transition(.opacity)
      }
      if showsStatus {
        statusSheet
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .padding(60)
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.3), value: link.toast)
    .animation(.easeInOut(duration: 0.3), value: showsStatus)
    .task(id: showsStatus) {
      guard showsStatus else { return }
      try? await Task.sleep(for: .seconds(6))
      showsStatus = false
    }
  }

  private var statusSheet: some View {
    let state = renderer.currentDisplayState()
    let size = renderer.frameSize
    return VStack(alignment: .leading, spacing: 10) {
      Text("Connected to \(link.clients.values.map(\.name).sorted().joined(separator: ", "))").font(
        .headline)
      Group {
        Text(
          "Frames shown: \(renderer.framesShown) · last sequence: \(link.lastSequence.map(String.init) ?? "–")"
        )
        Text("Frame: \(size.width) × \(size.height)")
        Text(
          "Output request: \(state.requested?.dynamicRange.displayName ?? "none") · "
            + "matching \(state.matchingEnabled ? "on" : "off")\(state.switching ? " · switching" : "")"
        )
        if let note = state.note { Text(note).lineLimit(3) }
        if let error = renderer.lastError { Text("Renderer: \(error)").foregroundStyle(.red) }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .padding(32)
    .frame(maxWidth: 900, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
  }
}
