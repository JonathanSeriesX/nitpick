import Calibration
import ColorScience
import Foundation
import LGControl
import MeterKit
import Network
import PatternLink

/// A thrown error as the user reads it: what happened and what to do next.
struct ErrorText: Equatable, Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var nextStep: String?
    /// macOS refused local network access: show the System Settings hint.
    var isLocalNetwork = false

    static let localNetworkHint = "Allow Nitpick in System Settings ▸ Privacy & Security ▸ Local Network, then try again."

    init(title: String, message: String, nextStep: String? = nil, isLocalNetwork: Bool = false) {
        self.title = title
        self.message = message
        self.nextStep = nextStep
        self.isLocalNetwork = isLocalNetwork
    }

    init(_ error: any Error) {
        switch error {
        case let e as MeterError: self = Self.meter(e)
        case let e as LGError: self = Self.tv(e)
        case let e as PatternLinkError: self = Self.link(e)
        case let e as CalibrationError: self = Self.calibration(e)
        case let e as CGATSError: self = Self.correction(e)
        case let e as NWError: self = Self.network(e)
        case is CancellationError: self.init(title: "Cancelled", message: "The operation was cancelled.")
        default:
            self.init(
                title: "Something went wrong", message: (error as NSError).localizedDescription,
                nextStep: "Try again. If it keeps happening, reconnect the device on the Devices screen.")
        }
    }

    private static func meter(_ e: MeterError) -> ErrorText {
        let message = e.errorDescription ?? "\(e)"
        switch e {
        case .busy:
            return ErrorText(
                title: "The meter is in use", message: "Another app has the meter open.",
                nextStep: "Quit Calibrite PROFILER, DisplayCAL or other calibration software, then click Connect again.")
        case .accessDenied:
            return ErrorText(
                title: "macOS blocked the meter", message: "The app was not allowed to open the USB device.",
                nextStep:
                    "Unplug the meter and plug it in again. If it still fails, this build lacks the USB entitlement (App Sandbox ▸ Hardware ▸ USB)."
            )
        case .disconnected, .notConnected:
            return ErrorText(
                title: "The meter was disconnected", message: message,
                nextStep: "Check the USB cable, plug the meter in again and click Connect.")
        case .unsupportedVariant:
            return ErrorText(
                title: "Unsupported meter", message: message, nextStep: "This unit only works with the software it was sold with.")
        case .diffuserOverSensor:
            return ErrorText(
                title: "Diffuser over the sensor", message: message, nextStep: "Swing the ambient diffuser away, then measure again.")
        case .invalidCorrection:
            return ErrorText(title: "Correction not usable", message: message, nextStep: "Choose a different .ccss or .ccmx file.")
        default:
            return ErrorText(title: "Meter error", message: message, nextStep: "Unplug the meter, plug it in again and click Connect.")
        }
    }

    private static func tv(_ e: LGError) -> ErrorText {
        switch e {
        case .pairingDenied:
            return ErrorText(
                title: "Pairing declined on the TV", message: "Decline was chosen on the TV's pairing prompt.",
                nextStep: "Click Connect again and choose Accept on the TV.")
        case .pairingRejected(let why):
            return ErrorText(
                title: "The TV refused pairing", message: why,
                nextStep: "Click Connect again and choose Accept on the TV. If the TV keeps refusing, check for a TV software update.")
        case .timeout(let what):
            return ErrorText(
                title: "The TV did not answer", message: "\(what) timed out.",
                nextStep: "Check that the TV is on and on the same network. If the TV shows a prompt, accept it within 60 seconds.")
        case .connectionFailed(let why):
            return ErrorText(
                title: "Cannot reach the TV", message: why,
                nextStep: "Check the IP address and that the TV is on. Enable “LG Connect Apps” in the TV's network settings.")
        case .certificateChanged:
            return ErrorText(
                title: "The TV's certificate changed",
                message: "The TV presented a different security certificate than at pairing.",
                nextStep: "If the TV was reset or replaced, use Forget TV in Diagnostics and pair again. Otherwise check your network.")
        case .calibrationUnavailable(let why):
            return ErrorText(
                title: "Calibration API unavailable", message: why,
                nextStep: "Turn off Internal LUTs in the session options to use picture controls only.")
        case .server(let code, let message, _):
            return ErrorText(
                title: code == 401 ? "The TV refused the command" : "The TV reported an error", message: message,
                nextStep: code == 401 ? "Pair the TV again so it grants the needed permissions." : "Try again.")
        default:
            return ErrorText(title: "TV error", message: "\(e)", nextStep: "Reconnect the TV on the Devices screen and try again.")
        }
    }

    private static func link(_ e: PatternLinkError) -> ErrorText {
        switch e {
        case .authenticationFailed:
            return ErrorText(
                title: "Pairing code not accepted", message: "The Apple TV did not accept the code or the saved pairing.",
                nextStep: "Enter the 6-digit code shown in Nitpick on the Apple TV.")
        case .versionMismatch:
            return ErrorText(
                title: "Version mismatch", message: "Nitpick on the Apple TV speaks a different protocol version.",
                nextStep: "Update Nitpick on the Mac and on the Apple TV to the same version.")
        case .timeout:
            return ErrorText(
                title: "The Apple TV did not answer", message: "The request timed out.",
                nextStep: "Open Nitpick on the Apple TV and keep it in the foreground.")
        case .connectionFailed(let why):
            return network(why)
                ?? ErrorText(
                    title: "Cannot reach the Apple TV", message: why,
                    nextStep: "Open Nitpick on the Apple TV and check that both devices are on the same network.")
        case .disconnected, .notConnected:
            return ErrorText(
                title: "The Apple TV disconnected", message: "The pattern generator connection closed.",
                nextStep: "Check that Nitpick is still open on the Apple TV, then connect again.")
        case .remote(let error):
            return ErrorText(title: "The Apple TV reported an error", message: error.message, nextStep: "Try again.")
        }
    }

    private static func calibration(_ e: CalibrationError) -> ErrorText {
        let message = e.description
        switch e {
        case .notConnected(let device):
            return ErrorText(
                title: "\(device) not connected", message: message, nextStep: "Connect the \(device.lowercased()) on the Devices screen.")
        case .timeout(let what):
            return ErrorText(
                title: "\(what) did not respond", message: message, nextStep: "Check the device and its connection, then run again.")
        case .refused:
            return ErrorText(
                title: "The TV refused the change", message: message,
                nextStep: "Game Optimizer modes refuse calibration uploads; turn off Internal LUTs for game sessions.")
        case .precondition:
            return ErrorText(title: "Cannot start this step", message: message)
        case .outOfRange, .unsupportedSetting:
            return ErrorText(title: "Setting not accepted", message: message, nextStep: "Check the TV's picture mode and try again.")
        case .deviceFailure, .invalidState:
            return ErrorText(title: "Device error", message: message, nextStep: "Reconnect the device on the Devices screen and run again.")
        }
    }

    private static func correction(_ e: CGATSError) -> ErrorText {
        let detail: String =
            switch e {
            case .empty: "The file is empty."
            case .missingDataFormat: "The file has no data format section."
            case .missingData: "The file has no data."
            case .malformed(let why): why
            }
        return ErrorText(title: "Cannot read the correction file", message: detail, nextStep: "Choose an Argyll .ccss or .ccmx file.")
    }

    private static func network(_ e: NWError) -> ErrorText {
        network("\(e)")
            ?? ErrorText(
                title: "Network error", message: e.localizedDescription,
                nextStep: "Check that the Mac and the device are on the same network.")
    }

    /// kDNSServiceErr_PolicyDenied (-65570) or "Local network prohibited": macOS denied local network access.
    private static func network(_ text: String) -> ErrorText? {
        guard
            text.contains("-65570") || text.localizedCaseInsensitiveContains("PolicyDenied")
                || text.localizedCaseInsensitiveContains("local network")
        else { return nil }
        return ErrorText(
            title: "Local network access is off", message: "macOS does not let Nitpick reach devices on your network.",
            nextStep: localNetworkHint, isLocalNetwork: true)
    }
}
