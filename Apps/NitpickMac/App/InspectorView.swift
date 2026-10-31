import Calibration
import SwiftUI

/// Details of the selected session's profile, or of the devices.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let session = model.selectedSession {
                sessionSections(session)
            } else {
                devicesSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func sessionSections(_ session: CalibrationSession) -> some View {
        let p = session.profile
        let t = p.target
        let m = p.measurement
        Section("Target") {
            LabeledContent("EOTF", value: t.eotf.displayName)
            LabeledContent("White", value: "D65 (\(Fmt.xy(t.whitePoint)))")
            LabeledContent("Colorimetry", value: t.colorimetry == .bt709 ? "BT.709" : "BT.2020")
            LabeledContent(t.isHDR ? "Mastering peak" : "Peak white", value: Fmt.nits(t.peakWhite))
            if t.isHDR {
                LabeledContent("Content gamut", value: "P3-D65")
                LabeledContent("Above the peak", value: t.hdrMapping == .rollOff ? "Roll-off" : "Hard clip (HGIG)")
            }
        }
        Section("TV") {
            LabeledContent("Picture mode", value: PictureModes.name(p.pictureMode))
            LabeledContent("Input", value: p.inputID.replacingOccurrences(of: "_", with: " "))
            LabeledContent("Internal LUTs", value: p.useInternalLUTs ? "On" : "Off")
            if p.dynamicRange == .sdr {
                LabeledContent("3D LUT", value: p.cubeLUT ? "\(p.cubeSize)³ from \(p.cubeGridLevels)³ patches" : "Off")
            }
            LabeledContent("Reset LUTs on cancel", value: p.restoreLUTsOnCancel ? "Yes" : "No")
        }
        Section("Measurement") {
            LabeledContent("Settling", value: m.settlingTime.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))
            LabeledContent("Reads per patch", value: "\(m.minReads)–\(m.maxReads)")
            LabeledContent("Target noise", value: "\(Fmt.num(m.targetNoise * 100, 1)) %")
            LabeledContent("Window", value: "\(Int(m.window.areaFraction * 100)) %")
        }
        Section("Tolerances") {
            let tol = p.tolerances
            if t.isHDR {
                LabeledContent("Grayscale max ΔE ITP", value: Fmt.num(tol.hdrGrayscaleMaxITP, 1))
                LabeledContent("Colour max ΔE ITP", value: Fmt.num(tol.hdrColorMaxITP, 1))
            } else {
                LabeledContent("Grayscale avg / max", value: "\(Fmt.num(tol.grayscaleAverage, 1)) / \(Fmt.num(tol.grayscaleMax, 1))")
                LabeledContent("Colour p95 / max", value: "\(Fmt.num(tol.colorP95, 1)) / \(Fmt.num(tol.colorMax, 1))")
                LabeledContent("Luminance error", value: "\(Fmt.num(tol.luminanceErrorPercent, 0)) %")
            }
        }
        if !session.notes.isEmpty {
            Section("Notes") { Text(session.notes).font(.callout).textSelection(.enabled) }
        }
    }

    private var devicesSection: some View {
        let d = model.devices
        return Section("Devices") {
            LabeledContent("TV", value: d.tv.capabilities?.modelName ?? d.tv.phase.title)
            LabeledContent("Meter", value: d.meter.info?.model ?? d.meter.phase.title)
            LabeledContent("Pattern generator", value: d.pattern.connectedName ?? d.pattern.phase.title)
            LabeledContent("Demo time", value: d.pattern.kind == .simulated ? "\(Int(DeviceHub.demoSpeedup))× real time" : "Real time")
        }
    }
}
