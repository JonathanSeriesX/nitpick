#if DEBUG
    import AppKit
    import Calibration
    import LGControl
    import MeterKit
    import PatternLink
    import SwiftUI

    /// `-renderScreenshots <dir>`: renders the key screens with demo data to PNG (1440×900 @2x, dark), then exits.
    ///
    /// `ImageRenderer` draws AppKit-backed controls (buttons, pickers, text fields, tables, the split view) as placeholder
    /// images, so the views are hosted in an off-screen window and drawn with `cacheDisplay`, which needs no
    /// screen-recording permission. The sidebar is laid out in an `HStack` because the split view's sidebar material does
    /// not draw off screen.
    enum Screenshots {
        static let size = CGSize(width: 1440, height: 900)

        static func render(to requested: URL) async -> Int32 {
            do {
                let dir = writableDirectory(requested)
                let base = FileManager.default.temporaryDirectory.appendingPathComponent("NitpickShots-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: base) }
                guard let defaults = UserDefaults(suiteName: "NitpickShots-\(UUID().uuidString)") else { return 1 }
                let model = AppModel(base: base, defaults: defaults)
                await model.devices.setDemoMode(true)

                // Sessions with real results, produced instantly on a virtual clock.
                let rig = DemoRig()
                let sdr = try await DemoRun.execute(.movieSDR, rig: rig, store: model.store, history: model.history, quiet: true)
                let hdr = try await DemoRun.execute(.movieHDR10, rig: rig, store: model.store, history: model.history, quiet: true)
                try await DemoRun.execute(.gameSDR, rig: rig, store: model.store, history: model.history, quiet: true)
                try await DemoRun.execute(.dolbyVision(source: hdr.id), rig: rig, store: model.store, history: model.history, quiet: true)
                let failed = try await failedSession(model)
                model.reload()

                func shot(_ name: String, _ view: some View, width: CGFloat? = nil, light: Bool = false) async throws {
                    let url = dir.appendingPathComponent(name)
                    try await Snapshot.write(
                        view.environment(model).environment(\.snapshotMode, true), size: width == nil ? size : nil,
                        width: width ?? size.width, light: light, to: url)
                    print(url.path)
                }
                let root = RootView()

                model.selection = .devices
                try await shot("01-devices-demo.png", root)
                try await shot("02-new-session-sdr.png", sheet(over: root, NewSessionSheet()))
                var dv = NewSessionDraft(range: .dolbyVision)
                dv.sourceSessionID = hdr.id
                try await shot("03-new-session-dolby-vision.png", sheet(over: root, NewSessionSheet(draft: dv)))

                // The real UI path: AppModel.startRun on the demo devices (DemoClock, 40× real time).
                guard let uiRun = model.create(.movieSDR) else { return 1 }
                model.startRun(uiRun)
                try await waitFor("Pre-calibration") { (model.run?.stageIndex ?? 0) >= 3 && (model.run?.stageReadings ?? 0) >= 40 }
                try await shot("04-session-running.png", root)
                try await waitFor("the end of the run", seconds: 240) { model.run?.isRunning == false }
                check("UI run of Movie SDR completed", model.run?.outcome == .completed, "\(String(describing: model.run?.outcome))")
                await model.restore(uiRun)
                check("Restore TV settings", model.alert?.title == "TV settings restored", model.alert?.message ?? "no message")
                model.alert = nil
                if let done = model.session(uiRun) {
                    for kind in ExportKind.allCases {
                        let request = try ExportRequest(session: done, kind: kind)
                        check(
                            "Export \(kind.rawValue)", !request.file.data.isEmpty, "\(request.filename) · \(request.file.data.count) bytes")
                    }
                }
                guard let dvRun = model.create(.dolbyVision(source: hdr.id)) else { return 1 }
                model.startRun(dvRun)
                try await waitFor("the Dolby Vision prompt") { model.run?.prompt != nil }
                try await shot("04b-session-needs-user.png", root)
                model.confirmPrompt()
                try await waitFor("the end of the Dolby Vision run", seconds: 240) { model.run?.isRunning == false }
                check("UI run of Dolby Vision completed", model.run?.outcome == .completed, "\(String(describing: model.run?.outcome))")
                model.reload()

                model.selection = .session(sdr.id)
                try await shot("05-session-results-sdr.png", root)
                try await shot("05b-session-results-sdr-light.png", root, light: true)
                model.showInspector = true
                try await shot("05c-inspector.png", root)
                model.showInspector = false
                let sdrSaved = model.session(sdr.id) ?? sdr
                try await shot("06-session-results-sdr-full.png", SessionContent(session: sdrSaved).padding(24), width: 1190)
                if let hdrSaved = model.session(hdr.id), let result = hdrSaved.result {
                    try await shot(
                        "07-session-results-hdr10-before-full.png",
                        ResultsView(session: hdrSaved, result: result, phase: .before).padding(24), width: 1190)
                }

                model.selection = .session(failed)
                try await shot("08-session-failed.png", root)

                model.selection = .devices
                try await checkLGTV(model, shot: { try await shot($0, root) })
                try await checkVirtualMeter(model, shot: { try await shot($0, root) })

                await model.devices.tv.setPreviewState(kind: .real, phase: .failed, error: ErrorText(LGError.pairingDenied))
                await model.devices.meter.setPreviewState(kind: .usb, phase: .failed, error: ErrorText(MeterError.busy))
                await model.devices.pattern.setPreviewState(
                    kind: .real, phase: .waitingForUser, pinFor: "Living Room", error: ErrorText(PatternLinkError.authenticationFailed))
                model.devices.network.setPreviewDenied(true)
                model.selection = .devices
                try await shot("09-devices-errors.png", root)
                return failures == 0 ? 0 : 1
            } catch {
                print("screenshot rendering failed: \(error)")
                return 1
            }
        }

        /// The App Sandbox only lets the app write inside its container; elsewhere the images go to the container's temp folder.
        private static func writableDirectory(_ dir: URL) -> URL {
            let probe = dir.appendingPathComponent(".nitpick-probe")
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
                (try? Data().write(to: probe)) != nil
            {
                try? FileManager.default.removeItem(at: probe)
                return dir
            }
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("NitpickScreenshots")
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            print("note: the sandbox does not allow writing to \(dir.path); writing to \(fallback.path)")
            return fallback
        }

        private static func sheet(over root: some View, _ content: some View) -> some View {
            ZStack {
                root
                Color.black.opacity(0.35)
                content
                    .frame(width: 580, height: 700)
                    .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
                    .clipShape(.rect(cornerRadius: 12))
                    .shadow(radius: 24)
            }
        }

        private static var failures = 0

        /// The real LG path (LGTVController over SSAP) against `FakeWebOSServer` on 127.0.0.1: pairing prompt, capabilities,
        /// settings, snapshot, and the webOS 26 calibration block. Pairing keys stay in memory.
        private static func checkLGTV(_ model: AppModel, shot: (String) async throws -> Void) async throws {
            let tv = model.devices.tv
            let fake = FakeWebOSServer(configuration: .init(platform: .webOS25, pairing: .accept(after: .seconds(2))))
            let port = try await fake.start()
            defer { Task { await fake.stop() } }
            tv.credentials = InMemoryTVCredentialStore()
            tv.connectionOptions = LGTV.Options(
                connection: .init(port: port, allowInsecure: true), readbackDelay: .zero, calibrationSettleDelay: .zero)
            await tv.setPreviewState(kind: .real, phase: .idle, error: nil)
            let connecting = Task { await tv.connect(host: "127.0.0.1", id: nil) }
            try await waitFor("the pairing prompt") { tv.phase == .waitingForUser }
            try await shot("10-tv-pairing-prompt.png")
            await connecting.value
            check(
                "LG TV (fake webOS 25) paired and connected", tv.phase == .connected && tv.settings != nil,
                "\(tv.capabilities?.modelName ?? "-") · \(tv.release?.description ?? "-") · \(tv.settings?.values.count ?? 0) settings · \(tv.error?.message ?? "no error")"
            )
            await tv.takeSnapshot()
            check("Settings snapshot written", tv.snapshotURL != nil, tv.snapshotNote ?? tv.error?.message ?? "-")
            try await shot("11-tv-connected-webos25.png")

            await fake.setConfiguration(.init(platform: .webOS26, pairing: .accept(after: .milliseconds(300))))
            tv.credentials = InMemoryTVCredentialStore()
            await tv.connect(host: "127.0.0.1", id: nil)
            check(
                "LG TV (fake webOS 26) shows the calibration block",
                tv.phase == .connected ? tv.release?.blocksThirdPartyCalibration == true : tv.error != nil,
                "phase \(tv.phase.title) · \(tv.release?.description ?? "-") · API \(tv.capabilities?.supportsCalibrationAPI == true ? "available" : "unavailable") · \(tv.error.map { "\($0.title): \($0.message)" } ?? "no error")"
            )
            try await shot("12-tv-webos26.png")
            await tv.setKind(.simulated)
        }

        /// The real i1d3 driver on the virtual USB device: EEPROM read, a reading of the simulated panel, a CCMX correction.
        private static func checkVirtualMeter(_ model: AppModel, shot: (String) async throws -> Void) async throws {
            let meter = model.devices.meter
            await meter.setKind(.virtual)
            check(
                "Virtual i1d3 connected", meter.phase == .connected,
                "\(meter.info?.model ?? "-") · serial \(meter.info?.serialNumber ?? "-") · \(meter.diagnostics.count) diagnostics")
            model.devices.pattern.testLevel = 50
            await model.devices.pattern.showTestPattern()
            try await model.devices.clock.sleep(for: .seconds(3))
            if let m = meter.meter {
                let reading = try await m.measure(expectedLuminance: nil)
                check(
                    "Virtual i1d3 reads the 50 % window", reading.luminance > 1,
                    "Y \(Fmt.nits(reading.luminance)), xy \(Fmt.xy(reading.chromaticity))")
            }
            let ccmx = """
                CCMX
                DESCRIPTOR "Nitpick check WOLED"
                TECHNOLOGY "WOLED"
                COLOR_REP "XYZ"
                NUMBER_OF_FIELDS 3
                BEGIN_DATA_FORMAT
                XYZ_X XYZ_Y XYZ_Z
                END_DATA_FORMAT
                NUMBER_OF_SETS 3
                BEGIN_DATA
                1.02 0.01 0.0
                0.0 1.0 0.0
                0.0 0.0 0.97
                END_DATA
                """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("check.ccmx")
            try ccmx.write(to: url, atomically: true, encoding: .utf8)
            await meter.importCorrection(from: url)
            check(
                "CCMX correction parsed and applied", meter.correction?.name == "Nitpick check WOLED",
                meter.correction?.name ?? meter.error?.message ?? "-")
            try await shot("13-devices-virtual-meter.png")
            await meter.clearCorrection()
            await meter.setKind(.simulated)
        }

        private static func check(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            print("check: \(name): \(ok ? "OK" : "FAILED") (\(detail))")
        }

        private static func waitFor(_ what: String, seconds: Double = 120, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw CalibrationError.timeout("Waiting for \(what)") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        /// A Game HDR10 session that fails because Match Content is off on the (simulated) Apple TV.
        private static func failedSession(_ model: AppModel) async throws -> UUID {
            let rig = DemoRig()
            rig.source.matchingEnabled = false
            let saved = try await DemoRun.execute(.gameHDR10, rig: rig, store: model.store, history: model.history, quiet: true)
            return saved.id
        }
    }

    /// Draws a view in an off-screen window at @2x and writes a PNG.
    enum Snapshot {
        private final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var canBecomeKey: Bool { true }
        }

        /// `size` nil: the view's natural height at `width`.
        static func write(_ view: some View, size: CGSize?, width: CGFloat, light: Bool, to url: URL) async throws {
            let content = view.background(Color(nsColor: .windowBackgroundColor)).environment(\.controlActiveState, .key)
            let host = NSHostingView(
                rootView: AnyView(
                    size == nil ? AnyView(content.frame(width: width).fixedSize(horizontal: false, vertical: true)) : AnyView(content)))
            let target = size ?? CGSize(width: width, height: ceil(host.fittingSize.height))
            let window = KeyWindow(
                contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: target), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: target)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(900))
            host.layoutSubtreeIfNeeded()
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(target.width * 2), pixelsHigh: Int(target.height * 2), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw CocoaError(.fileWriteUnknown) }
            rep.size = target
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: url)
        }
    }
#endif
