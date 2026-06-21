import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// PlannedWorkoutView.swift — the live screen for a STRUCTURED interval workout with HR-zone targeting.
//
// Driven by the unit-tested `IntervalTimeline` (prepare/work/rest/rounds/cycles) and `ZoneAlertMonitor`
// (planned-zone drift). On every 1 Hz tick it resolves the current segment, fires a TRANSITION cue when
// the timeline crosses a segment boundary (sound + strap buzz + iPhone haptic), and — while a segment
// carries a target HR band — fires a DRIFT cue when the live HR sits outside that band past the grace
// window. With no strap bonded it still runs as a glanceable visual timer; a "Simulate HR" toggle lets
// the whole flow be exercised in the simulator, which has no Bluetooth radio.
struct PlannedWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var behavior: BehaviorStore

    let preset: IntervalPreset

    // MARK: Run state
    @State private var timeline: IntervalTimeline = IntervalTimeline(steps: [])
    @State private var elapsed: Double = 0          // seconds since start, accrues only while running
    @State private var prevElapsed: Double = 0
    @State private var running = false
    @State private var finished = false

    // MARK: HR / zone state
    @State private var zoneMonitor = ZoneAlertMonitor(low: 0, high: 0)
    @State private var lastTarget: (Int, Int) = (0, 0)
    @State private var simulateHR = false
    @State private var simBpm: Double = 90

    // MARK: iPhone haptics (mirror every cue so it works unstrapped)
    #if os(iOS)
    private enum HapticCue { case transition, drift, done }
    @State private var lastHaptic: HapticCue = .transition
    @State private var hapticTick = 0
    #endif

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // MARK: Derived

    private var progress: IntervalProgress { timeline.progress(atElapsed: elapsed) }

    /// Live bpm: the simulated source when armed, else the smoothed strap HR, else the raw HR.
    private var bpm: Int? {
        if simulateHR { return Int(simBpm.rounded()) }
        return model.bpm ?? live.heartRate
    }

    private var maxHR: Double { Double(model.profile.hrMax) }

    private var currentZone: Int {
        guard let b = bpm, maxHR > 0 else { return 0 }
        return HRZones.zones(maxHR: maxHR).zoneNumber(forBPM: Double(b))
    }

    /// Status of the live HR relative to the current segment's planned band.
    private enum ZoneStatus { case noTarget, inZone, above, below }
    private var zoneStatus: ZoneStatus {
        let lo = progress.targetZoneLow, hi = progress.targetZoneHigh
        guard lo >= 1, hi >= 1, bpm != nil else { return .noTarget }
        if currentZone > hi { return .above }
        if currentZone < lo { return .below }
        return .inZone
    }

    private var phaseColor: Color {
        switch progress.phase {
        case .prepare: return StrandPalette.accent
        case .work:    return StrandPalette.effortColor
        case .rest:    return StrandPalette.restColor
        case .recover: return StrandPalette.restColor
        }
    }

    private var phaseLabel: String {
        if finished { return "DONE" }
        switch progress.phase {
        case .prepare: return "PREPARE"
        case .work:    return "WORK"
        case .rest:    return "REST"
        case .recover: return "RECOVER"
        }
    }

    // MARK: Body

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(preset.name),
                       subtitle: "Interval workout — sound + buzz on every change") {
            VStack(alignment: .leading, spacing: 18) {
                statusRow
                heroCard
                zoneCard
                controls
                hrSourceCard
            }
        }
        .onReceive(ticker) { _ in tick() }
        .onAppear {
            rebuild()
            #if DEBUG
            if CommandLine.arguments.contains("--demo-run") { simulateHR = true; running = true }
            #endif
        }
        .onChangeCompat(of: running) { ScreenIdle.keepAwake($0) }
        .onDisappear { ScreenIdle.keepAwake(false) }
        #if os(iOS)
        .sensoryFeedback(trigger: hapticTick) { _, _ in
            switch lastHaptic {
            case .transition: return .impact(weight: .heavy)
            case .drift:      return .warning
            case .done:       return .success
            }
        }
        #endif
    }

    // MARK: Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            if live.bonded {
                StatePill("Strap buzz on", tone: .positive)
            } else if simulateHR {
                StatePill("Simulated HR", tone: .accent)
            } else {
                StatePill("Phone alerts only", tone: .neutral, showsDot: false)
            }
            Spacer()
            if running { StatePill("Running", tone: .accent, pulsing: true) }
            else if finished { StatePill("Complete", tone: .positive) }
            else { StatePill("Ready", tone: .neutral, showsDot: false) }
        }
    }

    // MARK: Hero — phase + big countdown

    private var heroCard: some View {
        NoopCard(tint: phaseColor) {
            VStack(spacing: 12) {
                HStack {
                    Text(phaseLabel)
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(phaseColor)
                    Spacer()
                    if progress.cycle > 0 {
                        Text("R\(progress.round) · C\(progress.cycle)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(finished ? "✓" : timeString(progress.remainingInStep))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                HStack(spacing: 18) {
                    metric("ROUNDS LEFT", progress.roundsLeft > 0 ? "\(progress.roundsLeft)" : "—")
                    metric("CYCLES LEFT", progress.cyclesLeft > 0 ? "\(progress.cyclesLeft)" : "—")
                    metric("TOTAL LEFT", timeString(progress.totalRemaining))
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.headline).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.overline).tracking(1.2)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Zone card — live HR vs target band

    private var zoneCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bpm.map { "\($0)" } ?? "—")
                        .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("BPM").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    zoneBadge
                }
                targetRow
            }
        }
    }

    private var zoneBadge: some View {
        let z = currentZone
        return Text(z >= 1 ? "ZONE \(z)" : "BELOW Z1")
            .font(StrandFont.caption).fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(StrandPalette.hrZoneColor(max(1, z))))
    }

    @ViewBuilder private var targetRow: some View {
        switch zoneStatus {
        case .noTarget:
            Text(progress.targetZoneLow >= 1
                 ? "Target Zone \(zoneBandText) — waiting for HR"
                 : "No HR target on this segment")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        case .inZone:
            statusLabel("IN ZONE \(zoneBandText)", StrandPalette.restColor, "checkmark.circle.fill")
        case .above:
            statusLabel("EASE OFF — above Zone \(progress.targetZoneHigh)", StrandPalette.effortColor, "arrow.down.circle.fill")
        case .below:
            statusLabel("PUSH — below Zone \(progress.targetZoneLow)", StrandPalette.accent, "arrow.up.circle.fill")
        }
    }

    private var zoneBandText: String {
        progress.targetZoneLow == progress.targetZoneHigh
            ? "\(progress.targetZoneLow)"
            : "\(progress.targetZoneLow)–\(progress.targetZoneHigh)"
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

    // MARK: HR source

    private var hrSourceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $simulateHR) {
                    Text("Simulate HR (no strap)").font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .tint(StrandPalette.accent)
                Text("The simulator has no Bluetooth. Turn this on to drive the zone alerts with a synthetic heart rate that drifts with the work/rest phases.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: - Tick / engine

    private func rebuild() {
        timeline = IntervalTimeline(preset: preset)
        elapsed = 0; prevElapsed = 0; running = false; finished = false
        lastTarget = (0, 0)
        zoneMonitor = ZoneAlertMonitor(low: 0, high: 0)
        simBpm = 90
    }

    private func tick() {
        if simulateHR { stepSimulatedHR() }
        guard running, !finished else { return }
        prevElapsed = elapsed
        elapsed += 1

        // Segment transition → cue.
        if let entered = timeline.boundaryCrossed(from: prevElapsed, to: elapsed) {
            fireTransition(into: entered)
        }

        // Re-arm the zone monitor when the active segment's target band changes.
        let p = progress
        if (p.targetZoneLow, p.targetZoneHigh) != lastTarget {
            lastTarget = (p.targetZoneLow, p.targetZoneHigh)
            zoneMonitor = ZoneAlertMonitor(low: p.targetZoneLow, high: p.targetZoneHigh,
                                           graceSeconds: 8, repeatSeconds: 25)
        }
        // Zone drift → cue (only on real/sim HR and an armed band).
        if zoneMonitor.isArmed, bpm != nil {
            if let alert = zoneMonitor.evaluate(zone: currentZone, at: elapsed) {
                fireDrift(alert)
            }
        }

        if progress.finished { finishWorkout() }
    }

    private func fireTransition(into step: IntervalStep) {
        switch step.phase {
        case .work:    cue(buzzLoops: 3, sound: .work)
        case .rest, .recover: cue(buzzLoops: 1, sound: .rest)
        case .prepare: break
        }
        #if os(iOS)
        lastHaptic = .transition; hapticTick &+= 1
        #endif
    }

    private func fireDrift(_ alert: ZoneAlertKind) {
        cue(buzzLoops: alert == .above ? 3 : 2, sound: alert == .above ? .tooHigh : .tooLow)
        #if os(iOS)
        lastHaptic = .drift; hapticTick &+= 1
        #endif
    }

    private func finishWorkout() {
        finished = true; running = false
        cue(buzzLoops: 5, sound: .finished)
        #if os(iOS)
        lastHaptic = .done; hapticTick &+= 1
        #endif
    }

    /// Fire the enabled alert channels: strap buzz (bonded only) + phone sound (per settings).
    private func cue(buzzLoops: UInt8, sound: AlertSound.Cue) {
        if behavior.zoneAlertBuzz, live.bonded { model.buzz(loops: buzzLoops) }
        if behavior.zoneAlertSound { AlertSound.play(sound) }
    }

    // MARK: Simulated HR — a phase-aware wander so the zone alerts can be demoed without a strap.

    private func stepSimulatedHR() {
        let target: Double
        switch progress.phase {
        case .work:    target = maxHR * 0.86    // climbs into Zone 4–5
        case .rest, .recover: target = maxHR * 0.58
        case .prepare: target = maxHR * 0.50
        }
        let drift = (target - simBpm) * 0.18
        let noise = Double(Int.random(in: -2...2))
        simBpm = min(maxHR, max(45, simBpm + drift + noise))
    }

    private func timeString(_ s: Int) -> String {
        let m = s / 60, sec = s % 60
        return m > 0 ? String(format: "%d:%02d", m, sec) : "\(sec)"
    }
}
