import SwiftUI

@main
enum NitpickMain {
    static func main() {
        #if DEBUG
            // -demoRun <preset> / -renderScreenshots <dir>: headless verification, then exit.
            if Headless.runIfRequested() { return }
        #endif
        NitpickApp.main()
    }
}

struct NitpickApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        Window("Nitpick", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .task { await model.start() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        Window("Nitpick Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 640)
    }
}
