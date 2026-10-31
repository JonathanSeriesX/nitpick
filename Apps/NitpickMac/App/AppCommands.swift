import SwiftUI

/// Menu bar: File ▸ New Session / Export…, Session ▸ Run / Cancel / Restore TV Settings, View ▸ Inspector, Help.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { model.showNewSession = true }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .importExport) {
            Button("Export…") { model.showExportChooser = true }
                .keyboardShortcut("e")
                .disabled(model.selectedSession == nil)
        }
        CommandMenu("Session") {
            let session = model.selectedSession
            Button("Run") { if let session { model.startRun(session.id) } }
                .keyboardShortcut("r")
                .disabled(session.map { model.runBlocker($0) != nil } ?? true)
            Button("Cancel") { model.cancelRun() }
                .keyboardShortcut(".")
                .disabled(!model.isRunning)
            Divider()
            Button("Restore TV Settings") { if let session { Task { await model.restore(session.id) } } }
                .disabled(session.map { model.restoreBlocker($0) != nil } ?? true)
            Divider()
            Button("Show Devices") { model.selection = .devices }
                .keyboardShortcut("0")
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Nitpick Help") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
    }
}
