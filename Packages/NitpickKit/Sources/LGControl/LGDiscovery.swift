import Darwin
import Foundation
import Synchronization

/// A webOS TV found by SSDP.
public struct DiscoveredTV: Sendable, Hashable, Identifiable {
    /// UPnP `UDN` without `uuid:`, lowercase; equals hello `deviceUUID`. Use it as the credential-store key.
    public var id: String
    /// `friendlyName`, e.g. `[LG] webOS TV OLED65B4PUA`.
    public var name: String
    /// `modelNumber` (e.g. `OLED65B4PUA`), else `modelName`.
    public var model: String
    /// Host of the `LOCATION` URL (not the UDP source).
    public var host: String
}

/// One SSDP M-SEARCH reply. Header names are case-insensitive.
public struct SSDPResponse: Sendable, Equatable {
    public var location: URL
    public var usn: String
    public var server: String?
    public var searchTarget: String?

    public init?(_ text: String) {
        let lines = text.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard let status = lines.first, status.uppercased().hasPrefix("HTTP/1.1 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let loc = headers["LOCATION"], let url = URL(string: loc), url.host() != nil, let usn = headers["USN"] else { return nil }
        (location, self.usn, server, searchTarget) = (url, usn, headers["SERVER"], headers["ST"])
    }

    /// `uuid:6da6…::urn:…` → `6da6…`.
    public var uuid: String? {
        guard usn.lowercased().hasPrefix("uuid:") else { return nil }
        return String(usn.dropFirst(5).prefix { $0 != ":" }).lowercased()
    }
}

/// The fields Nitpick needs from the UPnP device description XML at `LOCATION`.
public struct UPnPDeviceDescription: Sendable, Equatable {
    public var friendlyName: String?
    public var modelName: String?
    public var modelNumber: String?
    public var udn: String?

    public init(xml: Data) {
        let delegate = DescriptionParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        let f = delegate.fields
        (friendlyName, modelName, modelNumber, udn) = (f["friendlyName"], f["modelName"], f["modelNumber"], f["UDN"])
    }

    /// Keeps the first (root device) occurrence of each wanted element.
    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:]
        private var text = ""
        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if ["friendlyName", "modelName", "modelNumber", "UDN"].contains(name), fields[name] == nil {
                fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

/// SSDP discovery of LG webOS TVs (`urn:lge-com:service:webos-second-screen:1`, SPEC §2.1) over a BSD UDP socket.
/// The sandboxed app needs the network client and server entitlements. A TV in standby probably does not answer.
public actor LGDiscovery {
    public static let searchTarget = "urn:lge-com:service:webos-second-screen:1"
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// Searches for `duration`; yields the full list each time a TV is added, then finishes.
    public nonisolated func discover(duration: Duration = .seconds(4)) -> AsyncStream<[DiscoveredTV]> {
        AsyncStream { continuation in
            let task = Task { await self.run(duration: duration, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(duration: Duration, into continuation: AsyncStream<[DiscoveredTV]>.Continuation) async {
        var found: [String: DiscoveredTV] = [:]
        var seen: Set<URL> = []
        for await reply in SSDPSocket.search(target: Self.searchTarget, duration: duration) where seen.insert(reply.location).inserted {
            guard let tv = await describe(reply) else { continue }
            found[tv.id] = tv
            continuation.yield(found.values.sorted { $0.name < $1.name })
        }
        continuation.finish()
    }

    private func describe(_ reply: SSDPResponse) async -> DiscoveredTV? {
        guard let host = reply.location.host() else { return nil }
        let request = URLRequest(url: reply.location, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        let description = (try? await session.data(for: request)).map { UPnPDeviceDescription(xml: $0.0) }
        guard let id = description?.udn.map(SSAPRegistration.normalizedID) ?? reply.uuid else { return nil }
        return DiscoveredTV(
            id: id, name: description?.friendlyName ?? "LG webOS TV",
            model: [description?.modelNumber, description?.modelName].compactMap { $0 }.first { !$0.isEmpty } ?? "",
            host: host)
    }
}

/// Blocking UDP work on a background thread.
enum SSDPSocket {
    static func search(target: String, duration: Duration) -> AsyncStream<SSDPResponse> {
        AsyncStream { continuation in
            let cancelled = Flag()
            continuation.onTermination = { _ in cancelled.value.store(true, ordering: .relaxed) }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { continuation.finish() }
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var ttl: UInt8 = 2
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
                let message =
                    "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: \(target)\r\n\r\n"
                let deadline = ContinuousClock.now + duration
                var sends = 0
                var buffer = [UInt8](repeating: 0, count: 4096)
                while ContinuousClock.now < deadline, !cancelled.value.load(ordering: .relaxed) {
                    if sends < 3 {  // UDP drops: send three times, 300 ms apart
                        _ = sendUDP(fd, Array(message.utf8), to: "239.255.255.250", port: 1900)
                        sends += 1
                    }
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&pfd, 1, 300) > 0 else { continue }
                    let n = recv(fd, &buffer, buffer.count, 0)
                    if n > 0, let reply = SSDPResponse(String(decoding: buffer[0..<n], as: UTF8.self)) { continuation.yield(reply) }
                }
            }
        }
    }

    final class Flag: Sendable { let value = Atomic<Bool>(false) }

    @discardableResult
    static func sendUDP(_ fd: Int32, _ bytes: [UInt8], to ip: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == bytes.count
            }
        }
    }
}

/// Wake-on-LAN (SPEC §2.3). Needs "Turn on via Wi-Fi" (webOS 24/25) or "Wake on LAN" (2025+) enabled on the TV.
/// Get the MACs with `LGTV.macAddresses()` while the TV is on, and wake both (the TV reacts on the interface in use).
public enum WakeOnLAN {
    /// 102 bytes: 6 × `0xFF`, then the 6-byte MAC 16 times. MAC as `a8:23:fe:00:11:22` (`:`/`-` separated or bare hex).
    public static func packet(mac: String) throws -> Data {
        let hex = mac.filter(\.isHexDigit)
        guard hex.count == 12, mac.filter({ !$0.isHexDigit && $0 != ":" && $0 != "-" }).isEmpty else {
            throw LGError.invalidPayload("bad MAC address \(mac)")
        }
        let bytes = stride(from: 0, to: 12, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        return Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in bytes })
    }

    /// Sends three copies 100 ms apart over UDP with `SO_BROADCAST` (default `255.255.255.255:9`).
    public static func send(mac: String, broadcast: String = "255.255.255.255", port: UInt16 = 9) async throws {
        let packet = Array(try packet(mac: mac))
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LGError.connectionFailed("socket: errno \(errno)") }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        for copy in 0..<3 {
            if copy > 0 { try await Task.sleep(for: .milliseconds(100)) }
            guard SSDPSocket.sendUDP(fd, packet, to: broadcast, port: port) else {
                throw LGError.connectionFailed("Wake-on-LAN send to \(broadcast):\(port) failed (errno \(errno))")
            }
        }
    }
}
