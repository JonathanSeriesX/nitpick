#if DEBUG
    import AppKit
    import Calibration
    import ColorScience
    import Foundation

    /// DEBUG launch arguments for verification without a screen: `-demoRun <preset>`, `-renderScreenshots <dir>` and
    /// `-linkTest …` / `-linkTestToken …` (see `LinkTest`).
    enum Headless {
        /// Runs the requested job and exits the process; returns false when no job was requested.
        static func runIfRequested() -> Bool {
            let args = CommandLine.arguments
            func value(after flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            let job: @MainActor () async -> Int32
            if let preset = value(after: "-demoRun") {
                job = { await DemoRun.run(preset) }
            } else if let dir = value(after: "-renderScreenshots") {
                job = { await Screenshots.render(to: URL(fileURLWithPath: dir)) }
            } else if let i = args.firstIndex(of: "-linkTest"), i + 4 < args.count {
                job = { await LinkTest.run(host: args[i + 1], port: args[i + 2], pin: args[i + 3], name: args[i + 4]) }
            } else if let i = args.firstIndex(of: "-linkTestToken"), i + 2 < args.count {
                job = { await LinkTest.run(host: args[i + 1], port: args[i + 2], pin: nil, name: nil) }
            } else {
                return false
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task {
                let code = await job()
                fflush(stdout)
                exit(code)
            }
            app.run()
            return true
        }
    }

    /// A complete simulated setup on one virtual clock: whole sessions run without real waiting.
    struct DemoRig {
        let clock = VirtualClock()
        let panel: SimulatedPanel
        let tv: SimulatedTVController
        let source: SimulatedPatternSource
        let meter: SimulatedMeter

        init() {
            panel = SimulatedPanel(clock: clock)
            tv = SimulatedTVController(panel: panel)
            source = SimulatedPatternSource(panel: panel)
            meter = SimulatedMeter(panel: panel)
        }

        var devices: WorkflowRunner.Devices { (meter, source, tv) }
    }

    /// `-demoRun <preset>`: one full workflow on the simulated devices, summary on stdout, exit 0 when it completes.
    enum DemoRun {
        static let presets: [String: SessionProfile] = [
            "movieSDR": .movieSDR, "gameSDR": .gameSDR, "movieHDR10": .movieHDR10, "gameHDR10": .gameHDR10,
        ]

        static func run(_ name: String) async -> Int32 {
            guard presets[name] != nil || name == "dolbyVision" else {
                print("usage: Nitpick -demoRun movieSDR|gameSDR|movieHDR10|gameHDR10|dolbyVision")
                return 64
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NitpickDemoRun-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                let store = try SessionStore(directory: dir.appendingPathComponent("Sessions"))
                let history = try MeasurementHistory(directory: dir.appendingPathComponent("Measurements"))
                let rig = DemoRig()
                var profile = presets[name] ?? .movieHDR10
                if name == "dolbyVision" {
                    print("Prerequisite: a Movie HDR10 session on the same simulated panel")
                    let source = try await execute(.movieHDR10, rig: rig, store: store, history: history)
                    guard source.status == .completed else { return 1 }
                    profile = .dolbyVision(source: source.id)
                }
                let session = try await execute(profile, rig: rig, store: store, history: history)
                return session.status == .completed ? 0 : 1
            } catch {
                print("error: \(ErrorText(error).message)")
                return 1
            }
        }

        /// Runs `profile` to its end on `rig`, prints progress and the summary unless `quiet`, returns the saved session.
        @discardableResult
        static func execute(
            _ profile: SessionProfile, rig: DemoRig, store: SessionStore, history: MeasurementHistory, quiet: Bool = false
        ) async throws -> CalibrationSession {
            func say(_ text: String) { if !quiet { print(text) } }
            let runner = WorkflowRunner(store: store, history: history)
            let session = CalibrationSession(profile: profile)
            let wallStart = Date()
            let virtualStart = rig.clock.now
            var readings = 0
            var failure: String?
            say("== \(profile.name): \(PictureModes.name(profile.pictureMode)), \(session.targetDescription)")
            for try await event in runner.run(profile: profile, devices: rig.devices, session: session, sleeper: rig.clock) {
                switch event {
                case .stage(let name, let index, let count):
                    say("stage \(index + 1)/\(count) \(name)")
                case .measurement: readings += 1
                case .warning(let text): say("   warning: \(text)")
                case .needsUser(let prompt):
                    say("   needs user: \(prompt)")
                    say("   (simulating the user choosing Dolby Vision on the Apple TV)")
                    try rig.source.simulateUserSelectsOutput(.dolbyVision)
                    runner.confirmUser()
                case .failed(let message):
                    failure = message
                    say("FAILED: \(message)")
                case .cancelled: say("CANCELLED")
                default: break
                }
            }
            if let failure { store.recordFailure(failure, for: session.id) }
            let saved = try store.load(id: session.id)
            guard let r = saved.result else {
                say("RESULT \(profile.name): \(saved.status.title)")
                return saved
            }
            let virtual = Fmt.elapsed(rig.clock.now.timeIntervalSince(virtualStart))
            let wall = Fmt.num(Date().timeIntervalSince(wallStart), 1)
            say(
                "RESULT \(profile.name): \(saved.status.title), tolerances \(r.passed ? "PASS" : "FAIL") · \(readings) readings · "
                    + "\(r.adjustments.count) adjustments · \(virtual) virtual · \(wall) s wall")
            let stages = ["Connect", "Signal path", "Settings snapshot", "Pre-calibration", "Adjust", "Post-calibration", "Verification"]
            say(
                "  stage times:  "
                    + stages.compactMap { name in r.durations[name].map { "\(name) \(Fmt.elapsed($0))" } }.joined(separator: ", "))
            say("  before:       \(Fmt.line(r.before))")
            say("  after:        \(Fmt.line(r.after))")
            let v = r.verification.summary
            say("  verification: avg \(Fmt.num(v.averageDeltaE)) p95 \(Fmt.num(v.p95DeltaE)) max \(Fmt.num(v.maxDeltaE))")
            if !r.lutsUploaded.isEmpty { say("  uploads:      \(r.lutsUploaded.joined(separator: ", "))") }
            if let tone = r.toneAnalysis {
                say(
                    "  tone:         peak \(Fmt.nits(tone.peakLuminance)), knee \(Fmt.nits(tone.kneeLuminance)), proposed \(tone.proposed.displayLuminance)/\(tone.proposed.masteringPeak)/\(tone.proposed.rolloffPoint) %"
                )
            }
            if let dv = saved.dolbyConfig {
                say(
                    "  dolby vision: white \(Fmt.nits(dv.whiteLevel)) \(Fmt.xy(dv.white)), black \(Fmt.num(dv.blackLevel, 4)), gamma \(Fmt.num(dv.gamma, 1))"
                )
            }
            for failure in r.failures { say("  out of tolerance: \(failure)") }
            return saved
        }
    }
#endif
