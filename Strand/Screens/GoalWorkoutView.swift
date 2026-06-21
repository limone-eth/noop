import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// GoalWorkoutView.swift — the live screen for a GOAL workout: hit a time/distance target while holding
// an HR zone and/or a pace band. The endurance counterpart to PlannedWorkoutView's intervals.
//
// Drives off the unit-tested `GoalPreset` (completion math), `ZoneAlertMonitor` (HR drift) and
// `PaceAlertMonitor` (pace drift). On each 1 Hz tick it reads elapsed time + GPS distance/pace
// (`AppModel.gpsRecorder`, real on device), updates goal progress, and fires a cue (sound + strap buzz
// + iPhone haptic) when HR or pace drifts out of band, plus a completion cue when the goal is reached.
// A "Simulate" toggle synthesizes HR + pace so the whole flow is demoable in the GPS-less simulator.
struct GoalWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var behavior: BehaviorStore

    let preset: GoalPreset

    // MARK: Run state
    @State private var elapsed: Double = 0
    @State private var running = false
    @State private var finished = false

    // MARK: Distance / pace (real from gpsRecorder, or simulated)
    @State private var simulate = false
    @State private var simDistance: Double = 0
    @State private var simPace: Double = 360
    @State private var simBpm: Double = 90

    // MARK: Monitors
    @State private var zoneMonitor = ZoneAlertMonitor(low: 0, high: 0)
    @State private var paceMonitor: PaceAlertMonitor?

    #if os(iOS)
    private enum HapticCue { case drift, done }
    @State private var lastHaptic: HapticCue = .drift
    @State private var hapticTick = 0
    #endif

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var distanceM: Double { simulate ? simDistance : model.gpsRecorder.distanceM }
    private var paceSecPerKm: Double? {
        simulate ? (simPace > 0 ? simPace : nil) : model.gpsRecorder.paceSecPerKm
    }
    private var bpm: Int? { simulate ? Int(simBpm.rounded()) : (model.bpm ?? live.heartRate) }
    private var maxHR: Double { Double(model.profile.hrMax) }

    private var currentZone: Int {
        guard let b = bpm, maxHR > 0 else { return 0 }
        return HRZones.zones(maxHR: maxHR).zoneNumber(forBPM: Double(b))
    }

    private var fraction: Double { preset.fractionComplete(elapsedSec: elapsed, distanceM: distanceM) ?? 0 }

    private enum ZoneStatus { case noTarget, inZone, above, below }
    private var zoneStatus: ZoneStatus {
        guard preset.hasHRTarget, bpm != nil else { return .noTarget }
        if currentZone > preset.targetZoneHigh { return .above }
        if currentZone < preset.targetZoneLow { return .below }
        return .inZone
    }

    private enum PaceStatus { case noTarget, inBand, fast, slow }
    private var paceStatus: PaceStatus {
        guard let pr = preset.paceRange, let p = paceSecPerKm, p > 0 else { return .noTarget }
        if p < Double(pr.fastSecPerKm) { return .fast }
        if p > Double(pr.slowSecPerKm) { return .slow }
        return .inBand
    }

    // MARK: Body

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(preset.name),
                       subtitle: "Goal workout — hold your zone / pace") {
            VStack(alignment: .leading, spacing: 18) {
                statusRow
                goalCard
                if preset.hasHRTarget { zoneCard }
                if preset.hasPaceTarget { paceCard }
                controls
                simulateCard
            }
        }
        .onReceive(ticker) { _ in tick() }
        .onAppear {
            rebuild()
            #if DEBUG
            if CommandLine.arguments.contains("--demo-run") { simulate = true; running = true }
            #endif
        }
        .onChangeCompat(of: running) { ScreenIdle.keepAwake($0) }
        .onDisappear { ScreenIdle.keepAwake(false); if model.gpsRecorder.isRecording { _ = model.gpsRecorder.stop() } }
        #if os(iOS)
        .sensoryFeedback(trigger: hapticTick) { _, _ in
            lastHaptic == .done ? .success : .warning
        }
        #endif
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if live.bonded { StatePill("Strap buzz on", tone: .positive) }
            else if simulate { StatePill("Simulated", tone: .accent) }
            else { StatePill("Phone alerts only", tone: .neutral, showsDot: false) }
            Spacer()
            if running { StatePill("Running", tone: .accent, pulsing: true) }
            else if finished { StatePill("Goal reached", tone: .positive) }
            else { StatePill("Ready", tone: .neutral, showsDot: false) }
        }
    }

    // MARK: Goal progress

    private var goalCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(spacing: 14) {
                HStack {
                    Text(goalLabel).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.accent)
                    Spacer()
                    Text(finished ? "DONE" : "\(Int((fraction * 100).rounded()))%")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Text(primaryValue)
                    .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                if !isOpenGoal {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(StrandPalette.accent)
                }
                HStack(spacing: 18) {
                    metric("TIME", timeString(Int(elapsed)))
                    metric("DISTANCE", distString(distanceM))
                    metric("PACE", paceString(paceSecPerKm))
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.headline).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.overline).tracking(1.2).foregroundStyle(StrandPalette.textTertiary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: HR zone card

    private var zoneCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bpm.map { "\($0)" } ?? "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("BPM").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text(currentZone >= 1 ? "ZONE \(currentZone)" : "BELOW Z1")
                        .font(StrandFont.caption).fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(StrandPalette.hrZoneColor(max(1, currentZone))))
                }
                switch zoneStatus {
                case .noTarget: statusLabel("Target Zone \(zoneBand) — waiting for HR", StrandPalette.textSecondary, "heart")
                case .inZone:   statusLabel("IN ZONE \(zoneBand)", StrandPalette.restColor, "checkmark.circle.fill")
                case .above:    statusLabel("EASE OFF — above Zone \(preset.targetZoneHigh)", StrandPalette.effortColor, "arrow.down.circle.fill")
                case .below:    statusLabel("PUSH — below Zone \(preset.targetZoneLow)", StrandPalette.accent, "arrow.up.circle.fill")
                }
            }
        }
    }

    private var zoneBand: String {
        preset.targetZoneLow == preset.targetZoneHigh ? "\(preset.targetZoneLow)"
            : "\(preset.targetZoneLow)–\(preset.targetZoneHigh)"
    }

    // MARK: Pace card

    private var paceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(paceString(paceSecPerKm))
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("/KM").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    if let pr = preset.paceRange {
                        Text("\(paceString(Double(pr.fastSecPerKm)))–\(paceString(Double(pr.slowSecPerKm)))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                switch paceStatus {
                case .noTarget: statusLabel("Target pace — waiting for GPS", StrandPalette.textSecondary, "location")
                case .inBand:   statusLabel("ON PACE", StrandPalette.restColor, "checkmark.circle.fill")
                case .fast:     statusLabel("EASE OFF — faster than target", StrandPalette.effortColor, "arrow.down.circle.fill")
                case .slow:     statusLabel("PUSH — slower than target", StrandPalette.accent, "arrow.up.circle.fill")
                }
            }
        }
    }

    private func statusLabel(_ text: String, _ color: Color, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(StrandFont.subhead).fontWeight(.semibold).foregroundStyle(color)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button(running ? "Pause" : (finished ? "Restart" : (elapsed > 0 ? "Resume" : "Start"))) {
                if finished { rebuild() }
                running.toggle()
                if running, !simulate, preset.needsGps, !model.gpsRecorder.isRecording {
                    model.gpsRecorder.start(startMs: Int64(Date().timeIntervalSince1970 * 1000))
                }
            }
            .font(StrandFont.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.accent))

            Button("Reset") { rebuild() }
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    private var simulateCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $simulate) {
                    Text("Simulate (no strap / GPS)").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                }.tint(StrandPalette.accent)
                Text("Synthesizes heart rate and pace so the zone + pace alerts can be demoed in the simulator. Turn off to use your real strap + GPS.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Engine

    private func rebuild() {
        elapsed = 0; running = false; finished = false
        simDistance = 0; simPace = preset.paceRange.map { Double(($0.fastSecPerKm + $0.slowSecPerKm) / 2) } ?? 360
        simBpm = 90
        zoneMonitor = ZoneAlertMonitor(low: preset.targetZoneLow, high: preset.targetZoneHigh,
                                       graceSeconds: 10, repeatSeconds: 30)
        paceMonitor = preset.paceRange.map { PaceAlertMonitor(range: $0, graceSeconds: 12, repeatSeconds: 30) }
        if model.gpsRecorder.isRecording { _ = model.gpsRecorder.stop() }
    }

    private func tick() {
        if simulate { stepSimulated() }
        guard running, !finished else { return }
        elapsed += 1

        if preset.isComplete(elapsedSec: elapsed, distanceM: distanceM) { finishWorkout(); return }

        if zoneMonitor.isArmed, bpm != nil, let a = zoneMonitor.evaluate(zone: currentZone, at: elapsed) {
            fireDrift(zoneAbove: a == .above)
        }
        if paceMonitor?.isArmed == true, let p = paceSecPerKm,
           let a = paceMonitor?.evaluate(paceSecPerKm: p, at: elapsed) {
            fireDrift(zoneAbove: a == .tooFast)   // tooFast → ease off (same "above" cue)
        }
    }

    private func fireDrift(zoneAbove: Bool) {
        cue(buzzLoops: zoneAbove ? 3 : 2, sound: zoneAbove ? .tooHigh : .tooLow)
        #if os(iOS)
        lastHaptic = .drift; hapticTick &+= 1
        #endif
    }

    private func finishWorkout() {
        finished = true; running = false
        if model.gpsRecorder.isRecording { _ = model.gpsRecorder.stop() }
        cue(buzzLoops: 5, sound: .finished)
        #if os(iOS)
        lastHaptic = .done; hapticTick &+= 1
        #endif
    }

    private func cue(buzzLoops: UInt8, sound: AlertSound.Cue) {
        if behavior.zoneAlertBuzz, live.bonded { model.buzz(loops: buzzLoops) }
        if behavior.zoneAlertSound { AlertSound.play(sound) }
    }

    /// Synthetic HR + pace that wander toward the target band, occasionally drifting out to demo alerts.
    private func stepSimulated() {
        // Pace: wander around the band midpoint with a slow excursion so a drift alert eventually fires.
        let target = preset.paceRange.map { Double(($0.fastSecPerKm + $0.slowSecPerKm) / 2) } ?? 330
        let wave = Double((Int(elapsed) % 60) - 30) * 1.2   // ±36s/km excursion over a minute
        simPace = max(180, target + wave + Double(Int.random(in: -4...4)))
        if running { simDistance += 1000.0 / simPace }      // metres this second
        // HR toward the zone target (or moderate).
        let hrTarget = preset.hasHRTarget
            ? maxHR * (Double(preset.targetZoneLow) + 0.5) / 10.0 * 2   // ~mid of the target zone band
            : maxHR * 0.7
        simBpm = min(maxHR, max(50, simBpm + (hrTarget - simBpm) * 0.15 + Double(Int.random(in: -2...2))))
    }

    // MARK: Formatting

    private var goalLabel: String {
        switch preset.goal {
        case .open: return "OPEN SESSION"
        case .duration: return "TIME GOAL"
        case .distance: return "DISTANCE GOAL"
        }
    }
    private var isOpenGoal: Bool { if case .open = preset.goal { return true }; return false }
    private var primaryValue: String {
        switch preset.goal {
        case .open: return timeString(Int(elapsed))
        case .duration(let s): return timeString(max(0, s - Int(elapsed)))   // countdown
        case .distance(let m): return distString(max(0, Double(m) - distanceM))
        }
    }
    private func timeString(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    private func distString(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m"
    }
    private func paceString(_ s: Double?) -> String {
        guard let s, s > 0, s.isFinite else { return "—" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
