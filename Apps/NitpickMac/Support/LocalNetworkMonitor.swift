import Foundation
import Network
import PatternLink

/// Detects a denied local network permission. `PatternLinkBrowser` does not expose its browser state, so this runs a
/// second `NWBrowser` for the same service and watches for kDNSServiceErr_PolicyDenied in its waiting state (TN3179).
@Observable
final class LocalNetworkMonitor {
    private(set) var denied = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: patternLinkServiceType, domain: nil), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool
            switch state {
            case .waiting(let error), .failed(let error):
                // -65570 = kDNSServiceErr_PolicyDenied
                if case .dns(let code) = error, code == -65570 { denied = true } else { return }
            case .ready: denied = false
            default: return
            }
            MainActor.assumeIsolated { self?.denied = denied }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    #if DEBUG
        func setPreviewDenied(_ denied: Bool) { self.denied = denied }
    #endif
}
