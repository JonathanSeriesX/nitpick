import Calibration
import SwiftUI

/// One session: header and actions, banners, pre-flight checks, the live run and the results.
struct SessionView: View {
    let session: CalibrationSession

    var body: some View {
        ScrollView {
            SessionContent(session: session).padding(24)
        }
        .navigationTitle(session.profile.name)
        .navigationSubtitle(ProfileGroup(session.profile).title)
    }
}

/// The scrollable content of `SessionView` (rendered on its own for full-length snapshots).
struct SessionContent: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession

    var body: some View {
        let run = model.run?.sessionID == session.id ? model.run : nil
        let running = run?.isRunning == true
        VStack(alignment: .leading, spacing: 20) {
            SessionHeader(session: session, running: running)
            if session.status == .interrupted { interruptedBanner }
            if run == nil, session.status == .failed || session.status == .cancelled {
                Banner(
                    style: session.status == .failed ? .error : .info,
                    title: session.status == .failed ? "The last run failed" : "The last run was cancelled",
                    message: session.notes.isEmpty ? nil : session.notes,
                    nextStep: "Check the devices and run the session again.")
            }
            if let run { RunProgressView(run: run) }
            if session.result == nil || running { PreflightView(session: session, run: run) }
            if let result = session.result, !running { ResultsView(session: session, result: result) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interruptedBanner: some View {
        let blocker = model.restoreBlocker(session)
        return Banner(
            style: .warning, title: "This session was interrupted",
            message: "Nitpick quit while the session was running, so the TV may still have settings the session changed.",
            nextStep: session.restorePoint == nil
                ? "No settings snapshot was taken, so nothing on the TV was changed."
                : "Restore the settings snapshot taken before the session changed anything. \(blocker ?? "")"
        ) {
            if session.restorePoint != nil {
                Button("Restore TV Settings") { Task { await model.restore(session.id) } }
                    .disabled(blocker != nil)
            }
        }
    }
}

struct SessionHeader: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession
    let running: Bool

    var body: some View {
        // Actions sit beside the title when there is room, below it in a narrow window or with the inspector open.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                info
                Spacer(minLength: 16)
                actions(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 12) {
                info
                actions(alignment: .leading)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: ProfileGroup(session.profile).symbol).font(.title).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(session.profile.name).font(.largeTitle.weight(.semibold)).lineLimit(1)
                StatusPill(session: session, running: running)
            }
            Text(session.subtitle).font(.title3).foregroundStyle(.secondary)
            Text(session.targetDescription).font(.callout)
            HStack(spacing: 16) {
                Label(session.tvModel ?? "TV not used yet", systemImage: "tv")
                Label(session.meterModel ?? "Meter not used yet", systemImage: "camera.metering.center.weighted")
                Label("Created \(Fmt.date(session.createdAt))", systemImage: "calendar")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func actions(alignment: HorizontalAlignment) -> some View {
        let runBlocker = model.runBlocker(session)
        let restoreBlocker = model.restoreBlocker(session)
        return VStack(alignment: alignment, spacing: 8) {
            HStack(spacing: 8) {
                if running {
                    Button("Cancel", systemImage: "stop.fill") { model.cancelRun() }
                        .help("Stop the session (⌘.); the TV's settings are restored from the snapshot")
                } else {
                    Button(session.status == .completed ? "Run Again" : "Run", systemImage: "play.fill") { model.startRun(session.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(runBlocker != nil)
                        .help(
                            runBlocker
                                ?? (session.status == .completed
                                    ? "Run this profile again as a new session (⌘R)" : "Start the calibration (⌘R)"))
                }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ForEach(ExportKind.allCases) { kind in
                        Button(kind.title) { model.requestExport(kind, of: session.id) }.disabled(!kind.isAvailable(for: session))
                    }
                }
                .fixedSize()
                .help("Export measurements, the session or generated LUTs")
                Button("Restore TV Settings", systemImage: "arrow.uturn.backward") { Task { await model.restore(session.id) } }
                    .disabled(restoreBlocker != nil)
                    .help(restoreBlocker ?? "Write back the settings snapshot taken before this session changed anything")
                Button("Delete Session", systemImage: "trash") { model.pendingDeletion = session.id }
                    .labelStyle(.iconOnly)
                    .disabled(running)
                    .help("Delete this session")
                    .accessibilityLabel("Delete session")
            }
            .fixedSize()
            if !running, let runBlocker { Text(runBlocker).font(.caption).foregroundStyle(.secondary) }
            if !running, session.restorePoint != nil, let restoreBlocker {
                Text("Restore: \(restoreBlocker)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    let session: CalibrationSession
    let running: Bool

    var body: some View {
        let status: CalibrationSession.Status = running ? .running : session.status
        let verdict = status == .completed ? (session.passed ? " · within tolerance" : " · out of tolerance") : ""
        let color = status == .completed && !session.passed ? Color.orange : status.color
        Label(status.title + verdict, systemImage: status.symbol)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
            .accessibilityLabel("Status: \(status.title)\(verdict)")
    }
}
