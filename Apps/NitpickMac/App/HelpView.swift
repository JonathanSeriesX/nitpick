import Calibration
import SwiftUI

/// A short in-app guide (Help ▸ Nitpick Help).
struct HelpView: View {
    private let topics: [(String, String, String)] = [
        (
            "cable.connector", "1. Connect the devices",
            "On Devices, pair the LG TV (accept the prompt on the TV), plug in the meter, and pair the Apple TV with the 6-digit code shown in Nitpick on the Apple TV. No hardware? Turn on Demo mode."
        ),
        (
            "plus", "2. Create a session",
            "File ▸ New Session (⌘N). Choose Movie or Game and SDR, HDR10 or Dolby Vision. Each choice starts from a preset; Dolby Vision needs a completed Movie HDR10 session."
        ),
        (
            "play.fill", "3. Run",
            "Session ▸ Run (⌘R). Point the meter at the centre of the screen. Nitpick takes a settings snapshot before changing anything. Cancel (⌘.) at any time: the snapshot is written back."
        ),
        (
            "chart.bar.xaxis", "4. Read the results",
            "Switch between Before and After. Green tiles meet the session's tolerances, red ones do not. Export measurements, the session or the LUTs with File ▸ Export (⌘E)."
        ),
        (
            "arrow.uturn.backward", "Restore TV settings",
            "Restores the picture settings saved in the session's \(RestorePoint.label.prefix(1).lowercased() + RestorePoint.label.dropFirst()). Calibration data uploaded to the TV (LUTs) cannot be read back and is not restored."
        ),
        (
            "network", "Local network access",
            "If no Apple TV or LG TV appears, allow Nitpick in System Settings ▸ Privacy & Security ▸ Local Network."
        ),
        (
            "tv", "Apple TV display mode",
            "Nitpick switches the Apple TV between SDR and HDR10 itself. Enable Match Dynamic Range on the Apple TV: Settings ▸ Video and Audio ▸ Match Content."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Nitpick Help").font(.largeTitle.weight(.semibold))
                ForEach(topics.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: topics[i].0).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(topics[i].1).font(.headline)
                            Text(topics[i].2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 480, minHeight: 480)
    }
}
