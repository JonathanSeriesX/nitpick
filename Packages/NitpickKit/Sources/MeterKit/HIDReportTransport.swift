#if os(macOS)
    import CoreHID
    import Foundation

    /// One i1d3 meter as seen by discovery: enough to show it in the UI and to open it.
    public struct HIDDeviceIdentity: Hashable, Sendable, Identifiable, CustomStringConvertible {
        /// I/O Registry entry ID (CoreHID `DeviceReference.deviceID`); any unique number for simulated devices.
        public var id: UInt64
        public var vendorID: UInt32
        public var productID: UInt32
        public var product: String?
        public var serialNumber: String?
        public var locationID: UInt64?
        /// CoreHID handle used by `CoreHIDTransport`; nil for simulated devices.
        let reference: HIDDeviceClient.DeviceReference?

        public init(
            id: UInt64, vendorID: UInt32 = I1D3Protocol.vendorID, productID: UInt32 = I1D3Protocol.productID,
            product: String? = nil, serialNumber: String? = nil, locationID: UInt64? = nil
        ) {
            self.init(
                id: id, vendorID: vendorID, productID: productID, product: product, serialNumber: serialNumber,
                locationID: locationID, reference: nil)
        }

        init(
            id: UInt64, vendorID: UInt32, productID: UInt32, product: String?, serialNumber: String?,
            locationID: UInt64?,
            reference: HIDDeviceClient.DeviceReference?
        ) {
            self.id = id
            self.vendorID = vendorID
            self.productID = productID
            self.product = product
            self.serialNumber = serialNumber
            self.locationID = locationID
            self.reference = reference
        }

        public var description: String {
            String(format: "%04x:%04x #%llx", vendorID, productID, id) + (product.map { " \($0)" } ?? "")
        }
    }

    /// A 64-byte HID report channel to one i1d3, without report IDs (spec §2.2).
    ///
    /// Implementations: `CoreHIDTransport` (real USB device) and `FakeI1D3Transport` (simulated device). Both refuse any
    /// report that `I1D3Protocol.validateOutgoing(_:)` rejects, so no write command can reach a device.
    public protocol HIDReportTransport: Sendable {
        var identity: HIDDeviceIdentity { get }
        func open() async throws
        /// Closes the device. A pending `nextInputReport` fails with `MeterError.disconnected`.
        func close() async
        /// Sends one 64-byte output report. Only one command may wait for its reply at a time.
        func sendOutputReport(_ data: Data) async throws
        /// The next input report, oldest first. Reports that arrive before this call are buffered, not lost.
        /// Throws `MeterError.timeout`, `MeterError.disconnected` or `CancellationError`.
        func nextInputReport(timeout: Duration) async throws -> Data
    }

    /// Errors from the i1d3 driver. Descriptions are written for the user.
    public enum MeterError: Error, Hashable, Sendable, LocalizedError {
        case notConnected
        /// Another process holds the meter.
        case busy
        /// The App Sandbox or TCC refused to open the device.
        case accessDenied
        /// The meter was unplugged or stopped answering at the USB level.
        case disconnected
        case timeout
        /// A second command was sent before the first one's reply arrived.
        case operationInProgress
        /// The device answered with a non-zero status byte (for example `0x83`: no light transitions).
        case deviceStatus(UInt8)
        case malformedReply(String)
        /// The command code may write to the device (spec §3.3) or is not on the read-only allowlist.
        case forbiddenCommand(UInt8)
        /// None of the shipped unlock keys opened this unit.
        case unsupportedVariant
        /// The ambient diffuser covers the sensor, so a display reading would be wrong.
        case diffuserOverSensor
        case invalidCalibration(String)
        case invalidCorrection(String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "The meter is not connected."
            case .busy:
                "Another app is using the meter. Quit Calibrite PROFILER, DisplayCAL or other calibration software, then try again."
            case .accessDenied:
                "macOS did not allow access to the meter. The app needs the USB entitlement (com.apple.security.device.usb, App Sandbox → Hardware → USB)."
            case .disconnected: "The meter was disconnected."
            case .timeout: "The meter did not answer in time."
            case .operationInProgress: "The meter is busy with another measurement."
            case .deviceStatus(let s): String(format: "The meter reported status 0x%02X.", s)
            case .malformedReply(let why): "The meter sent an unexpected reply (\(why))."
            case .forbiddenCommand(let c): String(format: "Command 0x%02X is not allowed.", c)
            case .unsupportedVariant: "This meter is locked to other software (unsupported OEM variant)."
            case .diffuserOverSensor: "Swing the ambient diffuser away from the sensor, then measure again."
            case .invalidCalibration(let why): "The meter's calibration data is invalid (\(why))."
            case .invalidCorrection(let why): "The colorimeter correction cannot be used (\(why))."
            case .transport(let why): "USB error: \(why)."
            }
        }
    }

    /// Buffers input reports so none is lost between a send and the wait that follows, and keeps one command in flight.
    actor ReportInbox {
        private var reports: [Data] = []
        private var closedError: MeterError? = .notConnected
        private var awaitingReply = false
        private var waiter: (token: Int, continuation: CheckedContinuation<Data, any Error>, timer: Task<Void, Never>)?
        private var tokens = 0

        var isWaiting: Bool { waiter != nil }

        func reopen() {
            reports = []
            closedError = nil
            awaitingReply = false
        }

        func close(_ error: MeterError) {
            closedError = error
            reports = []
            awaitingReply = false
            if let token = waiter?.token { fail(token, error) }
        }

        func deliver(_ report: Data) {
            guard closedError == nil else { return }
            guard let w = waiter else { return reports.append(report) }
            waiter = nil
            w.timer.cancel()
            w.continuation.resume(returning: report)
        }

        /// Marks a command as sent; throws if the previous one is still waiting for its reply.
        func beginCommand() throws {
            if let closedError { throw closedError }
            guard !awaitingReply else { throw MeterError.operationInProgress }
            awaitingReply = true
        }

        /// Undoes `beginCommand()` when the send itself failed.
        func abandonCommand() { awaitingReply = false }

        func next(timeout: Duration) async throws -> Data {
            // Before the `defer`: a second reader must not free the command slot while the first one's reply is pending.
            guard waiter == nil else { throw MeterError.operationInProgress }
            defer { awaitingReply = false }
            if !reports.isEmpty { return reports.removeFirst() }
            if let closedError { throw closedError }
            try Task.checkCancellation()
            tokens += 1
            let token = tokens
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let timer = Task {
                        try? await Task.sleep(for: timeout)
                        self.fail(token, MeterError.timeout)
                    }
                    waiter = (token, continuation, timer)
                }
            } onCancel: {
                Task { await self.fail(token, CancellationError()) }
            }
        }

        private func fail(_ token: Int, _ error: any Error) {
            guard let w = waiter, w.token == token else { return }
            waiter = nil
            w.timer.cancel()
            w.continuation.resume(throwing: error)
        }
    }
#endif
