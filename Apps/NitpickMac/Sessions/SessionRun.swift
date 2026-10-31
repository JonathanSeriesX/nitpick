import Calibration
import ColorScience
import Foundation

/// Live state of one workflow run, fed by `WorkflowRunner`'s event stream.
@Observable
final class SessionRun {
    struct Reading: Identifiable {
        let id: Int
        let stage: String
        let stimulus: SignalRGB
        let reading: MeterReading
        /// Judged ΔE against the target (indicative while running: HDR grey uses the peak seen so far).
        let deltaE: Double
    }

    enum Outcome: Equatable {
        case completed
        case cancelled
        case failed(String)
    }

    let sessionID: UUID
    let profile: SessionProfile
    let runner: WorkflowRunner
    private(set) var stageName = "Starting"
    private(set) var stageIndex = 0
    private(set) var stageCount = 7
    private(set) var stageReadings = 0
    private(set) var totalReadings = 0
    private(set) var message = ""
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?
    private(set) var feed: [Reading] = []
    private(set) var warnings: [String] = []
    private(set) var adjustments = 0
    private(set) var prompt: String?
    private(set) var outcome: Outcome?
    @ObservationIgnored private var peakSeen = 0.0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sessionID: UUID, profile: SessionProfile, runner: WorkflowRunner) {
        self.sessionID = sessionID
        self.profile = profile
        self.runner = runner
    }

    var isRunning: Bool { outcome == nil }

    /// Readings a measurement stage takes, from the package's stimulus sets (Adjust varies by TV, so it is open-ended).
    private var expectedReadings: [String: Int] {
        let t = profile.target
        let sets = [
            Stimuli.grayscale(t.dynamicRange).count + Stimuli.nearBlack.count, Stimuli.primariesSecondaries(t).count,
            Stimuli.saturationSweeps(t).count,
        ].reduce(0, +)
        let verification = Stimuli.verification(t).count
        return ["Pre-calibration": sets + verification, "Post-calibration": sets, "Verification": verification]
    }

    /// Overall progress: finished stages plus the share of the current stage's expected readings.
    var fraction: Double {
        if outcome == .completed { return 1 }
        let inStage = expectedReadings[stageName].map { min(Double(stageReadings) / Double($0), 0.99) } ?? 0
        return min((Double(stageIndex) + inStage) / Double(stageCount), 1)
    }

    func start(devices: WorkflowRunner.Devices, session: CalibrationSession, sleeper: any Sleeper, onChange: @escaping () -> Void) {
        startedAt = Date()
        let stream = runner.run(profile: profile, devices: devices, session: session, sleeper: sleeper)
        task = Task {
            do {
                for try await event in stream {
                    apply(event)
                    if case .stage = event { onChange() }
                }
            } catch {
                outcome = .failed(ErrorText(error).message)
            }
            if outcome == nil { outcome = .cancelled }
            finishedAt = Date()
            prompt = nil
            onChange()
        }
    }

    func cancel() { runner.cancel() }

    func confirm() {
        prompt = nil
        runner.confirmUser()
    }

    func apply(_ event: WorkflowEvent) {
        switch event {
        case .stage(let name, let index, let count):
            stageName = name
            stageIndex = index
            stageCount = count
            stageReadings = 0
        case .progress(_, let message):
            self.message = message
        case .measurement(let stimulus, let reading, let reference):
            stageReadings += 1
            totalReadings += 1
            if stimulus.isGray { peakSeen = max(peakSeen, reading.luminance) }
            let deltaE = Metrics.deltaE(reading.xyz, reference ?? self.reference(stimulus), target: profile.target)
            feed.insert(Reading(id: totalReadings, stage: stageName, stimulus: stimulus, reading: reading, deltaE: deltaE), at: 0)
            if feed.count > 8 { feed.removeLast() }
        case .adjustment(let step):
            adjustments += 1
            message = "\(step.control): \(step.from) → \(step.to)"
        case .warning(let text):
            warnings.append(text)
        case .needsUser(let text):
            prompt = text
        case .completed:
            outcome = .completed
        case .cancelled:
            outcome = .cancelled
        case .failed(let text):
            outcome = .failed(text)
        }
    }

    private func reference(_ stimulus: SignalRGB) -> XYZ {
        let target = profile.target
        guard target.isHDR, stimulus.isGray else { return target.reference(stimulus) }
        return Metrics.hdrGrayReference(stimulus: stimulus.r, target: target, displayPeak: max(peakSeen, 100)).xyz
    }
}
