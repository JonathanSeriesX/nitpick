import Calibration
import ColorScience
import SwiftUI

/// Creates a session: usage and dynamic range pick the preset, the rest refines it.
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewSessionDraft

    init(draft: NewSessionDraft = NewSessionDraft()) { _draft = State(initialValue: draft) }

    var body: some View {
        let caps = model.devices.tv.capabilities
        let problems = draft.problems(capabilities: caps)
        VStack(spacing: 0) {
            Form {
                Section("Session") {
                    TextField("Name", text: $draft.name)
                    Picker("Usage", selection: presetBinding(\.usage)) {
                        Text("Movie").tag(SessionProfile.Usage.movie)
                        Text("Game").tag(SessionProfile.Usage.game)
                    }
                    .pickerStyle(.segmented)
                    .disabled(draft.range == .dolbyVision)
                    .help(
                        draft.range == .dolbyVision
                            ? "Dolby Vision sessions calibrate Cinema Dark"
                            : "Movie modes can use the TV's internal LUTs; game modes use picture controls")
                    Picker("Dynamic range", selection: presetBinding(\.range)) {
                        ForEach(NewSessionDraft.ranges) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("TV") {
                    Picker("Input", selection: $draft.inputID) {
                        ForEach(inputs(caps)) { Text($0.label + ($0.isConnected ? " (in use)" : "")).tag($0.id) }
                    }
                    Picker("Picture mode", selection: $draft.pictureMode) {
                        ForEach(PictureModes.ids(for: draft.range), id: \.self) { Text(PictureModes.name($0)).tag($0) }
                    }
                }
                if draft.range == .dolbyVision { dolbySource }
                target
                options(caps)
            }
            .formStyle(.grouped)
            Divider()
            footer(problems)
        }
        .frame(width: 580, height: 700)
        .onAppear {
            if let input = caps?.inputs.first(where: \.isConnected)?.id { draft.inputID = input }
            adjustForTV(caps)
        }
    }

    /// A binding that re-applies the preset when usage or dynamic range changes, keeping a name the user typed.
    private func presetBinding<T>(_ key: WritableKeyPath<NewSessionDraft, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: key] },
            set: { value in
                let customName = draft.name != draft.preset.name ? draft.name : nil
                draft[keyPath: key] = value
                draft.applyPreset()
                if let customName { draft.name = customName }
                adjustForTV(model.devices.tv.capabilities)
            })
    }

    private func adjustForTV(_ caps: TVCapabilities?) {
        if let caps, !caps.supportsCalibrationAPI { draft.useInternalLUTs = false }
    }

    private func inputs(_ caps: TVCapabilities?) -> [TVInput] {
        caps?.inputs ?? (1...4).map { TVInput(id: "HDMI_\($0)", label: "HDMI \($0)", isConnected: false) }
    }

    private var dolbySource: some View {
        Section {
            Picker("HDR10 session", selection: $draft.sourceSessionID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(model.dolbySources) { s in
                    Text("\(s.profile.name) · \(Fmt.date(s.createdAt))").tag(UUID?.some(s.id))
                }
            }
        } header: {
            Text("Source")
        } footer: {
            Text("The Dolby Vision configuration is derived from the measurements of a completed Movie HDR10 session of this TV.")
        }
    }

    @ViewBuilder private var target: some View {
        Section("Target") {
            if draft.range == .sdr {
                Picker("EOTF", selection: $draft.eotf) {
                    ForEach(NewSessionDraft.EOTF.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Peak white") {
                    HStack {
                        TextField("Peak white", value: $draft.peak, format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("cd/m²").foregroundStyle(.secondary)
                        Stepper("Peak white", value: $draft.peak, in: 50...600, step: 10).labelsHidden()
                    }
                }
            } else {
                Picker("HDR10 metadata", selection: $draft.metadata) {
                    ForEach(NewSessionDraft.Metadata.allCases) { Text($0.title).tag($0) }
                }
                if draft.range == .hdr10 {
                    Picker("Tone mapping", selection: $draft.mapping) {
                        Text("Roll-off (static tone map)").tag(CalibrationTarget.HDRMapping.rollOff)
                        Text("Hard clip (HGIG)").tag(CalibrationTarget.HDRMapping.hardClip)
                    }
                }
            }
        }
    }

    private func options(_ caps: TVCapabilities?) -> some View {
        Section("Options") {
            Toggle("Internal LUTs (TV calibration API)", isOn: $draft.useInternalLUTs)
                .disabled(caps.map { !$0.supportsCalibrationAPI } ?? false)
                .help("Off: picture controls only (OLED light, contrast, white balance)")
            if draft.range == .sdr {
                Toggle("3D LUT (\(draft.preset.cubeSize)³, \(draft.preset.cubeGridLevels)³ patches)", isOn: $draft.cubeLUT)
                    .disabled(!draft.useInternalLUTs)
            }
            LabeledContent("Settling time") {
                HStack {
                    Slider(value: $draft.settlingMS, in: 200...3000, step: 100).frame(width: 180).labelsHidden()
                    Text("\(Int(draft.settlingMS)) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
            Stepper("Minimum reads per patch: \(draft.minReads)", value: $draft.minReads, in: 1...10)
            Stepper("Maximum reads per patch: \(draft.maxReads)", value: $draft.maxReads, in: 1...20)
        }
    }

    private func footer(_ problems: [String]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let first = problems.first {
                Label(first, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(2)
            } else {
                Text(
                    draft.preset.target.isHDR
                        ? "Uses \(PictureModes.name(draft.pictureMode)) with PQ patterns." : "Uses \(PictureModes.name(draft.pictureMode))."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create Session") {
                model.create(draft.profile())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!problems.isEmpty)
        }
        .padding(16)
    }
}
