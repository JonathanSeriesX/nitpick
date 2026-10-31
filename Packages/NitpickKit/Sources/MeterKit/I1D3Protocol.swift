#if os(macOS)
    import Foundation

    /// The i1d3 wire protocol without I/O: command builders, reply validation and parsers, and the unlock arithmetic.
    ///
    /// Written from the clean-room spec (docs/research/meter-i1d3.md §3). Every request and reply is 64 bytes. Byte 0 of a
    /// request is the command code; byte 0 of a reply is the status and byte 1 echoes the command code. Integers are
    /// little-endian, except the big-endian external EEPROM address.
    public enum I1D3Protocol {
        public static let reportLength = 64
        public static let vendorID: UInt32 = 0x0765
        public static let productID: UInt32 = 0x5020
        /// Measurement clock (spec §4.3).
        public static let clockHz = 12_000_000.0
        public static let internalEEPROMSize = 256
        public static let externalEEPROMSize = 8192
        /// Largest read per command (spec §3.2): the data must fit in the 64-byte reply after its header.
        public static let internalEEPROMChunk = 60
        public static let externalEEPROMChunk = 59

        /// Codes that write to the device (internal EEPROM, external EEPROM, write enable; spec §3.3). Never sent.
        public static let forbiddenCommands: Set<UInt8> = [0x07, 0x13, 0xAB]
        /// Byte-0 codes this driver may send: the read-only allowlist of spec §3.2, without Set LED and AIO.
        static let allowedCommands: Set<UInt8> = [0x00, 0x01, 0x02, 0x08, 0x10, 0x12, 0x94, 0x99, 0x9A]
        /// Sub-commands of the `0x00` group this driver may send.
        static let allowedInfoCommands: Set<UInt8> = [0x00, 0x01, 0x10, 0x11, 0x12, 0x13, 0x20, 0x31]

        /// One request of the read-only allowlist.
        public enum Command: Hashable, Sendable {
            /// Product name, firmware version and date in one string.
            case getInfo
            case getStatus
            case getProductName
            case getProductType
            case getFirmwareVersion
            case getFirmwareDate
            case getLockStatus
            /// Rev. B only; call after `getHardwareInfo` succeeded.
            case getFirmwareNumber
            /// `0x10`: answers only on Rev. B, so it is the revision probe. Its echo is not checked.
            case getHardwareInfo
            /// Counts both edges of each sensor signal for `clocks` ticks of the 12 MHz clock.
            case measureFrequency(clocks: UInt32)
            /// Times `edges[c]` sensor edges of each channel in `channels` (bit 0 R, bit 1 G, bit 2 B).
            case measurePeriod(edges: [UInt16], channels: UInt8)
            case readInternalEEPROM(address: UInt8, length: UInt8)
            case readExternalEEPROM(address: UInt16, length: UInt8)
            case getDiffuserPosition
            case getUnlockChallenge
            case sendUnlockResponse(challenge: [UInt8], key: UnlockKey)

            /// Byte 0 of the request, which the reply echoes in byte 1.
            public var code: UInt8 {
                switch self {
                case .getInfo, .getStatus, .getProductName, .getProductType, .getFirmwareVersion, .getFirmwareDate,
                    .getLockStatus, .getFirmwareNumber:
                    0x00
                case .getHardwareInfo: 0x10
                case .measureFrequency: 0x01
                case .measurePeriod: 0x02
                case .readInternalEEPROM: 0x08
                case .readExternalEEPROM: 0x12
                case .getDiffuserPosition: 0x94
                case .getUnlockChallenge: 0x99
                case .sendUnlockResponse: 0x9A
                }
            }

            /// The 64-byte output report.
            public var report: Data {
                var r = [UInt8](repeating: 0, count: I1D3Protocol.reportLength)
                r[0] = code
                switch self {
                case .getInfo: r[1] = 0x00
                case .getStatus: r[1] = 0x01
                case .getProductName: r[1] = 0x10
                case .getProductType: r[1] = 0x11
                case .getFirmwareVersion: r[1] = 0x12
                case .getFirmwareDate: r[1] = 0x13
                case .getLockStatus: r[1] = 0x20
                case .getFirmwareNumber: r[1] = 0x31
                case .getHardwareInfo, .getDiffuserPosition, .getUnlockChallenge: break
                case .measureFrequency(let clocks):
                    put(clocks, into: &r, at: 1)
                case .measurePeriod(let edges, let channels):
                    for (c, e) in edges.prefix(3).enumerated() { put(e, into: &r, at: 1 + 2 * c) }
                    r[7] = channels & 0b111
                case .readInternalEEPROM(let address, let length):
                    r[1] = address
                    r[2] = length
                case .readExternalEEPROM(let address, let length):
                    r[1] = UInt8(address >> 8)  // the only big-endian field
                    r[2] = UInt8(address & 0xFF)
                    r[3] = length
                case .sendUnlockResponse(let challenge, let key):
                    r = I1D3Protocol.unlockResponse(challenge: challenge, key: key)
                }
                return Data(r)
            }
        }

        /// Throws unless `report` is a 64-byte request on the read-only allowlist. Transports call this before every send.
        public static func validateOutgoing(_ report: Data) throws {
            guard let code = report.first else { throw MeterError.malformedReply("empty request") }
            guard !forbiddenCommands.contains(code), allowedCommands.contains(code) else {
                throw MeterError.forbiddenCommand(code)
            }
            guard report.count == reportLength else {
                throw MeterError.malformedReply("request length \(report.count)")
            }
            if code == 0x00, !allowedInfoCommands.contains(report[report.startIndex + 1]) {
                throw MeterError.forbiddenCommand(code)
            }
        }

        /// Checks length, status and echo of a reply to `command` (spec §3.1) and returns its bytes.
        public static func validate(_ reply: Data, for command: Command) throws -> [UInt8] {
            let b = [UInt8](reply)
            guard b.count == reportLength else { throw MeterError.malformedReply("reply length \(b.count)") }
            guard b[0] == 0 else { throw MeterError.deviceStatus(b[0]) }
            switch command.code {
            case 0x10: break  // no echo check (spec §3.2)
            case 0x94:  // byte 1 carries the diffuser position, and the payload must be empty
                guard b[2...].allSatisfy({ $0 == 0 }) else {
                    throw MeterError.malformedReply("diffuser payload not zero")
                }
            default:
                guard b[1] == command.code else {
                    throw MeterError.malformedReply(
                        String(format: "echo 0x%02X for command 0x%02X", b[1], command.code))
                }
            }
            return b
        }

        // MARK: Reply parsers

        /// NUL-terminated ASCII from `offset`, trimmed of surrounding spaces.
        public static func string(_ reply: [UInt8], from offset: Int = 2, maxLength: Int = 62) -> String {
            let bytes = reply.dropFirst(offset).prefix(maxLength).prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        public static func u16(_ b: [UInt8], at i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }

        public static func u32(_ b: [UInt8], at i: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * $1) }
        }

        /// Get-status rule from spec §3.2: OK if byte 2 ≠ 0 or the u16 at bytes 3–4 is ≥ 5.
        public static func isStatusOK(_ reply: [UInt8]) -> Bool { reply[2] != 0 || u16(reply, at: 3) >= 5 }

        /// Locked if byte 2 = 0 and byte 3 ≠ 0.
        public static func isLocked(_ reply: [UInt8]) -> Bool { reply[2] == 0 && reply[3] != 0 }

        /// R, G, B counts (frequency mode) or clock counts (period mode) at bytes 2, 6, 10.
        public static func channelCounts(_ reply: [UInt8]) -> [UInt32] { [2, 6, 10].map { u32(reply, at: $0) } }

        /// 1 = ambient diffuser over the sensor, 0 = display position.
        public static func diffuserPosition(_ reply: [UInt8]) -> UInt8 { reply[1] }

        public static func unlockAccepted(_ reply: [UInt8]) -> Bool { reply[2] == 0x77 }

        /// Offset of the data in an EEPROM read reply.
        static func eepromDataOffset(external: Bool) -> Int { external ? 5 : 4 }

        /// `(address, length)` reads that cover `0..<total` exactly, each at most `maxLength` bytes.
        public static func chunks(total: Int, maxLength: Int) -> [(address: Int, length: Int)] {
            stride(from: 0, to: total, by: maxLength).map { ($0, min(maxLength, total - $0)) }
        }

        static func put<T: FixedWidthInteger>(_ value: T, into r: inout [UInt8], at i: Int) {
            for k in 0..<(T.bitWidth / 8) { r[i + k] = UInt8(truncatingIfNeeded: value >> (8 * k)) }
        }

        // MARK: Unlock (spec §3.5, §3.6)

        /// A 64-bit unlock key: two 32-bit words.
        public struct UnlockKey: Hashable, Sendable, CustomStringConvertible {
            public let name: String
            let k0: UInt32
            let k1: UInt32
            public var description: String { name }
        }

        /// The keys this app ships, in the order they are tried. Only the retail, generic-OEM and ColorMunki keys are
        /// included (spec §1.6 recommendation); vendor-branded units stay unsupported.
        public static let unlockKeys: [UnlockKey] = [
            UnlockKey(name: "retail", k0: 0xE962_2E9F, k1: 0x8D63_E133),
            UnlockKey(name: "generic OEM", k0: 0xCAA6_2B2C, k1: 0x3081_5B61),
            UnlockKey(name: "ColorMunki", k0: 0xE01E_6E0A, k1: 0x2574_62DE),
        ]

        /// The `0x9A` request that answers `challenge` (the 64-byte reply to `0x99`) with `key`.
        public static func unlockResponse(challenge c: [UInt8], key: UnlockKey) -> [UInt8] {
            precondition(c.count == reportLength, "challenge must be 64 bytes")
            // Eight challenge bytes, unmasked with c[3].
            let s = (0..<8).map { c[3] ^ c[35 + $0] }
            func word(_ i: Int, _ j: Int, _ k: Int, _ l: Int) -> UInt32 {
                UInt32(s[i]) << 24 | UInt32(s[j]) << 16 | UInt32(s[k]) << 8 | UInt32(s[l])
            }
            let a = word(3, 0, 4, 6)
            let b = word(1, 7, 2, 5)
            let n0 = 0 &- key.k0
            let n1 = 0 &- key.k1
            let p0 = n0 &- b
            let p1 = n1 &- a
            let p2 = b &* n0
            let p3 = a &* n1
            func byte(_ x: UInt32, _ j: Int) -> Int { Int((x >> (8 * j)) & 0xFF) }
            let sum = s.reduce(0) { $0 + Int($1) } + (0..<4).reduce(0) { $0 + byte(n0, $1) + byte(n1, $1) }
            let lo = sum & 0xFF
            let hi = (sum >> 8) & 0xFF
            let r = [
                byte(p0, 2) + lo, byte(p2, 1) - hi, byte(p3, 0) + hi, byte(p1, 2) + lo,
                byte(p2, 2) - hi, byte(p3, 2) - lo, byte(p1, 3) - lo, byte(p0, 0) - hi,
                byte(p3, 1) + lo, byte(p2, 3) - hi, byte(p0, 1) + lo, byte(p1, 1) - hi,
                byte(p1, 0) + hi, byte(p3, 3) + hi, byte(p2, 0) + lo, byte(p0, 3) - lo,
            ]
            var out = [UInt8](repeating: 0, count: reportLength)
            out[0] = 0x9A
            for (i, v) in r.enumerated() { out[24 + i] = c[2] ^ UInt8(truncatingIfNeeded: v) }  // mod 256
            return out
        }
    }
#endif
