#if os(macOS)
    import Calibration
    import ColorScience
    import Foundation
    import Testing

    @testable import MeterKit

    typealias Fake = FakeI1D3Transport

    private func connected(
        _ configuration: Fake.Configuration = .init(noiseScale: 0), replyTimeout: Duration = .seconds(2)
    ) async throws -> (I1D3Meter, Fake) {
        let fake = Fake(configuration: configuration)
        let meter = I1D3Meter(transport: fake, replyTimeout: replyTimeout)
        try await meter.connect()
        return (meter, fake)
    }

    /// Largest per-component relative error.
    private func error(_ measured: XYZ, _ truth: XYZ) -> Double {
        max(abs(measured.X / truth.X - 1), abs(measured.Y / truth.Y - 1), abs(measured.Z / truth.Z - 1))
    }

    private func white(_ y: Double) -> XYZ { Chromaticity.d65.xyz(Y: y) }

    private func measurementCodes(_ fake: Fake, since start: Int) async -> [UInt8] {
        await fake.receivedCommands[start...].filter { $0 == 0x01 || $0 == 0x02 }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ v: Double) { lock.withLock { storage.append(v) } }
        var values: [Double] { lock.withLock { storage } }
    }

    @Suite struct I1D3MeterTests {
        @Test func connectReadsAndDecodesTheEEPROM() async throws {
            let fake = Fake(configuration: .init(noiseScale: 0))
            let meter = I1D3Meter(transport: fake)
            let progress = Recorder()
            try await meter.connect { progress.append($0) }

            let calibration = try #require(await meter.calibration)
            #expect(calibration.serialNumber == "NITPICK-FAKE-0001")
            #expect(calibration.hardwareVersion == "B-02")
            #expect(calibration.blackWords == [1_200, 900, 1_500])
            #expect(calibration.storedChecksum == calibration.computedChecksum)
            let curves = calibration.sensorCurves
            #expect(curves.rows.count == 3 && curves.rows.allSatisfy { $0.count == 351 })
            #expect(curves.startWavelength == 380 && curves.step == 1 && curves.wavelength(at: 350) == 730)
            #expect(calibration.ambientTransmission.count == 351)
            #expect(try calibration.defaultMatrix() != .identity)

            let commands = await fake.receivedCommands
            #expect(commands.filter { $0 == 0x08 }.count == 5)
            #expect(commands.filter { $0 == 0x12 }.count == 139)
            #expect(progress.values.last == 1)
            #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 < $1 })

            let info = await meter.info
            #expect(info.serialNumber == "NITPICK-FAKE-0001" && info.model == "Nitpick Virtual i1d3")
            #expect(info.firmware == "v2.28 31Oct26" && info.isSimulated)
            let diagnostics = await meter.diagnostics
            #expect(diagnostics["revision"] == "B" && diagnostics["firmwareNumber"] == "0x0228")
            #expect(diagnostics["unlockKey"] == "generic OEM")
        }

        @Test(arguments: [
            (Fake.Lock.retail, 1, "retail"), (.genericOEM, 2, "generic OEM"), (.colorMunki, 3, "ColorMunki"),
            (.unlocked, 0, "not needed"),
        ])
        func unlockTriesRetailThenOEMThenColorMunki(lock: Fake.Lock, attempts: Int, name: String) async throws {
            let (meter, fake) = try await connected(.init(lock: lock, noiseScale: 0))
            #expect(await fake.unlockAttempts == attempts)
            #expect(await meter.diagnostics["unlockKey"] == name)
        }

        @Test func unitLockedToAForeignKeyIsUnsupported() async {
            let fake = Fake(configuration: .init(lock: .foreignKey))
            await #expect(throws: MeterError.unsupportedVariant) { try await I1D3Meter(transport: fake).connect() }
            #expect(await fake.unlockAttempts == 3)
        }

        @Test func defaultMatrixReadsWithinOnePercent() async throws {
            let (meter, fake) = try await connected()
            let colours = [
                white(100), xyY(x: 0.45, y: 0.41, Y: 50).xyz, xyY(x: 0.25, y: 0.27, Y: 30).xyz,
                xyY(x: 0.33, y: 0.55, Y: 150).xyz, white(5),
            ]
            for truth in colours {
                await fake.setStimulus(.xyz(truth))
                let reading = try await meter.measure(expectedLuminance: truth.Y)
                #expect(error(reading.xyz, truth) < 0.01, "\(reading.xyz) vs \(truth)")
                #expect(reading.flags.isEmpty)
            }
        }

        @Test func ccssMatchesTheDisplayAtLeastAsWellAsTheDefault() async throws {
            let (meter, fake) = try await connected()
            func band(_ center: Double, _ width: Double, _ peak: Double) -> [Double] {
                (0..<351).map { peak * exp(-pow((380 + Double($0) - center) / width, 2) / 2) }
            }
            let primaries = [band(625, 12, 0.004), band(535, 15, 0.003), band(455, 10, 0.004)]
            func mix(_ w: [Double]) -> [Double] {
                (0..<351).map { i in (0..<3).reduce(0) { $0 + w[$1] * primaries[$1][i] } }
            }
            let ccss = ColorimeterCorrection(
                name: "Fake display",
                kind: .spectral(SpectralSamples(startWavelength: 380, step: 1, rows: primaries + [mix([1, 1, 1])])))
            let tests = [[0.8, 0.3, 0.1], [0.2, 0.9, 0.5], [1, 1, 1], [0.5, 0.1, 0.9]].map(mix)

            func worstError() async throws -> Double {
                var worst = 0.0
                for spectrum in tests {
                    await fake.setStimulus(.spectrum(spectrum))
                    let truth = CIEObserver.xyz(ofSpectrum: spectrum, startWavelength: 380, step: 1) * 683.002
                    worst = max(worst, error(try await meter.measure(expectedLuminance: nil).xyz, truth))
                }
                return worst
            }
            let defaultError = try await worstError()
            try await meter.setCorrection(ccss)
            let ccssError = try await worstError()
            #expect(ccssError <= defaultError && defaultError > 0.01)  // narrow-band primaries defeat the default fit
            #expect(ccssError < 0.005)
        }

        @Test func ccssMatrixIgnoresSampleScale() throws {
            let image = Fake.makeEEPROM(.init())
            let calibration = try I1D3Calibration(
                internalEEPROM: Data(image.internal), externalEEPROM: Data(image.external))
            let rows = (0..<4).map { k in (0..<351).map { 1 + sin(Double($0 * (k + 1)) / 40) } }
            func matrix(_ scale: Double) throws -> Matrix3 {
                try calibration.matrix(
                    for: ColorimeterCorrection(
                        name: "s",
                        kind: .spectral(
                            SpectralSamples(startWavelength: 380, step: 1, rows: rows.map { $0.map { $0 * scale } }))))
            }
            let a = try matrix(1)
            let b = try matrix(7)
            #expect(zip(a.m, b.m).allSatisfy { abs($0 - $1) <= 1e-9 * max(abs($0), 1) })
        }

        @Test func ccmxMultipliesTheDefaultMatrix() async throws {
            let (meter, fake) = try await connected()
            await fake.setStimulus(.xyz(white(100)))
            let plain = try await meter.measure(expectedLuminance: 100).xyz
            try await meter.setCorrection(
                ColorimeterCorrection(name: "c", kind: .matrix([1.1, 0, 0, 0, 1, 0, 0, 0, 0.9])))
            let corrected = try await meter.measure(expectedLuminance: 100).xyz
            #expect(abs(corrected.X / plain.X - 1.1) < 1e-9)
            #expect(abs(corrected.Y / plain.Y - 1) < 1e-9)
            #expect(abs(corrected.Z / plain.Z - 0.9) < 1e-9)
            try await meter.setCorrection(nil)
            #expect(try await meter.measure(expectedLuminance: 100).xyz == plain)
            await #expect(throws: MeterError.self) {
                try await meter.setCorrection(ColorimeterCorrection(name: "bad", kind: .matrix([1, 2])))
            }
        }

        @Test func darkPatchesSwitchToPeriodModeAndIntegrateLonger() async throws {
            let (meter, fake) = try await connected()
            await fake.setStimulus(.xyz(white(100)))
            var start = await fake.receivedCommands.count
            let bright = try await meter.measure(expectedLuminance: 100)
            #expect(await measurementCodes(fake, since: start) == [0x01])

            await fake.setStimulus(.xyz(white(0.5)))
            start = await fake.receivedCommands.count
            let dark = try await meter.measure(expectedLuminance: 0.5)
            #expect(await measurementCodes(fake, since: start) == [0x01, 0x02])
            let (brightTime, darkTime) = (try #require(bright.integrationTime), try #require(dark.integrationTime))
            #expect(darkTime > 1 && darkTime > brightTime && darkTime <= I1D3Meter.maximumIntegrationTime + 1e-6)
            #expect(error(dark.xyz, white(0.5)) < 0.01)
        }

        @Test func saturationIsFlagged() async throws {
            let (meter, fake) = try await connected()
            await fake.inject(.saturate)
            #expect(try await meter.measure(expectedLuminance: 5000).flags == ["saturated"])
        }

        @Test func trueBlackOnRevisionAIsBelowFloor() async throws {
            let (meter, fake) = try await connected(.init(revision: "A", noiseScale: 0))
            #expect(await meter.diagnostics["revision"] == "A")
            await fake.setStimulus(.xyz(.zero))
            let reading = try await meter.measure(expectedLuminance: 0)
            #expect(reading.xyz == .zero && reading.flags == ["belowFloor"] && reading.noiseEstimate == nil)
        }

        @Test func noiseEstimateMatchesObservedScatter() async throws {
            let (meter, fake) = try await connected(.init(noiseScale: 1, seed: 42))
            await fake.setStimulus(.xyz(white(50)))
            var ys: [Double] = []
            var estimates: [Double] = []
            for _ in 0..<40 {
                let r = try await meter.measure(expectedLuminance: 50)
                ys.append(r.luminance)
                estimates.append(try #require(r.noiseEstimate))
            }
            let mean = ys.reduce(0, +) / Double(ys.count)
            let sd = (ys.map { pow($0 - mean, 2) }.reduce(0, +) / Double(ys.count - 1)).squareRoot()
            let ratio = (sd / mean) / (estimates.reduce(0, +) / Double(estimates.count))
            #expect(ratio > 0.6 && ratio < 1.6, "observed/estimated σ = \(ratio)")
            #expect(abs(mean / 50 - 1) < 0.02)
        }

        @Test func cancellationReturnsPromptlyAndTheNextReadingWorks() async throws {
            let (meter, fake) = try await connected(.init(noiseScale: 0, timeScale: 1))
            await fake.setStimulus(.xyz(white(0.5)))
            let task = Task { try await meter.measure(expectedLuminance: 0.5) }  // ≈ 6 s of simulated integration
            try await Task.sleep(for: .milliseconds(100))
            let clock = ContinuousClock()
            let cancelled = clock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(cancelled.duration(to: clock.now) < .milliseconds(500))

            await fake.setStimulus(.xyz(white(100)))
            let reading = try await meter.measure(expectedLuminance: 100)
            #expect(error(reading.xyz, white(100)) < 0.01)
        }

        @Test func lostReplyTimesOutAndTheMeterRecovers() async throws {
            let (meter, fake) = try await connected(replyTimeout: .milliseconds(200))
            await fake.setStimulus(.xyz(white(100)))
            await fake.inject(.dropNextReply)
            await #expect(throws: MeterError.timeout) { try await meter.measure(expectedLuminance: 100) }
            #expect(error(try await meter.measure(expectedLuminance: 100).xyz, white(100)) < 0.01)
        }

        @Test func unplugDuringMeasurementThenReconnect() async throws {
            let (meter, fake) = try await connected()
            await fake.setStimulus(.xyz(white(100)))
            await fake.inject(.unplugDuringMeasurement)
            await #expect(throws: MeterError.disconnected) { try await meter.measure(expectedLuminance: 100) }
            await #expect(throws: MeterError.notConnected) { try await meter.measure(expectedLuminance: 100) }
            try await meter.connect()
            #expect(error(try await meter.measure(expectedLuminance: 100).xyz, white(100)) < 0.01)
        }

        @Test func busyMeterIsReported() async {
            let fake = Fake()
            await fake.inject(.busy)
            await #expect(throws: MeterError.busy) { try await I1D3Meter(transport: fake).connect() }
            #expect(MeterError.busy.errorDescription?.contains("Calibrite PROFILER") == true)
            #expect(MeterError.accessDenied.errorDescription?.contains("com.apple.security.device.usb") == true)
        }

        @Test func endToEndThroughTheMeterProtocol() async throws {
            let fake = Fake(configuration: .init(lock: .retail))
            let meter: any Meter = I1D3Meter(transport: fake)
            try await meter.connect()
            let info = await meter.info
            #expect(info.serialNumber == "NITPICK-FAKE-0001" && info.isSimulated && info.maximumLuminance > 1000)
            await fake.setStimulus(.xyz(white(200)))
            let reading = try await meter.measure(expectedLuminance: nil)
            #expect(abs(reading.luminance / 200 - 1) < 0.1)
            #expect(reading.integrationTime == 0.4)
            try await meter.setCorrection(nil)
            await meter.disconnect()
            await #expect(throws: MeterError.notConnected) { try await meter.measure(expectedLuminance: nil) }
        }
    }
#endif
