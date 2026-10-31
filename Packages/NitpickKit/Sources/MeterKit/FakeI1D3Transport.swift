#if os(macOS)
    import ColorScience
    import Foundation

    /// A deterministic simulated i1d3 that answers the read-only allowlist like the spec describes. Use it for tests, and
    /// as a "virtual meter" when no hardware is connected.
    ///
    /// Its sensor curves are scaled, slightly shifted CIE 1931 colour-matching functions (about 16 Hz per cd/m² in green,
    /// the order of magnitude of spec §7.1), so the fitted matrix is not the identity. Light comes from `setStimulus(_:)`.
    /// Counts carry Poisson-like noise (σ = `noiseScale` × √edges) from a seeded generator.
    public actor FakeI1D3Transport: HIDReportTransport {
        /// Which key unlocks the simulated unit.
        public enum Lock: Hashable, Sendable {
            case unlocked
            case retail
            case genericOEM
            case colorMunki
            /// Locked to a key the driver does not ship.
            case foreignKey
        }

        /// What the sensor sees.
        public enum Stimulus: Hashable, Sendable {
            /// Light with this XYZ (cd/m²), turned into sensor frequencies with the inverse of the unit's default matrix.
            case xyz(XYZ)
            /// Spectral radiance in W/(sr·m²·nm), 351 values at 380…730 nm (1 nm). Sensor frequencies are integrated on the
            /// same 5 nm grid ColorScience uses for CIE integrals, so CCSS fits over these spectra are exact.
            case spectrum([Double])
        }

        public enum Fault: Hashable, Sendable {
            /// `open()` fails as if another app held the meter.
            case busy
            /// The next command gets no reply.
            case dropNextReply
            /// The next measurement command unplugs the meter before it answers. `open()` works again afterwards.
            case unplugDuringMeasurement
            /// Every channel reads far above the 250 kHz sensor limit.
            case saturate
        }

        public struct Configuration: Sendable {
            public var lock: Lock
            /// "A" fails the `0x10` probe and returns 0 clocks for a dark period channel; "B" answers `0x10` and returns
            /// status `0x83` instead.
            public var revision: Character
            public var serialNumber: String
            /// Multiplies the √edges count noise; 0 makes readings exact.
            public var noiseScale: Double
            /// 1 replies after the simulated integration time, 0 replies at once.
            public var timeScale: Double
            public var seed: UInt64

            public init(
                lock: Lock = .genericOEM, revision: Character = "B", serialNumber: String = "NITPICK-FAKE-0001",
                noiseScale: Double = 1, timeScale: Double = 0, seed: UInt64 = 0x1D3
            ) {
                self.lock = lock
                self.revision = revision
                self.serialNumber = serialNumber
                self.noiseScale = noiseScale
                self.timeScale = timeScale
                self.seed = seed
            }
        }

        /// Seconds a period measurement waits for edges before giving up (spec §3.2: "about 10 s").
        static let noEdgeWindow = 10.0

        public nonisolated let identity: HIDDeviceIdentity
        public let configuration: Configuration
        /// Byte 0 of every command the device accepted, oldest first.
        public private(set) var receivedCommands: [UInt8] = []
        /// Number of `0x9A` unlock responses received.
        public private(set) var unlockAttempts = 0

        let internalEEPROM: [UInt8]
        let externalEEPROM: [UInt8]
        private let curvesPerWatt: [[Double]]  // Hz per W/nm, as the meter decodes them
        private let inverseMatrix: Matrix3
        private let blackHz: [Double]
        private let inbox = ReportInbox()
        private var rng: SplitMix64
        private var stimulus = Stimulus.xyz(.zero)
        private var faults: Set<Fault> = []
        private var isOpen = false
        private var locked = true
        private var challenge: [UInt8]?
        private var session = 0

        public init(configuration: Configuration = Configuration()) {
            self.configuration = configuration
            identity = HIDDeviceIdentity(
                id: 0xFA4E_1D30, product: "Nitpick Virtual i1d3", serialNumber: configuration.serialNumber)
            (internalEEPROM, externalEEPROM) = Self.makeEEPROM(configuration)
            // The image is built above from finite curves that span 3D, so decoding cannot fail.
            let calibration = try! I1D3Calibration(
                internalEEPROM: Data(internalEEPROM), externalEEPROM: Data(externalEEPROM))
            curvesPerWatt = calibration.sensorCurves.rows.map { $0.map { $0 * 1000 } }
            inverseMatrix = try! calibration.defaultMatrix().inverse!
            blackHz = calibration.blackOffsetHz
            rng = SplitMix64(state: configuration.seed)
        }

        public func setStimulus(_ stimulus: Stimulus) { self.stimulus = stimulus }
        public func inject(_ fault: Fault) { faults.insert(fault) }
        public func clear(_ fault: Fault) { faults.remove(fault) }

        // MARK: HIDReportTransport

        public func open() async throws {
            if faults.contains(.busy) { throw MeterError.busy }
            isOpen = true
            locked = configuration.lock != .unlocked  // a fresh plug-in starts locked
            challenge = nil
            session += 1
            await inbox.reopen()
        }

        public func close() async {
            isOpen = false
            session += 1
            await inbox.close(.disconnected)
        }

        public func sendOutputReport(_ data: Data) async throws {
            try I1D3Protocol.validateOutgoing(data)
            guard isOpen else { throw MeterError.notConnected }
            try await inbox.beginCommand()
            let request = [UInt8](data)
            receivedCommands.append(request[0])
            if faults.remove(.dropNextReply) != nil { return }
            if request[0] == 0x01 || request[0] == 0x02, faults.remove(.unplugDuringMeasurement) != nil {
                return await close()
            }
            let (reply, seconds) = respond(to: request)
            let delay = seconds * configuration.timeScale
            guard delay > 0 else { return await inbox.deliver(Data(reply)) }
            let current = session
            Task {
                try? await Task.sleep(for: .seconds(delay))
                if session == current { await inbox.deliver(Data(reply)) }
            }
        }

        public func nextInputReport(timeout: Duration) async throws -> Data {
            try await inbox.next(timeout: timeout)
        }

        // MARK: Device behaviour

        /// The reply to `r` and the simulated time the device needs for it.
        private func respond(to r: [UInt8]) -> (reply: [UInt8], seconds: Double) {
            var out = [UInt8](repeating: 0, count: I1D3Protocol.reportLength)
            out[1] = r[0]
            func put(_ text: String) { for (i, b) in text.utf8.prefix(60).enumerated() { out[2 + i] = b } }
            // Measurements and EEPROM reads before the unlock: refused (real behaviour UNCONFIRMED, spec §3.7).
            if locked, [0x01, 0x02, 0x08, 0x12].contains(r[0]) {
                out[0] = 0x01
                return (out, 0)
            }
            switch r[0] {
            case 0x00:
                switch r[1] {
                case 0x00: put("Nitpick Virtual i1d3 v2.28 31Oct26")
                case 0x01: out[2] = 1
                case 0x10: put("Nitpick Virtual i1d3")
                case 0x11: I1D3Protocol.put(UInt16(1), into: &out, at: 3)
                case 0x12: put("v2.28 ")
                case 0x13: put("31Oct26")
                case 0x20: (out[2], out[3]) = locked ? (0, 1) : (1, 0)
                case 0x31:
                    if configuration.revision == "B" {
                        I1D3Protocol.put(UInt16(0x0228), into: &out, at: 3)
                    } else {
                        put("v1.0")
                    }
                default: out[0] = 0x01
                }
            case 0x10:
                if configuration.revision == "B" { out[2] = 0x21 } else { out[0] = 0x01 }
            case 0x01:
                let seconds = Double(I1D3Protocol.u32(r, at: 1)) / I1D3Protocol.clockHz
                for (c, f) in frequencies().enumerated() {
                    let edges = 2 * f * seconds
                    let noisy = edges + configuration.noiseScale * edges.squareRoot() * gaussian()
                    // Counting starts in sync with the signal, so counts are biased down by 0…1 (spec §4.3).
                    I1D3Protocol.put(UInt32(clamping: Int(max(0, noisy).rounded(.down))), into: &out, at: 2 + 4 * c)
                }
                return (out, seconds)
            case 0x02:
                let f = frequencies()
                var longest = 0.0
                var missed = false
                for c in 0..<3 where r[7] & (1 << c) != 0 {
                    let edges = Double(I1D3Protocol.u16(r, at: 1 + 2 * c))
                    let seconds = f[c] > 0 ? edges / (2 * f[c]) : .infinity
                    guard edges > 0, seconds <= Self.noEdgeWindow else {
                        missed = true
                        continue
                    }
                    let noisy = seconds * max(0.01, 1 + configuration.noiseScale * gaussian() / edges.squareRoot())
                    I1D3Protocol.put(
                        UInt32(clamping: Int((noisy * I1D3Protocol.clockHz).rounded())), into: &out, at: 2 + 4 * c)
                    longest = max(longest, noisy)
                }
                if missed {
                    longest = Self.noEdgeWindow
                    if configuration.revision == "B" { out[0] = 0x83 }  // Rev. A leaves the channel at 0 clocks
                }
                return (out, longest)
            case 0x08:
                let (address, length) = (Int(r[1]), Int(r[2]))
                guard (1...I1D3Protocol.internalEEPROMChunk).contains(length), address + length <= internalEEPROM.count
                else {
                    out[0] = 0x01
                    break
                }
                out.replaceSubrange(4..<4 + length, with: internalEEPROM[address..<address + length])
            case 0x12:
                let (address, length) = (Int(r[1]) << 8 | Int(r[2]), Int(r[3]))
                guard (1...I1D3Protocol.externalEEPROMChunk).contains(length), address + length <= externalEEPROM.count
                else {
                    out[0] = 0x01
                    break
                }
                out.replaceSubrange(5..<5 + length, with: externalEEPROM[address..<address + length])
            case 0x94:
                out[1] = 0  // display position
            case 0x99:
                for i in 2..<out.count { out[i] = UInt8.random(in: 0...255, using: &rng) }
                challenge = out
            case 0x9A:
                unlockAttempts += 1
                if let key = unlockKey, let c = challenge,
                    I1D3Protocol.unlockResponse(challenge: c, key: key)[24..<40] == r[24..<40]
                {
                    locked = false
                    out[2] = 0x77
                }
                challenge = nil
            default:
                out[0] = 0x01
            }
            return (out, 0)
        }

        private var unlockKey: I1D3Protocol.UnlockKey? {
            let name: String? =
                switch configuration.lock {
                case .retail: "retail"
                case .genericOEM: "generic OEM"
                case .colorMunki: "ColorMunki"
                case .unlocked, .foreignKey: nil
                }
            return I1D3Protocol.unlockKeys.first { $0.name == name }
        }

        /// True sensor frequencies in Hz, including the black offset.
        private func frequencies() -> [Double] {
            if faults.contains(.saturate) { return [300_000, 300_000, 300_000] }
            let light: [Double]
            switch stimulus {
            case .xyz(let xyz):
                let rgb = inverseMatrix * RGB(r: xyz.X, g: xyz.Y, b: xyz.Z)
                light = rgb.components.map { max(0, $0) }
            case .spectrum(let s):
                light = curvesPerWatt.map { curve in
                    stride(from: 0, to: min(s.count, curve.count), by: 5).reduce(0) { $0 + s[$1] * curve[$1] * 5 }
                }
            }
            return zip(light, blackHz).map(+)
        }

        private func gaussian() -> Double {
            let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            let u2 = Double.random(in: 0..<1, using: &rng)
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }

        // MARK: EEPROM image

        static func makeEEPROM(_ configuration: Configuration) -> (internal: [UInt8], external: [UInt8]) {
            typealias L = I1D3Calibration.Layout
            var i = [UInt8](repeating: 0xFF, count: I1D3Protocol.internalEEPROMSize)
            for (offset, word) in zip(L.blackWords, [1_200, 900, 1_500] as [UInt32]) {
                I1D3Protocol.put(word, into: &i, at: offset)
            }
            func ascii(_ text: String, at offset: Int, length: Int) {
                let bytes = Array(text.utf8.prefix(length))
                i.replaceSubrange(
                    offset..<offset + length, with: bytes + Array(repeating: 0, count: length - bytes.count))
            }
            ascii(configuration.serialNumber, at: L.serial, length: L.serialLength)
            ascii("\(configuration.revision)-02", at: L.version, length: L.versionLength)

            var e = [UInt8](repeating: 0, count: I1D3Protocol.externalEEPROMSize)
            I1D3Protocol.put(UInt64(1_793_404_800), into: &e, at: L.calibrationDate)
            // Hz per W/nm; 16 × 683 makes green ≈ 16 Hz per cd/m². Shifts and gains keep the fit away from the identity.
            let k = 16 * 683.002
            let curves: [(Double) -> Double] = [
                { k * 1.02 * cmf(CIEObserver.xbar, $0 - 4) },
                { k * 0.97 * cmf(CIEObserver.ybar, $0 + 3) },
                { k * 1.05 * cmf(CIEObserver.zbar, $0 - 2) },
            ]
            func floats(_ values: [Double], at offset: Int) {
                for (n, v) in values.enumerated() {
                    I1D3Protocol.put(Float(v).bitPattern, into: &e, at: offset + 4 * n)
                }
            }
            let wavelengths = (0..<L.curveSamples).map { 380 + Double($0) }
            for (offset, curve) in zip(L.sensorCurves, curves) { floats(wavelengths.map(curve), at: offset) }
            floats(wavelengths.map { 0.02 + 0.03 * ($0 - 380) / 350 }, at: L.ambientTransmission)
            I1D3Protocol.put(e[L.checksumRange].reduce(0) { $0 &+ UInt16($1) }, into: &e, at: L.checksum)
            return (i, e)
        }

        /// Linear interpolation in a 380…780 nm, 5 nm CIE table; 0 outside.
        private static func cmf(_ table: [Double], _ nm: Double) -> Double {
            let x = (nm - 380) / 5
            guard x >= 0, x <= Double(table.count - 1) else { return 0 }
            let n = min(Int(x), table.count - 2)
            return table[n] + (table[n + 1] - table[n]) * (x - Double(n))
        }
    }

    /// Small seeded generator (SplitMix64) so simulated noise is reproducible.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
#endif
