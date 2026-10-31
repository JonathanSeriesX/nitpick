import Calibration
import SwiftUI

/// The main window: sidebar of devices and sessions, the selected screen, sheets, dialogs and the inspector.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        @Bindable var model = model
        Group {
            if snapshotMode {
                HStack(spacing: 0) {
                    Sidebar().frame(width: 250).background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                    detail
                }
            } else {
                NavigationSplitView {
                    Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    detail
                }
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView().inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet() }
        .alert(
            model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text([error.message, error.nextStep].compactMap { $0 }.joined(separator: "\n\n"))
        }
        .confirmationDialog(
            "Delete “\(model.pendingDeletion.flatMap(model.session)?.profile.name ?? "session")”?",
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { id in
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: { _ in
            Text("The session and its measurements are removed from this Mac. The TV is not changed.")
        }
        .confirmationDialog("Export", isPresented: $model.showExportChooser, presenting: model.selectedSession) { session in
            ForEach(ExportKind.allCases.filter { $0.isAvailable(for: session) }) { kind in
                Button(kind.title) { model.requestExport(kind, of: session.id) }
            }
        }
        .fileExporter(
            isPresented: Binding(get: { model.export != nil }, set: { if !$0 { model.export = nil } }),
            document: model.export?.file, contentType: model.export?.contentType ?? .data, defaultFilename: model.export?.filename
        ) { result in
            if case .failure(let error) = result { model.alert = ErrorText(error) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .devices?, nil:
            DevicesView()
        case .session(let id):
            if let session = model.session(id) {
                SessionView(session: session).id(id)
            } else {
                ContentUnavailableView(
                    "No session selected", systemImage: "list.bullet.rectangle", description: Text("Choose a session in the sidebar."))
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Setup") {
                Label {
                    HStack {
                        Text("Devices")
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach([model.devices.tv.phase, model.devices.meter.phase, model.devices.pattern.phase].indices, id: \.self) {
                                i in
                                Circle().fill([model.devices.tv.phase, model.devices.meter.phase, model.devices.pattern.phase][i].color)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .accessibilityLabel(model.devices.allConnected ? "All devices connected" : "Some devices not connected")
                    }
                } icon: {
                    Image(systemName: "cable.connector")
                }
                .tag(SidebarItem.devices)
            }
            ForEach(ProfileGroup.allCases) { group in
                let sessions = model.sessions.filter { ProfileGroup($0.profile) == group }.reversed()
                if !sessions.isEmpty {
                    Section(group.title) {
                        ForEach(Array(sessions)) { session in
                            SessionRow(session: session, running: model.run?.sessionID == session.id && model.isRunning)
                                .tag(SidebarItem.session(session.id))
                                .contextMenu {
                                    Button("Run") { model.startRun(session.id) }.disabled(model.runBlocker(session) != nil)
                                    Button("Export Session (JSON)…") { model.requestExport(.json, of: session.id) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { model.pendingDeletion = session.id }
                                }
                        }
                    }
                }
            }
            if model.sessions.isEmpty {
                Section("Sessions") {
                    Text("No sessions yet. Click + to create one.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(snapshotMode ? .hidden : .automatic)
        .onDeleteCommand {
            if case .session(let id) = model.selection { model.pendingDeletion = id }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    model.showNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Session (⌘N)")
                Spacer()
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.showNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("New Session (⌘N)")
            }
        }
    }
}

private struct SessionRow: View {
    let session: CalibrationSession
    let running: Bool

    var body: some View {
        let status: CalibrationSession.Status = running ? .running : session.status
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.profile.name).lineLimit(1)
                Text(
                    "\(session.createdAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(PictureModes.name(session.profile.pictureMode))"
                )
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: status.symbol)
                .foregroundStyle(status == .completed && !session.passed ? Color.orange : status.color)
                .accessibilityLabel(status.title)
                .help(status == .completed ? (session.passed ? "Completed within tolerance" : "Completed, out of tolerance") : status.title)
        }
        .padding(.vertical, 2)
    }
}
