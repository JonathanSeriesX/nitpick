import Darwin
import Foundation
import Testing

@testable import LGControl

@Suite struct DiscoveryTests {
    @Test func parsesCapturedSSDPResponse() throws {
        let text =
            "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.128:1702/\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\n"
            + "USN: uuid:6da62662-1369-a82d-95c7-353c235ed503::urn:lge-com:service:webos-second-screen:1\r\n"
            + "ST: urn:lge-com:service:webos-second-screen:1\r\nDATE: Sun, 17 Jan 2016 13:52:40 GMT\r\nSERVER: WebOS/4.1.0 UPnP/1.0\r\n\r\n"
        let r = try #require(SSDPResponse(text))
        #expect(r.location == URL(string: "http://192.168.1.128:1702/") && r.location.host() == "192.168.1.128")
        #expect(r.uuid == "6da62662-1369-a82d-95c7-353c235ed503" && r.server == "WebOS/4.1.0 UPnP/1.0")
        #expect(r.searchTarget == LGDiscovery.searchTarget)
        #expect(SSDPResponse("http/1.1 200 ok\nlocation: http://10.0.0.5:1873/\nusn: uuid:ABC::x\n")?.uuid == "abc")
        #expect(SSDPResponse("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\nUSN: uuid:a\r\n") == nil)
        #expect(SSDPResponse("HTTP/1.1 200 OK\r\nUSN: uuid:a\r\n") == nil)
    }

    @Test func parsesDeviceDescription() {
        let xml = """
            <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
              <specVersion><major>1</major><minor>0</minor></specVersion>
              <device>
                <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
                <friendlyName>[LG] webOS TV OLED65B4PUA</friendlyName>
                <manufacturer>LG Electronics</manufacturer>
                <modelName>LG Smart TV</modelName>
                <modelNumber>OLED65B4PUA</modelNumber>
                <UDN>uuid:6da62662-1369-a82d-95c7-353c235ed503</UDN>
                <serviceList><service><serviceType>urn:lge-com:service:webos-second-screen:1</serviceType></service></serviceList>
              </device>
            </root>
            """
        let d = UPnPDeviceDescription(xml: Data(xml.utf8))
        #expect(d.friendlyName == "[LG] webOS TV OLED65B4PUA" && d.modelName == "LG Smart TV" && d.modelNumber == "OLED65B4PUA")
        #expect(d.udn.map(SSAPRegistration.normalizedID) == "6da62662-1369-a82d-95c7-353c235ed503")
    }

    @Test func wakeOnLANPacket() throws {
        let p = try WakeOnLAN.packet(mac: "a8:23:fe:00:11:22")
        #expect(p.count == 102 && p.prefix(6).allSatisfy { $0 == 0xFF })
        let mac: [UInt8] = [0xA8, 0x23, 0xFE, 0x00, 0x11, 0x22]
        #expect((0..<16).allSatisfy { Array(p[(6 + $0 * 6)..<(12 + $0 * 6)]) == mac })
        #expect(try WakeOnLAN.packet(mac: "A8-23-FE-00-11-22") == p && WakeOnLAN.packet(mac: "a823fe001122") == p)
        #expect(throws: LGError.self) { try WakeOnLAN.packet(mac: "a8:23:fe:00:11") }
        #expect(throws: LGError.self) { try WakeOnLAN.packet(mac: "zz:23:fe:00:11:22") }
        #expect(try WakeOnLAN.packet(mac: "ａ８:２３:ｆｅ:００:１１:２２") == p, "full-width digits are hex digits too")
    }

    @Test func wakeOnLANSendsThreeCopies() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        try await WakeOnLAN.send(mac: "a8:23:fe:00:11:22", broadcast: "127.0.0.1", port: port)
        var buffer = [UInt8](repeating: 0, count: 256)
        var sizes: [Int] = []
        for _ in 0..<3 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 1000) > 0 else { break }
            sizes.append(recv(fd, &buffer, buffer.count, 0))
        }
        #expect(sizes == [102, 102, 102])
        #expect(Data(buffer[0..<102]) == (try WakeOnLAN.packet(mac: "a8:23:fe:00:11:22")))
    }
}
