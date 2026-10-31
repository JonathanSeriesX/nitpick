import Foundation
import Testing

@testable import LGControl

@Suite struct FramingTests {
    @Test func jsonRoundTripAndIntegerEncoding() throws {
        let value: JSON = ["id": 7, "dataCount": 3072, "f": 0.4, "s": "a/b", "n": nil, "b": true, "a": [1, "2"]]
        let text = String(decoding: try value.encoded(), as: UTF8.self)
        #expect(text == #"{"a":[1,"2"],"b":true,"dataCount":3072,"f":0.4,"id":7,"n":null,"s":"a/b"}"#)
        #expect(try JSON.decode(text) == value)
        #expect(JSON.string("40").looselyEquals(40))
        #expect(JSON.array(["1", 2]).looselyEquals([1.0, "2"]))
        #expect(!JSON.string("40").looselyEquals("41"))
        #expect(JSON.string("34").intValue == 34)
    }

    @Test func successRuleFollowsBscpylgtv() throws {
        #expect(try SSAPConnection.successPayload(["type": "response", "payload": ["returnValue": true, "x": 1]])["x"] == 1)
        #expect(try SSAPConnection.successPayload(["type": "response", "payload": ["subscribed": true]])["subscribed"] == true)
        #expect(throws: LGError.self) { try SSAPConnection.successPayload(["type": "response", "payload": [:]]) }
        let e = #expect(throws: LGError.self) {
            try SSAPConnection.successPayload(["type": "error", "id": 1, "error": "401 insufficient permissions", "payload": [:]])
        }
        #expect(e?.serverCode == 401)
        let driver = #expect(throws: LGError.self) {
            try SSAPConnection.successPayload([
                "type": "response", "payload": ["returnValue": false, "errorCode": 20, "errorMessage": "Driver error"],
            ])
        }
        #expect(driver?.serverCode == 20)
    }

    @Test func frameIDsFromTheTVNeverTrap() {
        #expect(SSAPConnection.key(.number(7)) == "7" && SSAPConnection.key(.string("register_0")) == "register_0")
        #expect(SSAPConnection.key(.number(1e300)) == nil && SSAPConnection.key(.number(2.5)) == nil)
        #expect(SSAPConnection.key(.bool(true)) == nil && SSAPConnection.key(nil) == nil)
    }

    @Test func framesCarryMonotonicIDsAndEchoMatching() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        async let a = tv.powerState()
        async let b = tv.foregroundApp()
        async let c = tv.externalInputs()
        let (power, app, inputs) = try await (a, b, c)
        #expect(power.state == "Active" && app == "com.webos.app.hdmi2" && inputs.count == 4)
        let frames = await fake.requests
        #expect(frames.first == ["id": "hello", "type": "hello", "payload": [:]])
        // hello → getSystemInfo → register (SPEC §3.3).
        #expect(
            frames.prefix(3).map { $0["uri"]?.stringValue ?? $0["type"]?.stringValue ?? "" } == [
                "hello", "ssap://system/getSystemInfo", "register",
            ])
        #expect(frames[2]["id"] == "register_0")
        let ids = frames.filter { $0["type"] == "request" }.compactMap { $0["id"]?.intValue }
        #expect(ids.count >= 3 && Set(ids).count == ids.count && ids.allSatisfy { $0 > 0 })
        #expect(frames.filter { $0["type"] == "request" }.allSatisfy { $0["uri"]?.stringValue?.hasPrefix("ssap://") == true })
        await fake.stop()
    }

    @Test func unknownURIIs404() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        let e = await lgError { try await tv.request("foo/bar") }
        #expect(e?.serverCode == 404)
        await fake.stop()
    }

    @Test func subscriptionYieldsFirstReplyAndPushes() async throws {
        let (fake, tv) = try await makeTV()
        try await tv.connect(host: "127.0.0.1")
        let stream = try await tv.subscribe("com.webos.service.tvpower/power/getPowerState")
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?["state"] == "Active")
        try await tv.turnOff()
        #expect(await it.next()?["state"] == "Power Off")
        await fake.stop()
    }

    @Test func requestTimeoutAndCancellation() async throws {
        let (fake, _) = try await makeTV(.init(pairing: .ignore))
        let port = await fake.port!
        let c = SSAPConnection(host: "127.0.0.1", options: .init(port: port, allowInsecure: true, requestTimeout: .milliseconds(200)))
        let hello = try await c.open()
        #expect(hello?.deviceOSReleaseVersion == "10.3.0")
        let start = ContinuousClock.now
        let e = await lgError {
            _ = try await c.register(SSAPRegistration.payload(manifest: .signedLegacy, clientKey: nil), timeout: .milliseconds(300))
        }
        #expect(e == .timeout("pairing prompt"))
        #expect(ContinuousClock.now - start < .seconds(2))

        let task = Task { try await c.register(SSAPRegistration.payload(manifest: .signedLegacy, clientKey: nil), timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // The connection survives both.
        #expect(try await c.request("system/getSystemInfo")["modelName"] == "OLED65B4PUA")
        await c.close()
        await #expect(throws: LGError.notConnected) { try await c.request("system/getSystemInfo") }
        await fake.stop()
    }

    @Test func connectRefusedAndConnectTimeout() async throws {
        let refused = SSAPConnection(host: "127.0.0.1", options: .init(port: 9, allowInsecure: true, connectTimeout: .seconds(2)))
        let e = await lgError { try await refused.open() }
        guard case .connectionFailed = e else {
            Issue.record("expected connectionFailed, got \(String(describing: e))")
            return
        }

        // A TCP listener that never answers the WebSocket upgrade.
        let silent = try SilentListener()
        let port = try await silent.start()
        let slow = SSAPConnection(host: "127.0.0.1", options: .init(port: port, allowInsecure: true, connectTimeout: .milliseconds(300)))
        let t = await lgError { try await slow.open() }
        guard case .timeout = t else {
            Issue.record("expected timeout, got \(String(describing: t))")
            return
        }
        silent.stop()
    }

    @Test(.timeLimit(.minutes(1))) func stateStreamFinishesWhenTheClientGoesAway() async {
        var tv: LGTV? = LGTV(credentials: InMemoryTVCredentialStore())
        let states = tv!.state
        tv = nil
        for await _ in states {}  // returns only once the stream is finished
    }

    @Test func droppedSocketReportsDisconnected() async throws {
        let (fake, tv) = try await makeTV()
        var states = tv.state.makeAsyncIterator()
        try await tv.connect(host: "127.0.0.1")
        await fake.dropConnections()
        while let s = await states.next() {
            if case .disconnected(let error) = s {
                #expect(error != nil)
                break
            }
        }
        await fake.stop()
    }
}
