import AVFoundation
import AVKit
import ColorScience
import PatternLink
import SwiftUI
import UIKit
import os

/// Puts pattern frames on screen through the video pipeline (`AVSampleBufferDisplayLayer`) and requests the HDMI
/// output mode with `AVDisplayCriteria(refreshRate:formatDescription:)`, the only public route (research §1.2, §2.4).
///
/// Status, kept honest:
/// - Implemented: 10-bit 'x420' frames with colour/HDR10 attachments, enqueue with DisplayImmediately, failure
///   recovery, criteria from a real tagged buffer, KVO wait for the mode switch.
/// - Verified in the simulator: SDR frames appear full screen. The simulator has no HDMI and reports matching off.
/// - Hardware only: whether HDR10/HLG criteria switch the 1st-gen Apple TV 4K, whether the HDR10 metadata reaches the
///   InfoFrame, and whether the codes leave the box unchanged (research §9).
@MainActor @Observable final class PatternRenderer {
    let view = PatternLayerView()
    private(set) var framesShown = 0
    private(set) var displayState = DisplayModeState()
    private(set) var lastError: String?
    /// Format of the last frame shown; `.blank` reuses it so it does not change the output mode.
    private(set) var currentFormat = SignalFormat.sdr
    /// Metadata of the last HDR10 frame; HDR10 criteria are built with it.
    private var hdr10Metadata = HDR10StaticMetadata.p3D65_1000

    @ObservationIgnored private let builder = PatternFrameBuilder()
    @ObservationIgnored private var lastSample: CMSampleBuffer?
    @ObservationIgnored private var retried = false
    @ObservationIgnored private let log = Logger(
        subsystem: "com.jonathanseriesx.nitpick", category: "renderer")

    static let dolbyVisionNote =
        "Dolby Vision output cannot be requested by an app. Select Dolby Vision in Settings ▸ Video and Audio ▸ Format, "
        + "with Match Dynamic Range off. Display criteria were cleared, so tvOS now uses that Format setting. "
        + "In Dolby Vision mode the TV processes every value, so patterns are not code-exact."
    static let matchingOffNote =
        "Match Dynamic Range is off (Settings ▸ Video and Audio ▸ Match Content), so tvOS ignores this request "
        + "and keeps the Format setting."

    init() {
        let layer = view.displayLayer
        layer.videoGravity = .resize
        layer.backgroundColor = UIColor.black.cgColor
        layer.preventsDisplaySleepDuringVideoPlayback = true
        for name in [
            AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: layer.sampleBufferRenderer, queue: .main
            ) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.recover() }
            }
        }
    }

    /// Output size in pixels: the screen's native bounds for the current mode, even-aligned for 4:2:0.
    var frameSize: (width: Int, height: Int) {
        let size = window?.screen.nativeBounds.size ?? CGSize(width: 1920, height: 1080)
        return (max(2, Int(size.width) & ~1), max(2, Int(size.height) & ~1))
    }

    private var window: UIWindow? {
        view.window
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    // MARK: - Frames

    /// Builds the frame, drops anything still queued and shows it as soon as possible.
    func show(_ spec: PatternSpec) throws -> (enqueuedAt: Date, centerCodes: [Int]?) {
        let size = frameSize
        let frame = try builder.makeFrame(spec, width: size.width, height: size.height)
        let timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let sample = try CMSampleBuffer(
            imageBuffer: frame.pixelBuffer, formatDescription: frame.formatDescription,
            sampleTiming: timing)
        sample.sampleAttachments[0][.displayImmediately] = true

        let renderer = view.displayLayer.sampleBufferRenderer
        renderer.flush()  // also resets a failed renderer
        renderer.enqueue(sample)
        let enqueuedAt = Date()
        lastSample = sample
        retried = false
        currentFormat = spec.format
        if spec.format.transfer == .pq, let metadata = spec.hdr10Metadata { hdr10Metadata = metadata }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            recover()
            if renderer.status == .failed {
                throw RenderError(message: renderer.error?.localizedDescription ?? "Video renderer failed")
            }
        }
        framesShown += 1
        return (enqueuedAt, frame.centerCodes)
    }

    /// Re-enqueues the last frame once after a decode failure or a lost decoder (for example after backgrounding).
    func recover() {
        let renderer = view.displayLayer.sampleBufferRenderer
        guard let lastSample, renderer.status == .failed || renderer.requiresFlushToResumeDecoding
        else { return }
        let message = renderer.error?.localizedDescription ?? "decoder needs a flush"
        guard !retried else {
            lastError = message
            log.error("Video renderer failed again: \(message, privacy: .public)")
            return
        }
        retried = true
        log.warning("Video renderer: \(message, privacy: .public); re-enqueuing the last frame")
        renderer.flush()
        renderer.enqueue(lastSample)
        if renderer.status == .failed { lastError = renderer.error?.localizedDescription ?? message }
    }

    // MARK: - Output mode

    /// Sets display criteria from a frame tagged like the requested mode, then waits for tvOS to finish switching.
    /// Dolby Vision cannot be requested: criteria are cleared and the note says how the user selects it.
    func requestDisplayMode(_ request: DisplayModeRequest) async -> DisplayModeState {
        guard let window else {
            return DisplayModeState(
                requested: request, note: "No window yet; try again once the app is on screen.")
        }
        let manager = window.avDisplayManager
        var note: String?
        if request.dynamicRange == .dolbyVision {
            manager.preferredDisplayCriteria = nil
            note = Self.dolbyVisionNote
        } else {
            let format = SignalFormat.standard(for: request.dynamicRange)
            let size = frameSize
            do {
                let frame = try builder.makeFrame(
                    PatternSpec(
                        content: .black, format: format,
                        hdr10Metadata: format.transfer == .pq ? hdr10Metadata : nil),
                    width: size.width, height: size.height)
                let rate = Float(request.refreshRate ?? Double(window.screen.maximumFramesPerSecond))
                manager.preferredDisplayCriteria = AVDisplayCriteria(
                    refreshRate: rate, formatDescription: frame.formatDescription)
            } catch {
                note = "Could not build display criteria: \(error)"
            }
        }
        let finished = await waitForModeSwitch(manager)
        if note == nil, !manager.isDisplayCriteriaMatchingEnabled { note = Self.matchingOffNote }
        if note == nil, !finished { note = "The output mode switch had not finished after 15 s." }
        displayState = DisplayModeState(requested: request, note: note)
        log.info(
            "Display mode \(request.dynamicRange.rawValue, privacy: .public): \(note ?? "requested", privacy: .public)"
        )
        return currentDisplayState()
    }

    /// The last request plus live values from the display manager and screen.
    func currentDisplayState() -> DisplayModeState {
        var state = displayState
        if let window {
            state.switching = window.avDisplayManager.isDisplayModeSwitchInProgress
            state.matchingEnabled = window.avDisplayManager.isDisplayCriteriaMatchingEnabled
            // UIScreen EDR headroom compiles on tvOS (research §1.1, inferred 16.0); whether it tracks HDMI HDR is unconfirmed.
            state.currentEDRHeadroom = Double(window.screen.currentEDRHeadroom)
            state.potentialEDRHeadroom = Double(window.screen.potentialEDRHeadroom)
        }
        return state
    }

    /// Waits up to 1.5 s for tvOS to start a mode switch (none starts when the mode already matches or matching is
    /// off), then until it ends: KVO on `isDisplayModeSwitchInProgress` plus the start/end notifications. Returns
    /// false after 15 s.
    private func waitForModeSwitch(_ manager: AVDisplayManager) async -> Bool {
        let (changes, sink) = AsyncStream.makeStream(of: Bool?.self)  // nil = clock tick
        let observation = manager.observe(\.isDisplayModeSwitchInProgress, options: [.initial, .new]) {
            @Sendable _, change in sink.yield(change.newValue)
        }
        // Referencing these AVKit symbols also makes the linker load AVKit; without them the UIWindow.avDisplayManager
        // category is missing at run time ("unrecognized selector"), because autolinking skips symbol-less imports.
        let center = NotificationCenter.default
        let tokens = [
            (Notification.Name.AVDisplayManagerModeSwitchStart, true),
            (.AVDisplayManagerModeSwitchEnd, false),
        ]
        .map { name, inProgress in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in sink.yield(inProgress) }
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                sink.yield(nil)
            }
        }
        defer {
            observation.invalidate()
            tokens.forEach(center.removeObserver)
            ticker.cancel()
            sink.finish()
        }
        let start = ContinuousClock.now
        var started = false
        for await inProgress in changes {
            if inProgress == true {
                started = true
            } else if inProgress == false, started {
                return true
            }
            let elapsed = ContinuousClock.now - start
            if !started, elapsed > .milliseconds(1500) { return true }
            if elapsed > .seconds(15) { return false }
        }
        return false
    }
}

struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Full-screen host for the video layer.
final class PatternLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct PatternView: UIViewRepresentable {
    let renderer: PatternRenderer
    func makeUIView(context: Context) -> PatternLayerView { renderer.view }
    func updateUIView(_ view: PatternLayerView, context: Context) {}
}
