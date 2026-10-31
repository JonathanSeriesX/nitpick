import Calibration
import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case devices
    case session(UUID)
}

/// App state: sessions on disk, the devices, the current run and what the window presents.
@Observable
final class AppModel {
    let store: SessionStore
    let history: MeasurementHistory
    let devices: DeviceHub
    private(set) var sessions: [CalibrationSession] = []
    var selection: SidebarItem? = .devices
    /// The current run, or the last one until another starts.
    private(set) var run: SessionRun?
    var showNewSession = false
    var showInspector = false
    var showExportChooser = false
    var pendingDeletion: UUID?
    var export: ExportRequest?
    var alert: ErrorText?
    private(set) var restoring = false
    @ObservationIgnored private var started = false

    /// `base`: …/Application Support/Nitpick with Sessions/, Measurements/ and Snapshots/ inside.
    init(base: URL, defaults: UserDefaults) {
        var problem: ErrorText?
        func open<T>(_ name: String, _ make: (URL) throws -> T) -> T {
            do { return try make(base.appendingPathComponent(name)) } catch {
                problem = ErrorText(
                    title: "Cannot open the session library", message: "\(error.localizedDescription)",
                    nextStep: "Sessions are kept in a temporary folder until Nitpick can write to \(base.path).")
                return try! make(FileManager.default.temporaryDirectory.appendingPathComponent("Nitpick-\(name)"))
            }
        }
        store = open("Sessions", SessionStore.init(directory:))
        history = open("Measurements", MeasurementHistory.init(directory:))
        devices = DeviceHub(defaults: defaults, snapshotDirectory: base.appendingPathComponent("Snapshots"))
        alert = problem
        // Sessions left running by a quit or crash become interrupted (their banner offers Restore).
        _ = try? store.markInterrupted()
        reload()
    }

    static func live() -> AppModel {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppModel(base: support.appendingPathComponent("Nitpick"), defaults: .standard)
    }

    func start() async {
        guard !started else { return }
        started = true
        await devices.start()
    }

    func reload() {
        sessions = (try? store.list()) ?? []
        if case .session(let id) = selection, !sessions.contains(where: { $0.id == id }) { selection = .devices }
    }

    var selectedSession: CalibrationSession? {
        guard case .session(let id) = selection else { return nil }
        return sessions.first { $0.id == id }
    }

    func session(_ id: UUID) -> CalibrationSession? { sessions.first { $0.id == id } }

    /// Completed HDR10 movie sessions: the possible sources of a Dolby Vision session.
    var dolbySources: [CalibrationSession] {
        sessions.filter { $0.status == .completed && $0.profile.dynamicRange == .hdr10 && $0.profile.usage == .movie }
    }

    @discardableResult
    func create(_ profile: SessionProfile) -> UUID? {
        let session = CalibrationSession(profile: profile)
        do {
            try store.save(session)
            reload()
            selection = .session(session.id)
            return session.id
        } catch {
            alert = ErrorText(error)
            return nil
        }
    }

    func delete(_ id: UUID) {
        guard run?.sessionID != id || run?.isRunning != true else { return }
        do {
            try store.delete(id: id)
            if run?.sessionID == id { run = nil }
            reload()
        } catch { alert = ErrorText(error) }
    }

    // MARK: Running

    var isRunning: Bool { run?.isRunning == true }

    /// Why the session cannot run now, or nil.
    func runBlocker(_ session: CalibrationSession) -> String? {
        if isRunning { return run?.sessionID == session.id ? "This session is running." : "Another session is running." }
        return devices.missingDevice
    }

    /// Runs the session; a completed one is run again as a new session with the same profile.
    func startRun(_ id: UUID) {
        guard var session = session(id), runBlocker(session) == nil else { return }
        if session.status == .completed {
            guard let copy = create(session.profile), let fresh = self.session(copy) else { return }
            session = fresh
        }
        do {
            let devices = try self.devices.workflowDevices()
            let run = SessionRun(sessionID: session.id, profile: session.profile, runner: WorkflowRunner(store: store, history: history))
            self.run = run
            selection = .session(session.id)
            run.start(devices: devices, session: session, sleeper: self.devices.sleeper) { [weak self, weak run] in
                guard let self else { return }
                if let run, case .failed(let message)? = run.outcome { store.recordFailure(message, for: run.sessionID) }
                reload()
            }
        } catch { alert = ErrorText(error) }
    }

    func cancelRun() { run?.cancel() }

    /// Answers the workflow's prompt. On the simulated Apple TV this also plays the user's part (choosing Dolby Vision).
    func confirmPrompt() {
        if let simulated = devices.pattern.simulated, run?.profile.dynamicRange == .dolbyVision {
            try? simulated.simulateUserSelectsOutput(.dolbyVision)
        }
        run?.confirm()
    }

    // MARK: Restore

    /// Why the TV settings of the session cannot be restored now, or nil.
    func restoreBlocker(_ session: CalibrationSession) -> String? {
        if session.restorePoint == nil { return "No settings snapshot was taken in this session." }
        if run?.sessionID == session.id && isRunning { return "The session is running; cancelling it restores the settings." }
        if devices.tv.phase != .connected { return "Connect the TV on the Devices screen first." }
        if restoring { return "Restoring…" }
        return nil
    }

    /// Writes back every setting of the snapshot that differs now. LUTs are not restored (they cannot be read back).
    func restore(_ id: UUID) async {
        guard let session = session(id), restoreBlocker(session) == nil, let point = session.restorePoint,
            let tv = devices.tv.controller
        else { return }
        restoring = true
        defer { restoring = false }
        do {
            let count = try await TVRestore.apply(point, to: tv)
            var updated = session
            let note = "Restored \(count) picture setting(s) of \(PictureModes.name(point.settings.pictureMode)) on \(Fmt.date(Date()))."
            updated.notes += (updated.notes.isEmpty ? "" : "\n") + note
            if updated.status == .interrupted { updated.status = .cancelled }
            try store.save(updated)
            reload()
            await devices.tv.refreshSettings()
            alert = ErrorText(
                title: "TV settings restored", message: note + " Calibration data uploaded to the TV is not part of the snapshot.")
        } catch {
            alert = ErrorText(error)
        }
    }

    // MARK: Export

    func requestExport(_ kind: ExportKind, of id: UUID) {
        guard let session = session(id) else { return }
        do { export = try ExportRequest(session: session, kind: kind) } catch { alert = ErrorText(error) }
    }
}

extension SessionStore {
    /// The engine saves only its restore note with a failed session; this adds the reason so a reopened session says why.
    func recordFailure(_ message: String, for id: UUID) {
        guard var session = try? load(id: id), !session.notes.contains(message) else { return }
        var lines = session.notes.split(separator: "\n").map(String.init)
        if let last = lines.last, message.hasSuffix(last) { lines.removeLast() }
        lines.append("Failed: \(message)")
        session.notes = lines.joined(separator: "\n")
        try? save(session)
    }
}

/// Writes a `RestorePoint` back through a connected TV.
enum TVRestore {
    /// Switches to the snapshot's picture mode if needed, then writes the settings that differ. Returns how many.
    static func apply(_ point: RestorePoint, to tv: any TVController) async throws -> Int {
        let mode = point.settings.pictureMode
        if try await tv.readPictureSettings(pictureMode: nil).pictureMode != mode {
            do { try await tv.setPictureMode(mode) } catch {
                throw CalibrationError.precondition(
                    "The TV cannot switch to \(PictureModes.name(mode)) now. Play \(SimulatedPanel.signalPath(of: mode)?.displayName ?? "matching") content on the TV, then restore again."
                )
            }
        }
        let current = try await tv.readPictureSettings(pictureMode: nil)
        let changes = point.settings.values.filter { current.values[$0.key] != $0.value }
        if !changes.isEmpty { try await tv.writePictureSettings(changes) }
        return changes.count
    }
}
