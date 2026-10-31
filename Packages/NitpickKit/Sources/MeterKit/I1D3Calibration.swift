#if os(macOS)
    import ColorScience
    import Foundation

    /// Per-unit calibration decoded from the i1d3's internal (256 B) and external (8 KB) EEPROMs (spec §4.1, §4.2),
    /// and the sensor-to-XYZ matrices derived from it (spec §4.4, §5).
    public struct I1D3Calibration: Hashable, Sendable {
        /// 683.002 lm/W expressed per mW: XYZ (cd/m²) = 0.683002 × Σ s(mW/(sr·m²·nm)) · cmf. ColorScience's CIE integrals
        /// omit this constant and the sensor curves are in Hz per mW/nm, so every fitted matrix is scaled by it.
        public static let lumensPerMilliwatt = 0.683002

        /// Internal 0x10, 20 ASCII characters, not always NUL-terminated. Examples: `I1-11.A-01.100999.02`.
        public var serialNumber: String
        /// Internal 0x2C, for example `A-01`, `B-02`. The first letter is the hardware revision.
        public var hardwareVersion: String
        /// Raw black-offset words for R, G, B (internal 0x04, 0x08, 0x0C, u32 LE); `0xFFFFFFFF` ("not set") decodes to 0.
        /// Units UNCONFIRMED (spec §4.1): ArgyllCMS reads them as word / 6 000 000 Hz, openI1D3 as raw frequency-mode
        /// counts. `blackOffsetHz` uses the Hz reading, per channel. Compare dark readings on hardware before trusting it.
        public var blackWords: [UInt32]
        /// External 0x001E, u64 LE. Encoding UNCONFIRMED; kept raw for logs.
        public var calibrationDateRaw: UInt64
        /// External 0x0002, u16 LE. For `A-01` units it must equal `computedChecksum`; later units often differ (spec §4.2).
        public var storedChecksum: UInt16
        /// Sum of external bytes 0x0004…0x1799, mod 2^16.
        public var computedChecksum: UInt16
        /// R, G, B sensor sensitivities in Hz per mW/nm (EEPROM values ÷ 1000), 380…730 nm at 1 nm.
        public var sensorCurves: SpectralSamples
        /// Ambient diffuser transmission (external 0x10BC), unitless, 380…730 nm at 1 nm. Ambient mode is not implemented.
        public var ambientTransmission: [Double]

        /// EEPROM offsets (spec §4.1, §4.2).
        enum Layout {
            static let blackWords = [0x04, 0x08, 0x0C]
            static let serial = 0x10
            static let serialLength = 20
            static let version = 0x2C
            static let versionLength = 10
            static let checksum = 0x0002
            static let checksumRange = 0x0004...0x1799
            static let calibrationDate = 0x001E
            static let sensorCurves = [0x0026, 0x05A2, 0x0B1E]
            static let ambientTransmission = 0x10BC
            static let curveSamples = 351  // 380…730 nm, 1 nm
        }

        public init(internalEEPROM: Data, externalEEPROM: Data) throws {
            let i = [UInt8](internalEEPROM)
            let e = [UInt8](externalEEPROM)
            guard i.count == I1D3Protocol.internalEEPROMSize, e.count == I1D3Protocol.externalEEPROMSize else {
                throw MeterError.invalidCalibration("EEPROM sizes \(i.count) and \(e.count)")
            }
            serialNumber = I1D3Protocol.string(i, from: Layout.serial, maxLength: Layout.serialLength)
            hardwareVersion = I1D3Protocol.string(i, from: Layout.version, maxLength: Layout.versionLength)
            blackWords = Layout.blackWords.map {
                let w = I1D3Protocol.u32(i, at: $0)
                return w == .max ? 0 : w
            }
            calibrationDateRaw =
                UInt64(I1D3Protocol.u32(e, at: Layout.calibrationDate))
                | UInt64(I1D3Protocol.u32(e, at: Layout.calibrationDate + 4)) << 32
            storedChecksum = I1D3Protocol.u16(e, at: Layout.checksum)
            computedChecksum = e[Layout.checksumRange].reduce(0) { $0 &+ UInt16($1) }
            if hardwareVersion.hasPrefix("A-01"), storedChecksum != computedChecksum {
                throw MeterError.invalidCalibration("external EEPROM checksum mismatch")
            }
            func floats(at offset: Int) -> [Double] {
                (0..<Layout.curveSamples).map {
                    Double(Float(bitPattern: I1D3Protocol.u32(e, at: offset + 4 * $0)))
                }
            }
            let curves = Layout.sensorCurves.map { floats(at: $0).map { $0 / 1000 } }
            guard curves.joined().allSatisfy(\.isFinite) else {
                throw MeterError.invalidCalibration("sensor curves are not finite")
            }
            sensorCurves = SpectralSamples(startWavelength: 380, step: 1, rows: curves)
            ambientTransmission = floats(at: Layout.ambientTransmission)
        }

        /// Black offsets in Hz, using ArgyllCMS's word / 6 000 000 reading (UNCONFIRMED, see `blackWords`).
        public var blackOffsetHz: [Double] { blackWords.map { Double($0) / 6_000_000 } }

        /// Factory-default sensor→XYZ matrix: ArgyllCMS's "MIbLSr" fit, which uses the three sensor curves themselves as
        /// the sample spectra (spec §4.4), so M · rgb(S_k) = XYZ(S_k) for k = R, G, B.
        ///
        /// Integrals come from ColorScience's 5 nm CIE 1931 table with zero outside the curves' 380…730 nm, while ArgyllCMS
        /// uses 1 nm and holds end values. The difference is small but UNCONFIRMED; compare with `spotread` on hardware.
        public func defaultMatrix() throws -> Matrix3 {
            guard let m = fit(sensorCurves) else {
                throw MeterError.invalidCalibration("sensor curves do not span three dimensions")
            }
            return m
        }

        /// The matrix to use with `correction`: the default for nil, CCMX · default for a matrix (spec §5.2), and a fresh
        /// least-squares fit over the display spectra with this unit's own curves for a CCSS (spec §5.1).
        public func matrix(for correction: ColorimeterCorrection?) throws -> Matrix3 {
            switch correction?.kind {
            case nil:
                return try defaultMatrix()
            case .matrix(let c)?:
                guard c.count == 9, c.allSatisfy(\.isFinite) else {
                    throw MeterError.invalidCorrection("CCMX needs 9 finite values")
                }
                return Matrix3(c) * (try defaultMatrix())
            case .spectral(let samples)?:
                guard samples.rows.count >= 3, let m = fit(samples) else {
                    throw MeterError.invalidCorrection("CCSS needs at least 3 independent spectra")
                }
                return m
            }
        }

        private func fit(_ samples: SpectralSamples) -> Matrix3? {
            SpectralCorrection.matrix(sensorSensitivities: sensorCurves, displaySamples: samples)
                .map { Matrix3($0.m.map { $0 * Self.lumensPerMilliwatt }) }
        }
    }
#endif
