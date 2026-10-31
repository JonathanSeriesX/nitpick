#if DEBUG
    import Calibration
    import ColorScience
    import Foundation
    import PatternLink

    /// `-linkTest <host> <port> <pin> <name>`: pairs with a real Apple TV and drives it end to end through `PatternDevice`,
    /// the layer the Devices screen calls, with an in-memory credential store (nothing reaches the login Keychain).
    /// `-linkTestToken <host> <port>`: reconnects with the pairing the last `-linkTest` saved (for example after the TV
    /// app restarted), then deletes it. `-linkTestHold <s>` pauses after the SDR patch and after blank, for screenshots.
    enum LinkTest {
        /// The pairing between runs, in the app's own temporary folder; only `-linkTestToken` reads it.
        static let savedPairing = FileManager.default.temporaryDirectory.appendingPathComponent("NitpickLinkTest.json")
        static let suite = "NitpickLinkTest"

        struct Pairing: Codable {
            var name: String
            var clientID: String
            var deviceID: UUID
            var token: Data
        }

        struct Failure: Error { let text: String }

        static func run(host: String, port: String, pin: String?, name: String?) async -> Int32 {
            let start = ContinuousClock.now
            func say(_ text: String) {
                print(String(format: "%6.2f s  ", (ContinuousClock.now - start) / .seconds(1)) + text)
                fflush(stdout)
            }
            let hold = UserDefaults.standard.double(forKey: "linkTestHold")
            func holdForScreenshot(_ what: String) async {
                guard hold > 0 else { return }
                say("HOLD \(what) for \(hold) s")
                try? await Task.sleep(for: .seconds(hold))
            }

            // Throwaway defaults: the client id and device id mapping of this run only.
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
            let store = InMemoryCredentialStore()
            var serviceName = name ?? ""
            if pin == nil {
                let data = try? Data(contentsOf: savedPairing)
                try? FileManager.default.removeItem(at: savedPairing)
                guard let data,
                    let pairing = try? JSONDecoder().decode(Pairing.self, from: data)
                else {
                    say("FAILED: no saved pairing at \(savedPairing.path); run -linkTest first")
                    return 1
                }
                defaults.set(pairing.clientID, forKey: "pattern.clientID")
                defaults.set(pairing.deviceID.uuidString, forKey: "pattern.deviceID.\(host):\(port)")
                store.setToken(pairing.token, for: pairing.deviceID)
                serviceName = pairing.name
                say("loaded the saved pairing: client \(pairing.clientID), Apple TV \(pairing.deviceID)")
            }

            let device = PatternDevice(panel: SimulatedPanel(clock: VirtualClock()), defaults: defaults, credentials: store)
            device.manualHost = host
            device.manualPort = port
            device.manualName = serviceName
            func check(_ what: String) throws {
                guard let e = device.error else { return }
                throw Failure(text: "\(what): \(e.title). \(e.message)" + (e.nextStep.map { " Next step: \($0)" } ?? ""))
            }
            func source() throws -> any PatternSource {
                guard let source = device.source else { throw Failure(text: "no pattern source (phase \(device.phase))") }
                return source
            }
            func mode(_ range: DynamicRange) async throws -> DisplayModeState {
                let source = try source()
                do { return try await source.setDisplayMode(DisplayModeRequest(dynamicRange: range)) } catch {
                    let e = ErrorText(error)
                    throw Failure(text: "\(range.rawValue) display mode: \(e.title). \(e.message)")
                }
            }
            func describe(_ s: DisplayModeState) -> String {
                "switching \(s.switching), matching \(s.matchingEnabled), EDR headroom "
                    + "\(s.currentEDRHeadroom.map { "\($0)" } ?? "–")/\(s.potentialEDRHeadroom.map { "\($0)" } ?? "–"), "
                    + "note: \(s.note ?? "none")"
            }
            func patch(level: Double, hdr: Bool) async throws -> String {
                device.testLevel = level
                device.testWindow = 0.10
                device.testHDR = hdr
                let ack = await device.showTestPattern()
                try check("show")
                guard let ack else { throw Failure(text: "show returned no ack") }
                let format: SignalFormat = hdr ? .hdr10 : .sdr
                let expected = SignalRGB.gray(level / 100).codes(in: format)
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return "ack sequence \(ack.sequence), enqueuedAt \(iso.string(from: ack.enqueuedAt)) "
                    + "(\(Int(Date().timeIntervalSince(ack.enqueuedAt) * 1000)) ms ago), "
                    + "centerCodes \(ack.centerCodes.map { "\($0)" } ?? "nil") (expected [\(expected.r), \(expected.g), \(expected.b)])"
            }

            var pairing: Pairing?
            do {
                if let pin {
                    await device.selectManual()
                    try check("add Apple TV")
                    guard device.pinTarget != nil else { throw Failure(text: "expected a PIN prompt, phase \(device.phase)") }
                    say("1 add \"\(serviceName)\" at \(host):\(port): no stored token, PIN requested")

                    device.pin = pin
                    await device.submitPIN()
                    try check("pair")
                    guard device.phase == .connected,
                        let id = defaults.string(forKey: "pattern.deviceID.\(host):\(port)").flatMap(UUID.init(uuidString:)),
                        let token = store.token(for: id)
                    else { throw Failure(text: "pairing left phase \(device.phase) without a stored token") }
                    say(
                        "2 PIN session → pair → token session: Apple TV id \(id), token \(token.count) bytes in the in-memory store"
                    )
                    pairing = Pairing(
                        name: serviceName, clientID: defaults.string(forKey: "pattern.clientID") ?? "", deviceID: id, token: token)

                    await device.disconnect()
                    say("3 disconnected: phase \(device.phase), source \(device.source == nil ? "nil" : "set")")
                }

                await device.selectManual()
                try check("reconnect with token")
                guard device.phase == .connected, let caps = device.capabilities else {
                    throw Failure(text: "reconnect left phase \(device.phase)")
                }
                await device.ping()
                try check("ping")
                let d = device.diagnostics
                say(
                    "4 reconnected with the stored token: \(caps.deviceName), \(caps.model), tvOS \(caps.systemVersion), "
                        + "protocol \(caps.protocolVersion), frame \(caps.frameWidth)×\(caps.frameHeight); identity \(d.identity ?? "?"), "
                        + "cipher 0x\(String(d.cipherSuite ?? 0, radix: 16, uppercase: true)), "
                        + "ping \(d.lastRoundTrip.map { "\($0.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))" } ?? "?")"
                )

                say("5 SDR display mode: \(describe(try await mode(.sdr)))")
                say("6 SDR 10 % window grey 50 %: \(try await patch(level: 50, hdr: false))")
                await holdForScreenshot("SDR patch")

                if pin != nil {
                    say("7 HDR10 display mode: \(describe(try await mode(.hdr10)))")
                    say("8 HDR10 10 % window 100 nits, p3D65_1000: \(try await patch(level: PQ.inverseEOTF(100) * 100, hdr: true))")
                }

                await device.blank()
                try check("blank")
                say("9 blank sent")
                await holdForScreenshot("blank")

                await device.disconnect()
                say("10 disconnected: phase \(device.phase)")
                if let pairing {
                    try JSONEncoder().encode(pairing).write(to: savedPairing, options: .atomic)
                    say("saved the pairing for -linkTestToken at \(savedPairing.path)")
                }
                return 0
            } catch {
                say("FAILED: \((error as? Failure)?.text ?? "\(error)")")
                await device.disconnect()
                return 1
            }
        }
    }
#endif
