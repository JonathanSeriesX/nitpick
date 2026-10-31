import SwiftUI

@main
struct NitpickTVApp: App {
  @State private var renderer: PatternRenderer
  @State private var link: LinkCoordinator

  init() {
    let renderer = PatternRenderer()
    _renderer = State(initialValue: renderer)
    _link = State(initialValue: LinkCoordinator(renderer: renderer))
  }

  var body: some Scene {
    WindowGroup {
      RootView(renderer: renderer, link: link)
    }
  }
}
