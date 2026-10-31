#if os(macOS)
    import CoreHID
    import Foundation

    /// A real i1d3 over CoreHID (macOS 15+): output reports without report ID, input reports from the notification stream
    /// (spec §2.3). Needs the `com.apple.security.device.usb` entitlement in the App Sandbox.
    public actor CoreHIDTransport: HIDReportTransport {
        public nonisolated let identity: HIDDeviceIdentity
        private let inbox = ReportInbox()
        private var client: HIDDeviceClient?
        private var reader: Task<Void, Never>?

        /// `identity` must come from `MeterDiscovery`.
        public init(identity: HIDDeviceIdentity) { self.identity = identity }

        public func open() async throws {
            guard client == nil else { return }
            guard let reference = identity.reference, let client = HIDDeviceClient(deviceReference: reference) else {
                throw MeterError.disconnected
            }
            do {
                try await client.seizeDevice()
            } catch HIDDeviceError.exclusiveAccess {
                throw MeterError.busy
            } catch {
                // Seizing inside the App Sandbox is UNCONFIRMED (spec §6.3): fall back to a shared open.
            }
            await inbox.reopen()
            // Subscribe before the first send, so the reply to it is buffered even if nobody waits yet.
            let notifications = await client.monitorNotifications(
                reportIDsToMonitor: [HIDReportID.allReports], elementsToMonitor: [])
            reader = Task { [inbox] in
                do {
                    for try await notification in notifications {
                        switch notification {
                        case .inputReport(_, let data, _): await inbox.deliver(data)
                        case .deviceRemoved: return await inbox.close(.disconnected)
                        default: continue
                        }
                    }
                    await inbox.close(.disconnected)
                } catch {
                    await inbox.close(Self.meterError(error))
                }
            }
            self.client = client
        }

        public func close() async {
            reader?.cancel()
            reader = nil
            client = nil  // releases the seize
            await inbox.close(.disconnected)
        }

        public func sendOutputReport(_ data: Data) async throws {
            try I1D3Protocol.validateOutgoing(data)
            guard let client else { throw MeterError.notConnected }
            try await inbox.beginCommand()
            do {
                try await client.dispatchSetReportRequest(type: .output, id: nil, data: data, timeout: .seconds(2))
            } catch {
                await inbox.abandonCommand()
                throw error is CancellationError ? error : Self.meterError(error)
            }
        }

        public func nextInputReport(timeout: Duration) async throws -> Data {
            guard client != nil else { throw MeterError.notConnected }
            return try await inbox.next(timeout: timeout)
        }

        static func meterError(_ error: any Error) -> MeterError {
            if let e = error as? MeterError { return e }
            guard let e = error as? HIDDeviceError else { return .transport(error.localizedDescription) }
            switch e {
            case .exclusiveAccess, .busy: return .busy
            case .notPermitted, .notPrivileged: return .accessDenied  // sandbox entitlement or TCC (spec §6.1, §6.2)
            case .timeout: return .timeout
            case .notResponding, .noPower, .aborted: return .disconnected
            default: return .transport(e.localizedDescription)
            }
        }
    }

    /// Finds i1d3 meters (VID 0x0765, PID 0x5020) and follows plug and unplug events.
    public actor MeterDiscovery {
        private let manager = HIDDeviceManager()
        private var known: [HIDDeviceClient.DeviceReference: HIDDeviceIdentity] = [:]
        private var subscribers: [UUID: AsyncStream<[HIDDeviceIdentity]>.Continuation] = [:]
        private var monitor: Task<Void, Never>?

        public init() {}

        /// The connected meters, re-emitted after every plug or unplug. The first element is the current list.
        public var devices: AsyncStream<[HIDDeviceIdentity]> {
            startMonitoring()
            let (stream, continuation) = AsyncStream.makeStream(
                of: [HIDDeviceIdentity].self, bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
            return stream
        }

        /// The meters connected now.
        public func enumerate() async -> [HIDDeviceIdentity] {
            if monitor == nil {
                startMonitoring()
                // ponytail: CoreHID has no synchronous enumeration; present devices arrive as immediate deviceMatched
                // events, so wait briefly once. Switch to IOKit registry matching if 300 ms proves too short.
                try? await Task.sleep(for: .milliseconds(300))
            }
            return current
        }

        private var current: [HIDDeviceIdentity] { known.values.sorted { $0.id < $1.id } }

        private func startMonitoring() {
            guard monitor == nil else { return }
            let criteria = HIDDeviceManager.DeviceMatchingCriteria(
                vendorID: I1D3Protocol.vendorID, productID: I1D3Protocol.productID)
            monitor = Task {
                do {
                    for try await notification in await manager.monitorNotifications(matchingCriteria: [criteria]) {
                        switch notification {
                        case .deviceMatched(let reference): await add(reference)
                        case .deviceRemoved(let reference): known[reference] = nil
                        @unknown default: continue
                        }
                        for subscriber in subscribers.values { subscriber.yield(current) }
                    }
                } catch {
                    // Discovery failures surface later as errors from `CoreHIDTransport.open()`.
                }
            }
        }

        private func add(_ reference: HIDDeviceClient.DeviceReference) async {
            let client = HIDDeviceClient(deviceReference: reference)
            known[reference] = HIDDeviceIdentity(
                id: reference.deviceID, vendorID: I1D3Protocol.vendorID, productID: I1D3Protocol.productID,
                product: await client?.product, serialNumber: await client?.serialNumber,
                locationID: await client?.locationID, reference: reference)
        }

        private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    }
#endif
