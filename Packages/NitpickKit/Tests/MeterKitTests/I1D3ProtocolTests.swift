#if os(macOS)
import Foundation
import Testing

@testable import MeterKit

private func hex(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        bytes.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return bytes
}

private func key(_ name: String) -> I1D3Protocol.UnlockKey { I1D3Protocol.unlockKeys.first { $0.name == name }! }

@Suite struct I1D3ProtocolTests {
    static let t0 = hex(
        "0099557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186"
            + "abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126")
    static let t1 = hex(
        "0099f9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a2"
            + "9f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542")

    /// Spec §3.5 test vectors. Key #1 = retail, #2 = ColorMunki, #3 = generic OEM.
    @Test(arguments: [
        (t0, "retail", "65c57460edfad0e4379df91607f25682"),
        (t0, "ColorMunki", "147219a4a3ab7510ef2f6f95fd867846"),
        (t0, "generic OEM", "811a93aad734af767329cd9d70ba8358"),
        (t1, "retail", "79f3a86cdf0e6410a4963d629b42d2ae"),
        (t1, "ColorMunki", "6890d5abf218c184612babe141c4446a"),
        (t1, "generic OEM", "dd982f990e79eba26d1849d9cc1f2f74"),
    ])
    func unlockVectors(challenge: [UInt8], keyName: String, expected: String) {
        let request = I1D3Protocol.unlockResponse(challenge: challenge, key: key(keyName))
        #expect(request == [0x9A] + Array(repeating: 0, count: 23) + hex(expected) + Array(repeating: 0, count: 24))
    }

    @Test func shipsOnlyTheRecommendedKeysInTryOrder() {
        #expect(I1D3Protocol.unlockKeys.map(\.name) == ["retail", "generic OEM", "ColorMunki"])
    }

    @Test func commandFraming() {
        func bytes(_ c: I1D3Protocol.Command) -> [UInt8] { [UInt8](c.report) }
        let all: [I1D3Protocol.Command] = [
            .getInfo, .getStatus, .getProductName, .getProductType, .getFirmwareVersion, .getFirmwareDate,
            .getLockStatus, .getFirmwareNumber, .getHardwareInfo, .measureFrequency(clocks: 1),
            .measurePeriod(edges: [2, 2, 2], channels: 7), .readInternalEEPROM(address: 0, length: 60),
            .readExternalEEPROM(address: 0, length: 59), .getDiffuserPosition, .getUnlockChallenge,
        ]
        for c in all {
            #expect(c.report.count == 64)
            #expect(c.report.first == c.code)
            #expect(!I1D3Protocol.forbiddenCommands.contains(c.code))
            #expect(throws: Never.self) { try I1D3Protocol.validateOutgoing(c.report) }
        }
        #expect(bytes(.getLockStatus).prefix(2) == [0x00, 0x20])
        #expect(bytes(.getFirmwareNumber).prefix(2) == [0x00, 0x31])
        #expect(bytes(.measureFrequency(clocks: 0x0102_0304)).prefix(6) == [0x01, 0x04, 0x03, 0x02, 0x01, 0x00])
        #expect(
            bytes(.measurePeriod(edges: [0x0102, 0x0304, 0x0506], channels: 0b101)).prefix(9)
                == [0x02, 0x02, 0x01, 0x04, 0x03, 0x06, 0x05, 0b101, 0x00])
        #expect(bytes(.readInternalEEPROM(address: 0x3C, length: 60)).prefix(4) == [0x08, 0x3C, 60, 0])
        // External EEPROM address is big-endian.
        #expect(bytes(.readExternalEEPROM(address: 0x1234, length: 59)).prefix(5) == [0x12, 0x12, 0x34, 59, 0])
        #expect(bytes(.getDiffuserPosition).prefix(2) == [0x94, 0x00])
        #expect(bytes(.getLockStatus)[2...].allSatisfy { $0 == 0 })
    }

    @Test func replyValidation() throws {
        var reply = [UInt8](repeating: 0, count: 64)
        reply[1] = 0x08
        #expect(throws: MeterError.self) { try I1D3Protocol.validate(Data(reply), for: .getLockStatus) }
        #expect(try I1D3Protocol.validate(Data(reply), for: .readInternalEEPROM(address: 0, length: 1)) == reply)
        // 0x10 is not echo-checked.
        #expect(throws: Never.self) { try I1D3Protocol.validate(Data(reply), for: .getHardwareInfo) }
        reply[0] = 0x83
        #expect(throws: MeterError.deviceStatus(0x83)) {
            try I1D3Protocol.validate(Data(reply), for: .readInternalEEPROM(address: 0, length: 1))
        }
        #expect(throws: MeterError.self) { try I1D3Protocol.validate(Data(reply.prefix(63)), for: .getStatus) }

        // 0x94 carries the position in byte 1 and must have an empty payload.
        var diffuser = [UInt8](repeating: 0, count: 64)
        diffuser[1] = 1
        #expect(
            I1D3Protocol.diffuserPosition(try I1D3Protocol.validate(Data(diffuser), for: .getDiffuserPosition)) == 1
        )
        diffuser[5] = 1
        #expect(throws: MeterError.self) { try I1D3Protocol.validate(Data(diffuser), for: .getDiffuserPosition) }
    }

    @Test func forbiddenAndUnknownCommandsAreRefused() async throws {
        let fake = FakeI1D3Transport()
        try await fake.open()
        for code: UInt8 in [0x07, 0x13, 0xAB, 0x93, 0x9B, 0x21, 0x04] {
            var report = [UInt8](repeating: 0, count: 64)
            report[0] = code
            #expect(throws: MeterError.forbiddenCommand(code)) { try I1D3Protocol.validateOutgoing(Data(report)) }
            await #expect(throws: MeterError.forbiddenCommand(code)) {
                try await fake.sendOutputReport(Data(report))
            }
        }
        var info = [UInt8](repeating: 0, count: 64)
        info[1] = 0x55  // unknown 0x00 sub-command
        await #expect(throws: MeterError.forbiddenCommand(0)) { try await fake.sendOutputReport(Data(info)) }
        #expect(await fake.receivedCommands.isEmpty)
    }

    @Test func eepromChunksCoverEachEEPROMExactly() {
        for (total, maxLength, count) in [(256, 60, 5), (8192, 59, 139)] {
            let chunks = I1D3Protocol.chunks(total: total, maxLength: maxLength)
            #expect(chunks.count == count)
            #expect(chunks.allSatisfy { $0.length >= 1 && $0.length <= maxLength })
            #expect(chunks.reduce(0) { $0 + $1.length } == total)
            #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.address + $0.length == $1.address })
            #expect(chunks.first?.address == 0)
        }
    }
}
#endif
