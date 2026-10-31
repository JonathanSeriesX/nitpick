import SwiftUI

@main
struct NitpickApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Nitpick")
            .frame(minWidth: 800, minHeight: 500)
    }
}
