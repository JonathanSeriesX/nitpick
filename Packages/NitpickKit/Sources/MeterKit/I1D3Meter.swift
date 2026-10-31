#if os(macOS)
    import Calibration
    import ColorScience
    import Foundation

    /// An X-Rite i1d3-family colorimeter (Calibrite Display Plus HL, Display Pro HL, i1Display Pro …) over any
    /// `HIDReportTransport`.
    ///
    /// `connect()` opens the device, reads its identity, unlocks it with the shipped keys, reads both EEPROMs and fits the
    /// sensor→XYZ matrix. `measure(expectedLuminance:)` reads frequency mode first and switches dark channels to period
    /// mode, within a 6 s budget (spec §4.5, §7.1).
    public actor I1D3Meter: Meter {
        /// Above this sensor frequency a reading is flagged "saturated" (spec §4.3; UNCONFIRMED for HL sensors).
        public static let saturationHz = 250_000.0
        /// Total integration budget per reading (spec §4.5).
        public static let maximumIntegrationTime = 6.0
        /// Edges per channel a reading aims for (100 sensor cycles, spec §4.5).
        static let targetEdges = 200.0
        /// Fewer edges than this on any channel flags the reading "belowFloor" (σ > 22 % by the noise model).
        static let floorEdges = 20.0
        /// A period measurement waits about this long for edges before it gives up (spec §3.2).
        static let noEdgeWindow = 10.0

        public private(set) var info: MeterInfo
        /// Facts for the hardware checklist in spec §6.6: product name and type, firmware, revision, unlock key, black
        /// words, checksum. Values are display strings.
        public private(set) var diagnostics: [String: String] = [:]
        public private(set) var calibration: I1D3Calibration?

        private let transport: any HIDReportTransport
        private let replyTimeout: Duration
        private var isOpen = false
        private var correction: ColorimeterCorrection?
        private var matrix: Matrix3?
        /// Set after a failed or cancelled command: drain one stale reply (until this time) before the next command.
        private var staleReplyDeadline: ContinuousClock.Instant?

        /// - Parameter replyTimeout: wait for an ordinary reply; measurement waits add their integration time to it.
        public init(transport: any HIDReportTransport, replyTimeout: Duration = .seconds(2)) {
            self.transport = transport
            self.replyTimeout = replyTimeout
            info = MeterInfo(
                model: transport.identity.product ?? "i1d3", serialNumber: transport.identity.serialNumber ?? "",
                maximumLuminance: 0, isSimulated: transport is FakeI1D3Transport)
        }

        public func connect() async throws { try await connect(progress: { _ in }) }

        /// Connects and reports EEPROM read progress from 0 to 1.
        public func connect(progress: @Sendable (Double) -> Void) async throws {
            if isOpen { await disconnect() }
            try await transport.open()
            isOpen = true
            staleReplyDeadline = nil
            do {
                try await initialize(progress: progress)
            } catch {
                await disconnect()
                throw error
            }
        }

        public func disconnect() async {
            isOpen = false
            await transport.close()
        }

        /// Switches the matrix: nil restores the default (MIbLSr) matrix, a CCMX multiplies it, a CCSS replaces it.
        public func setCorrection(_ correction: ColorimeterCorrection?) async throws {
            if let calibration { matrix = try calibration.matrix(for: correction) }
            self.correction = correction
        }

        /// One reading. `expectedLuminance` (cd/m²) picks the first integration time; nil means 0.4 s.
        ///
        /// Flags: "saturated" when a channel exceeds `saturationHz`; "belowFloor" when a channel ended with fewer than 20
        /// edges or found none, so the reading rests on too few sensor transitions (spec §7.5). `noiseEstimate` is the
        /// relative 1σ of Y from a shot-noise model: each channel's relative σ is 1/√edges.
        public func measure(expectedLuminance: Double?) async throws -> MeterReading {
            guard isOpen, let matrix, let calibration else { throw MeterError.notConnected }
            let diffuser = try await transact(.getDiffuserPosition)
            guard I1D3Protocol.diffuserPosition(diffuser) == 0 else { throw MeterError.diffuserOverSensor }

            // 1. Frequency mode over a time picked from the expected luminance.
            var (hz, edges, used) = try await measureFrequency(seconds: Self.integrationTime(for: expectedLuminance))
            var sawNoEdges = false
            let saturated = hz.contains { $0 > Self.saturationHz }

            // 2. Period mode for channels with light but too few edges, sized to the remaining budget.
            let remaining = Self.maximumIntegrationTime - used
            let weak = (0..<3).filter { edges[$0] > 0 && edges[$0] < Self.targetEdges }
            if !saturated, !weak.isEmpty, remaining > 0 {
                var request = [UInt16](repeating: 2, count: 3)
                for c in weak {
                    let wanted = min(Self.targetEdges, 2 * hz[c] * remaining * 0.9)  // 10 % margin for the estimate
                    request[c] = UInt16(min(65_534, max(2, Int(wanted / 2) * 2)))
                }
                let period = try await measurePeriod(edges: request, channels: weak)
                used += period.seconds
                for c in weak {
                    if let f = period.hz[c] {
                        hz[c] = f
                        edges[c] = Double(request[c])
                    } else {
                        sawNoEdges = true  // keep the frequency-mode estimate
                    }
                }
            }

            let signal = zip(hz, calibration.blackOffsetHz).map { max(0, $0 - $1) }
            let rgb = matrix * RGB(r: signal[0], g: signal[1], b: signal[2])
            let xyz = XYZ(X: rgb.r, Y: rgb.g, Z: rgb.b)
            let varianceY = (0..<3).reduce(0.0) { sum, c in
                edges[c] > 0 ? sum + pow(matrix[1, c] * signal[c], 2) / edges[c] : sum
            }
            var flags: [String] = []
            if saturated { flags.append("saturated") }
            if sawNoEdges || edges.contains(where: { $0 < Self.floorEdges }) { flags.append("belowFloor") }
            return MeterReading(
                xyz: xyz, integrationTime: used, noiseEstimate: xyz.Y > 0 ? varianceY.squareRoot() / xyz.Y : nil,
                flags: flags)
        }

        /// First integration time from the expected luminance, after the scale in spec §7.1 (≈ 16 Hz per cd/m²,
        /// UNCONFIRMED for HL): bright patches get ≥ 100 cycles in 0.2 s, dim ones get up to 1 s before period mode.
        static func integrationTime(for expectedLuminance: Double?) -> Double {
            guard let l = expectedLuminance else { return 0.4 }
            return l >= 100 ? 0.2 : l >= 10 ? 0.4 : 1.0
        }

        // MARK: Connection

        private func initialize(progress: @Sendable (Double) -> Void) async throws {
            var d: [String: String] = ["transport": transport.identity.description]
            guard I1D3Protocol.isStatusOK(try await transact(.getStatus)) else {
                throw MeterError.malformedReply("device status not OK")
            }
            d["info"] = I1D3Protocol.string(try await transact(.getInfo))
            let name = I1D3Protocol.string(try await transact(.getProductName), maxLength: 31)
            d["productName"] = name
            d["productType"] = String(format: "0x%04X", I1D3Protocol.u16(try await transact(.getProductType), at: 3))
            let firmware = I1D3Protocol.string(try await transact(.getFirmwareVersion))
            d["firmwareVersion"] = firmware
            // Rev. B probe (spec §3.4): 0x10 answers only on Rev. B.
            do {
                let hardware = try await transact(.getHardwareInfo, timeout: .milliseconds(500))
                d["revision"] = "B"
                d["hardwareInfo"] = String(format: "0x%02X", hardware[2])
                let number = I1D3Protocol.u16(try await transact(.getFirmwareNumber), at: 3)
                d["firmwareNumber"] = String(format: "0x%04X", number)
            } catch let error as MeterError where error != .disconnected {
                d["revision"] = "A"
            }
            let date = I1D3Protocol.string(try await transact(.getFirmwareDate))
            d["firmwareDate"] = date
            d["unlockKey"] = try await I1D3Protocol.isLocked(transact(.getLockStatus)) ? unlock().name : "not needed"

            let total = Double(I1D3Protocol.internalEEPROMSize + I1D3Protocol.externalEEPROMSize)
            var done = 0
            let internalEEPROM = try await readEEPROM(external: false) {
                done += $0
                progress(Double(done) / total)
            }
            let externalEEPROM = try await readEEPROM(external: true) {
                done += $0
                progress(Double(done) / total)
            }
            let calibration = try I1D3Calibration(internalEEPROM: internalEEPROM, externalEEPROM: externalEEPROM)
            let defaultMatrix = try calibration.defaultMatrix()
            matrix = try calibration.matrix(for: correction)
            self.calibration = calibration
            d["hardwareVersion"] = calibration.hardwareVersion
            d["blackWords"] = calibration.blackWords.map { String(format: "0x%08X", $0) }.joined(separator: " ")
            d["checksum"] = String(
                format: "stored 0x%04X computed 0x%04X", calibration.storedChecksum, calibration.computedChecksum)
            diagnostics = d
            info = MeterInfo(
                model: name, serialNumber: calibration.serialNumber, firmware: "\(firmware) \(date)",
                maximumLuminance: Self.saturationLuminance(defaultMatrix), isSimulated: info.isSimulated)
        }

        /// Tries the shipped keys in order until the device reports unlocked (spec §3.5).
        private func unlock() async throws -> I1D3Protocol.UnlockKey {
            for key in I1D3Protocol.unlockKeys {
                let challenge = try await transact(.getUnlockChallenge)
                let accepted: Bool
                do {
                    accepted = I1D3Protocol.unlockAccepted(
                        try await transact(.sendUnlockResponse(challenge: challenge, key: key)))
                } catch MeterError.deviceStatus {
                    accepted = false  // how a unit rejects a key is UNCONFIRMED; an error status counts as a refusal
                }
                if accepted, try await !I1D3Protocol.isLocked(transact(.getLockStatus)) {
                    return key
                }
            }
            throw MeterError.unsupportedVariant
        }

        private func readEEPROM(external: Bool, progress: (Int) -> Void) async throws -> Data {
            let size = external ? I1D3Protocol.externalEEPROMSize : I1D3Protocol.internalEEPROMSize
            let chunk = external ? I1D3Protocol.externalEEPROMChunk : I1D3Protocol.internalEEPROMChunk
            let offset = I1D3Protocol.eepromDataOffset(external: external)
            var data = Data(capacity: size)
            for (address, length) in I1D3Protocol.chunks(total: size, maxLength: chunk) {
                let command: I1D3Protocol.Command =
                    external
                    ? .readExternalEEPROM(address: UInt16(address), length: UInt8(length))
                    : .readInternalEEPROM(address: UInt8(address), length: UInt8(length))
                data.append(contentsOf: try await transact(command)[offset..<offset + length])
                progress(length)
            }
            return data
        }

        /// Luminance of a D65 white at which the busiest channel reaches `saturationHz`.
        static func saturationLuminance(_ matrix: Matrix3) -> Double {
            guard let hzPerNit = matrix.inverse.map({ $0 * Chromaticity.d65.xyz(Y: 1) }) else { return 0 }
            let busiest = max(hzPerNit.X, hzPerNit.Y, hzPerNit.Z)
            return busiest > 0 ? saturationHz / busiest : 0
        }

        // MARK: Measurements

        /// Hz per channel, the edges each estimate rests on, and the integration time actually used (spec §4.3).
        private func measureFrequency(seconds: Double) async throws -> (hz: [Double], edges: [Double], seconds: Double) {
            let clocks = UInt32((seconds * I1D3Protocol.clockHz).rounded())
            let t = Double(clocks) / I1D3Protocol.clockHz
            let reply = try await transact(.measureFrequency(clocks: clocks), timeout: .seconds(t) + replyTimeout)
            let counts = I1D3Protocol.channelCounts(reply).map(Double.init)
            // Counts are biased down by 0…1 when every channel saw light.
            let bias = counts.allSatisfy { $0 > 0 } ? 0.5 : 0
            return (counts.map { 0.5 * ($0 + bias) / t }, counts, t)
        }

        /// Hz per channel (nil = no edges in the device's window, or status 0x83) and the time it took.
        private func measurePeriod(edges: [UInt16], channels: [Int]) async throws -> (hz: [Double?], seconds: Double) {
            let mask = channels.reduce(UInt8(0)) { $0 | 1 << $1 }
            let clocks: [UInt32]
            do {
                let reply = try await transact(
                    .measurePeriod(edges: edges, channels: mask), timeout: .seconds(Self.noEdgeWindow) + replyTimeout)
                clocks = I1D3Protocol.channelCounts(reply)
            } catch MeterError.deviceStatus(0x83) {
                return ([nil, nil, nil], Self.noEdgeWindow)  // Rev. B: no transitions in the window
            }
            let hz = (0..<3).map { c -> Double? in
                channels.contains(c) && clocks[c] > 0
                    ? 0.5 * Double(edges[c]) * I1D3Protocol.clockHz / Double(clocks[c]) : nil
            }
            let seconds =
                channels.contains { clocks[$0] == 0 }
                ? Self.noEdgeWindow : Double(channels.map { clocks[$0] }.max() ?? 0) / I1D3Protocol.clockHz
            return (hz, seconds)
        }

        /// Sends one command and returns its validated reply. Honours cancellation; resynchronizes after failures (§3.1).
        private func transact(_ command: I1D3Protocol.Command, timeout: Duration? = nil) async throws -> [UInt8] {
            guard isOpen else { throw MeterError.notConnected }
            try Task.checkCancellation()
            if let deadline = staleReplyDeadline {
                staleReplyDeadline = nil
                _ = try? await transport.nextInputReport(
                    timeout: max(.milliseconds(200), ContinuousClock.now.duration(to: deadline)))
                try Task.checkCancellation()
            }
            let limit = timeout ?? replyTimeout
            do {
                try await transport.sendOutputReport(command.report)
                return try I1D3Protocol.validate(try await transport.nextInputReport(timeout: limit), for: command)
            } catch MeterError.deviceStatus(0x83) {
                throw MeterError.deviceStatus(0x83)  // an ordinary "no light" answer: nothing to resynchronize
            } catch MeterError.operationInProgress {
                throw MeterError.operationInProgress  // nothing was sent
            } catch MeterError.disconnected {
                await disconnect()
                throw MeterError.disconnected
            } catch is CancellationError {
                // The device still answers when its integration ends; drain that reply before the next command.
                staleReplyDeadline = .now + limit
                throw CancellationError()
            } catch {
                staleReplyDeadline = .now + .milliseconds(200)
                throw error
            }
        }
    }
#endif
