import SwiftUI
import StrandDesign
import StrandAnalytics

// ActiveWorkoutView.swift — the full-screen UI for the live session + the persistent mini "now playing"
// bar. Both are thin observers of `WorkoutSession`; the session keeps running across navigation, so the
// mini bar stays up (rendered at the app root) until the user Stops. The full screen is presented as a
// cover and can be minimized back to the bar.

struct ActiveWorkoutView: View {
    @EnvironmentObject private var session: WorkoutSession

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if session.mode == .interval { intervalBody } else { goalBody }
                    controls
                    simulateCard
                }
                .padding(20)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    // MARK: Header (minimize + title + stop)

    private var header: some View {
        HStack(spacing: 12) {
            Button { session.minimize() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(session.running ? "Running" : (session.finished ? "Complete" : "Paused"))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Button { session.stop() } label: {
                Text("Stop").font(StrandFont.subhead).fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(StrandPalette.metricRose))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    // MARK: Interval body

    private var intervalBody: some View {
        let p = session.progress
        return VStack(alignment: .leading, spacing: 18) {
            NoopCard(tint: phaseColor(p.phase)) {
                VStack(spacing: 12) {
                    HStack {
                        Text(session.finished ? "DONE" : phaseLabel(p.phase))
                            .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(phaseColor(p.phase))
                        Spacer()
                        if p.cycle > 0 {
                            Text("R\(p.round) · C\(p.cycle)").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Text(session.finished ? "✓" : timeStr(p.remainingInStep))
                        .font(.system(size: 76, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary).contentTransition(.numericText())
                    HStack(spacing: 18) {
                        metric("ROUNDS LEFT", p.roundsLeft > 0 ? "\(p.roundsLeft)" : "—")
                        metric("CYCLES LEFT", p.cyclesLeft > 0 ? "\(p.cyclesLeft)" : "—")
                        metric("TOTAL LEFT", timeStr(p.totalRemaining))
                    }
                }
            }
            hrZoneCard(targetLow: p.targetZoneLow, targetHigh: p.targetZoneHigh)
        }
    }

    // MARK: Goal body

    private var goalBody: some View {
        let g = session.goalPreset
        return VStack(alignment: .leading, spacing: 18) {
            NoopCard(tint: StrandPalette.accent) {
                VStack(spacing: 14) {
                    HStack {
                        Text(goalLabel).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.accent)
                        Spacer()
                        Text(session.finished ? "DONE" : "\(Int((goalFraction * 100).rounded()))%")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text(goalPrimary)
                        .font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary).contentTransition(.numericText())
                    if !isOpenGoal { ProgressView(value: min(1, max(0, goalFraction))).tint(StrandPalette.accent) }
                    HStack(spacing: 18) {
                        metric("TIME", timeStr(Int(session.elapsed)))
                        metric("DISTANCE", distStr(session.distanceM))
                        metric("PACE", paceStr(session.paceSecPerKm))
                    }
                }
            }
            if g?.hasHRTarget == true { hrZoneCard(targetLow: g!.targetZoneLow, targetHigh: g!.targetZoneHigh) }
            if let pr = g?.paceRange { paceCard(pr) }
        }
    }

    // MARK: Shared cards

    private func hrZoneCard(targetLow: Int, targetHigh: Int) -> some View {
        let z = session.currentZone
        let hasTarget = targetLow >= 1 && targetHigh >= 1
        let status: (String, Color, String)? = {
            guard hasTarget, session.bpm != nil else { return nil }
            if z > targetHigh { return ("EASE OFF — above Zone \(targetHigh)", StrandPalette.effortColor, "arrow.down.circle.fill") }
            if z < targetLow { return ("PUSH — below Zone \(targetLow)", StrandPalette.accent, "arrow.up.circle.fill") }
            let band = targetLow == targetHigh ? "\(targetLow)" : "\(targetLow)–\(targetHigh)"
            return ("IN ZONE \(band)", StrandPalette.restColor, "checkmark.circle.fill")
        }()
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.bpm.map { "\($0)" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("BPM").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text(z >= 1 ? "ZONE \(z)" : "BELOW Z1").font(StrandFont.caption).fontWeight(.semibold)
                        .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(StrandPalette.hrZoneColor(max(1, z))))
                }
                if let s = status { statusLabel(s.0, s.1, s.2) }
                else { Text(hasTarget ? "Target zone — waiting for HR" : "No HR target")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary) }
            }
        }
    }

    private func paceCard(_ pr: PaceRange) -> some View {
        let p = session.paceSecPerKm
        let status: (String, Color, String)? = {
            guard let p, p > 0 else { return nil }
            if p < Double(pr.fastSecPerKm) { return ("EASE OFF — faster than target", StrandPalette.effortColor, "arrow.down.circle.fill") }
            if p > Double(pr.slowSecPerKm) { return ("PUSH — slower than target", StrandPalette.accent, "arrow.up.circle.fill") }
            return ("ON PACE", StrandPalette.restColor, "checkmark.circle.fill")
        }()
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(paceStr(p)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("/KM").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    Text("\(paceStr(Double(pr.fastSecPerKm)))–\(paceStr(Double(pr.slowSecPerKm)))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let s = status { statusLabel(s.0, s.1, s.2) }
                else { Text("Target pace — waiting for GPS").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(session.running ? "Pause" : (session.finished ? "Restart" : "Resume")) { session.togglePlay() }
                .font(StrandFont.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.accent))
            Button("Stop") { session.stop() }
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    private var simulateCard: some View {
        NoopCard {
            Toggle(isOn: $session.simulate) {
                Text("Simulate HR / pace (no strap / GPS)").font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
            }.tint(StrandPalette.accent)
        }
    }

    // MARK: helpers

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.headline).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.overline).tracking(1.2).foregroundStyle(StrandPalette.textTertiary)
        }.frame(maxWidth: .infinity)
    }
    private func statusLabel(_ t: String, _ c: Color, _ icon: String) -> some View {
        HStack(spacing: 6) { Image(systemName: icon).foregroundStyle(c)
            Text(t).font(StrandFont.subhead).fontWeight(.semibold).foregroundStyle(c) }
    }
    private func phaseColor(_ p: IntervalPhase) -> Color {
        switch p { case .prepare: return StrandPalette.accent; case .work: return StrandPalette.effortColor
        case .rest, .recover: return StrandPalette.restColor }
    }
    private func phaseLabel(_ p: IntervalPhase) -> String {
        switch p { case .prepare: return "PREPARE"; case .work: return "WORK"; case .rest: return "REST"; case .recover: return "RECOVER" }
    }
    private var goalLabel: String {
        switch session.goalPreset?.goal { case .duration: return "TIME GOAL"; case .distance: return "DISTANCE GOAL"; default: return "OPEN SESSION" }
    }
    private var isOpenGoal: Bool { if case .open = session.goalPreset?.goal { return true }; return session.goalPreset == nil }
    private var goalFraction: Double { session.goalPreset?.fractionComplete(elapsedSec: session.elapsed, distanceM: session.distanceM) ?? 0 }
    private var goalPrimary: String {
        switch session.goalPreset?.goal {
        case .duration(let s): return timeStr(max(0, s - Int(session.elapsed)))
        case .distance(let m): return distStr(max(0, Double(m) - session.distanceM))
        default: return timeStr(Int(session.elapsed))
        }
    }
    private func timeStr(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    private func distStr(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m" }
    private func paceStr(_ s: Double?) -> String { guard let s, s > 0, s.isFinite else { return "—" }; return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Mini "now playing" bar

/// The persistent active-workout bar shown at the app root whenever a session is live and the full
/// screen is minimized. Tap to reopen; a Stop button ends it.
struct WorkoutMiniBar: View {
    @EnvironmentObject private var session: WorkoutSession

    var body: some View {
        Button { session.open() } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: session.running ? "figure.run" : "pause.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(StrandFont.subhead).fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                    Text(statusLine).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let b = session.bpm {
                    Text("\(b)").font(StrandFont.subhead).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(StrandPalette.hrZoneColor(max(1, session.currentZone))))
                }
                Button { session.togglePlay() } label: {
                    Image(systemName: session.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 30, height: 30)
                }.buttonStyle(.plain)
                Button { session.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(StrandPalette.metricRose).frame(width: 30, height: 30)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    private var accent: Color {
        guard session.mode == .interval else { return StrandPalette.accent }
        switch session.progress.phase {
        case .work: return StrandPalette.effortColor
        case .rest, .recover: return StrandPalette.restColor
        case .prepare: return StrandPalette.accent
        }
    }

    private var statusLine: String {
        if session.mode == .interval {
            let p = session.progress
            let label = session.finished ? "Done" : phaseLabel(p.phase)
            return session.finished ? label : "\(label) · \(timeStr(p.remainingInStep))"
        } else {
            let pct = Int((((session.goalPreset?.fractionComplete(elapsedSec: session.elapsed, distanceM: session.distanceM)) ?? 0) * 100).rounded())
            return session.finished ? "Goal reached" : "\(distStr(session.distanceM)) · \(pct)%"
        }
    }
    private func phaseLabel(_ p: IntervalPhase) -> String {
        switch p { case .prepare: return "Prepare"; case .work: return "Work"; case .rest: return "Rest"; case .recover: return "Recover" }
    }
    private func timeStr(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    private func distStr(_ m: Double) -> String { m >= 1000 ? String(format: "%.2f km", m / 1000) : "\(Int(m)) m" }
}
