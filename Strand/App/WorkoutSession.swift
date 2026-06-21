import Foundation
import Combine
import StrandAnalytics

// WorkoutSession.swift — the app-level, persistent active-workout controller.
//
// The interval and goal screens used to OWN their run state in SwiftUI `@State`, so navigating away
// destroyed the workout. This lifts the whole session — timer, elapsed clock, HR-zone + pace monitors,
// simulated source, and the sound/buzz/haptic dispatch — into one `ObservableObject` owned at the app
// root. A workout now keeps running no matter where you navigate; a mini "now playing" bar (rendered at
// the root) stays up until you explicitly Stop. The full screen (`ActiveWorkoutView`) and the mini bar
// are both thin observers of this object.
//
// Pure decision logic stays in the unit-tested `StrandAnalytics` engines; this is the runtime glue.
@MainActor
final class WorkoutSession: ObservableObject {

    enum Mode { case interval, goal }
    enum HapticCue { case transition, drift, done }

    // MARK: Published run state
    /// A workout is live (drives the mini bar's visibility). Stays true across navigation until Stop.
    @Published private(set) var isActive = false
    /// The full-screen view is presented (vs minimized to the mini bar). Bound by the root cover.
    @Published var presented = false
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var elapsed: Double = 0
    /// Bumped every tick so observing views recompute derived (HR/zone/distance) values each second.
    @Published private(set) var tick = 0
    /// Bumped on every cue so a root `.sensoryFeedback` fires even while minimized.
    @Published private(set) var hapticTick = 0
    @Published var simulate = false

    // MARK: Config
    private(set) var mode: Mode = .interval
    private(set) var title = ""
    private(set) var intervalPreset: IntervalPreset?
    private(set) var goalPreset: GoalPreset?
    private(set) var lastHaptic: HapticCue = .transition
    private var timeline = IntervalTimeline(steps: [])

    // MARK: Monitors
    private var zoneMonitor = ZoneAlertMonitor(low: 0, high: 0)
    private var paceMonitor: PaceAlertMonitor?
    private var lastTarget = (0, 0)

    // MARK: Simulated source
    private var simBpm = 90.0
    private var simDistance = 0.0
    private var simPace = 360.0

    // MARK: Dependencies / timer
    private weak var model: AppModel?
    private weak var behavior: BehaviorStore?
    private var timer: Timer?

    /// Wire up the shared app objects (called once at the app root).
    func configure(model: AppModel, behavior: BehaviorStore) {
        self.model = model
        self.behavior = behavior
    }

    // MARK: - Lifecycle

    func startInterval(_ p: IntervalPreset) {
        mode = .interval; intervalPreset = p; goalPreset = nil; title = p.name
        timeline = IntervalTimeline(preset: p)
        resetCommon()
        zoneMonitor = ZoneAlertMonitor(low: 0, high: 0)   // re-armed per-segment in tick
        isActive = true; running = true; presented = true
        startTimer()
    }

    func startGoal(_ p: GoalPreset) {
        mode = .goal; goalPreset = p; intervalPreset = nil; title = p.name
        resetCommon()
        simPace = p.paceRange.map { Double(($0.fastSecPerKm + $0.slowSecPerKm) / 2) } ?? 360
        zoneMonitor = ZoneAlertMonitor(low: p.targetZoneLow, high: p.targetZoneHigh,
                                       graceSeconds: 10, repeatSeconds: 30)
        paceMonitor = p.paceRange.map { PaceAlertMonitor(range: $0, graceSeconds: 12, repeatSeconds: 30) }
        isActive = true; running = true; presented = true
        if !simulate, p.needsGps, model?.gpsRecorder.isRecording == false {
            model?.gpsRecorder.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
        }
        startTimer()
    }

    private func resetCommon() {
        elapsed = 0; finished = false; lastTarget = (0, 0)
        simBpm = 90; simDistance = 0; tick = 0
    }

    func togglePlay() {
        if finished { restart(); return }
        running.toggle()
    }

    private func restart() {
        if let p = intervalPreset { startInterval(p) } else if let g = goalPreset { startGoal(g) }
    }

    func minimize() { presented = false }
    func open() { presented = true }

    func stop() {
        running = false; isActive = false; presented = false; finished = false
        timer?.invalidate(); timer = nil
        if model?.gpsRecorder.isRecording == true { _ = model?.gpsRecorder.stop() }
    }

    private func startTimer() {
        timer?.invalidate()
        // Scheduled on the main run loop; hop onto the MainActor to mutate published state safely.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    // MARK: - Live values (real source, or simulated)

    var bpm: Int? { simulate ? Int(simBpm.rounded()) : (model?.bpm ?? model?.live.heartRate) }
    var maxHR: Double { Double(model?.profile.hrMax ?? 0) }
    var currentZone: Int {
        guard let b = bpm, maxHR > 0 else { return 0 }
        return HRZones.zones(maxHR: maxHR).zoneNumber(forBPM: Double(b))
    }
    var distanceM: Double { simulate ? simDistance : (model?.gpsRecorder.distanceM ?? 0) }
    var paceSecPerKm: Double? {
        simulate ? (simPace > 0 ? simPace : nil) : model?.gpsRecorder.paceSecPerKm
    }
    var progress: IntervalProgress { timeline.progress(atElapsed: elapsed) }
    var bonded: Bool { model?.live.bonded ?? false }

    // MARK: - Tick

    private func step() {
        tick &+= 1
        if simulate { stepSimulated() }
        guard running, !finished else { return }
        elapsed += 1
        if mode == .interval { stepInterval() } else { stepGoal() }
    }

    private func stepInterval() {
        if let entered = timeline.boundaryCrossed(from: elapsed - 1, to: elapsed) {
            fireTransition(into: entered)
        }
        let p = progress
        if (p.targetZoneLow, p.targetZoneHigh) != lastTarget {
            lastTarget = (p.targetZoneLow, p.targetZoneHigh)
            zoneMonitor = ZoneAlertMonitor(low: p.targetZoneLow, high: p.targetZoneHigh,
                                           graceSeconds: 8, repeatSeconds: 25)
        }
        if zoneMonitor.isArmed, bpm != nil, let a = zoneMonitor.evaluate(zone: currentZone, at: elapsed) {
            fireDrift(above: a == .above)
        }
        // Soft 3-2-1 countdown in the final seconds of the segment — sound-only (no buzz/haptic), gated
        // on the alert-sound setting. remainingInStep is 0 once finished, so this never collides with the
        // transition cue.
        if (1...3).contains(p.remainingInStep), behavior?.zoneAlertSound == true {
            AlertSound.play(.tick)
        }
        if progress.finished { finish() }
    }

    private func stepGoal() {
        guard let g = goalPreset else { return }
        if g.isComplete(elapsedSec: elapsed, distanceM: distanceM) { finish(); return }
        if zoneMonitor.isArmed, bpm != nil, let a = zoneMonitor.evaluate(zone: currentZone, at: elapsed) {
            fireDrift(above: a == .above)
        }
        if paceMonitor?.isArmed == true, let pace = paceSecPerKm,
           let a = paceMonitor?.evaluate(paceSecPerKm: pace, at: elapsed) {
            fireDrift(above: a == .tooFast)
        }
    }

    // MARK: - Cues

    private func fireTransition(into step: IntervalStep) {
        switch step.phase {
        case .work: cue(buzz: 3, sound: .work)
        case .rest, .recover: cue(buzz: 1, sound: .rest)
        case .prepare: break
        }
        lastHaptic = .transition; hapticTick &+= 1
    }

    private func fireDrift(above: Bool) {
        cue(buzz: above ? 3 : 2, sound: above ? .tooHigh : .tooLow)
        lastHaptic = .drift; hapticTick &+= 1
    }

    private func finish() {
        finished = true; running = false
        if model?.gpsRecorder.isRecording == true { _ = model?.gpsRecorder.stop() }
        cue(buzz: 5, sound: .finished)
        lastHaptic = .done; hapticTick &+= 1
    }

    private func cue(buzz loops: UInt8, sound: AlertSound.Cue) {
        if behavior?.zoneAlertBuzz == true, model?.live.bonded == true { model?.buzz(loops: loops) }
        if behavior?.zoneAlertSound == true { AlertSound.play(sound) }
    }

    // MARK: - Simulated source

    private func stepSimulated() {
        if mode == .interval {
            let target: Double
            switch progress.phase {
            case .work: target = maxHR * 0.86
            case .rest, .recover: target = maxHR * 0.58
            case .prepare: target = maxHR * 0.50
            }
            simBpm = clampBpm(simBpm + (target - simBpm) * 0.18 + jitter())
        } else {
            let mid = goalPreset?.paceRange.map { Double(($0.fastSecPerKm + $0.slowSecPerKm) / 2) } ?? 330
            let wave = Double((Int(elapsed) % 60) - 30) * 1.2
            simPace = max(180, mid + wave + Double(Int.random(in: -4...4)))
            if running { simDistance += 1000.0 / simPace }
            let hrTarget = (goalPreset?.hasHRTarget == true)
                ? maxHR * (Double(goalPreset!.targetZoneLow) + 0.5) / 5.0
                : maxHR * 0.7
            simBpm = clampBpm(simBpm + (hrTarget - simBpm) * 0.15 + jitter())
        }
    }

    private func jitter() -> Double { Double(Int.random(in: -2...2)) }
    private func clampBpm(_ v: Double) -> Double {
        let upper = maxHR > 0 ? maxHR : 200
        return min(upper, max(45, v))
    }
}
