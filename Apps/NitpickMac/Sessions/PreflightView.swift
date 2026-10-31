import Calibration
import SwiftUI

/// What must be true before (and is checked during) a run.
struct PreflightView: View {
    @Environment(AppModel.self) private var model
    let session: CalibrationSession
    let run: SessionRun?

    private enum CheckState { case done, pending, warning }

    private struct Check: Identifiable {
        let id: String
        let state: CheckState
        let detail: String
    }

    var body: some View {
        Card(title: "Pre-flight checklist", symbol: "checklist") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(checks) { check in
                    GridRow {
                        icon(check.state)
                        Text(check.id).fontWeight(.medium)
                        Text(check.detail).foregroundStyle(check.state == .warning ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func icon(_ state: CheckState) -> some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .pending: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("Pending")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        }
    }

    private var checks: [Check] {
        let devices = model.devices
        let profile = session.profile
        let stage = run?.stageIndex ?? 0
        let pastSignalPath = stage >= 2 || session.restorePoint != nil
        var out = [
            device("TV connected", devices.tv.phase, devices.tv.capabilities?.modelName),
            device("Meter connected", devices.meter.phase, devices.meter.info?.model),
            device("Pattern generator connected", devices.pattern.phase, devices.pattern.connectedName),
            Check(
                id: "Picture mode set", state: pastSignalPath ? .done : .pending,
                detail: "\(PictureModes.name(profile.pictureMode)) on \(profile.inputID.replacingOccurrences(of: "_", with: " "))"
                    + (pastSignalPath ? "" : " (set when the run starts)")),
            displayModeCheck(pastSignalPath),
            Check(
                id: "Settings snapshot taken", state: session.restorePoint != nil ? .done : .pending,
                detail: session.restorePoint.map { "\(RestorePoint.label), \($0.settings.values.count) settings" }
                    ?? "\(RestorePoint.label), taken before anything changes"),
        ]
        if profile.useInternalLUTs, let caps = devices.tv.capabilities {
            out.append(
                Check(
                    id: "Calibration API", state: caps.supportsCalibrationAPI ? .done : .warning,
                    detail: caps.supportsCalibrationAPI
                        ? "Available: LUT uploads enabled" : "Unavailable: the session uses picture controls only"))
        }
        return out
    }

    private func device(_ title: String, _ phase: DevicePhase, _ name: String?) -> Check {
        Check(
            id: title, state: phase == .connected ? .done : .warning,
            detail: phase == .connected ? (name ?? "Ready") : "\(phase.title): open Devices")
    }

    private func displayModeCheck(_ done: Bool) -> Check {
        let range = session.profile.dynamicRange
        if range == .dolbyVision {
            return Check(
                id: "Display mode", state: done ? .done : .pending,
                detail: done ? "Dolby Vision selected on the Apple TV" : "You choose Dolby Vision on the Apple TV when asked")
        }
        if let state = model.devices.pattern.capabilities?.displayMode, !state.matchingEnabled {
            return Check(
                id: "Display mode", state: .warning,
                detail: "Enable Match Dynamic Range on the Apple TV: Settings ▸ Video and Audio ▸ Match Content")
        }
        return Check(
            id: "Display mode", state: done ? .done : .pending,
            detail: done ? "\(range.displayName) output confirmed by the Apple TV" : "\(range.displayName) is requested when the run starts"
        )
    }
}
