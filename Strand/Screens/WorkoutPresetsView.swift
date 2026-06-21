import SwiftUI
import StrandDesign
import StrandAnalytics

// WorkoutPresetsView.swift — the saveable workout library + the TimerPlus-style interval builder.
//
// Lists the user's interval presets (Tabata / HIIT / circuits); tapping one launches the live
// `PlannedWorkoutView`. The "+" opens `IntervalPresetBuilderView` to create a new one; an existing
// preset can be edited or deleted. Goal-based presets (run X km/min in a band) are modelled + tested in
// `StrandAnalytics` and shown read-only here pending their own live screen.
struct WorkoutPresetsView: View {
    @EnvironmentObject private var presets: WorkoutPresetStore
    @State private var editing: IntervalPreset?
    @State private var creatingNew = false

    var body: some View {
        ScreenScaffold(title: "Workouts", subtitle: "Interval & zone presets") {
            VStack(alignment: .leading, spacing: 24) {
                intervalSection
                if !presets.goals.isEmpty { goalSection }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creatingNew = true } label: { Image(systemName: "plus") }
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        .sheet(isPresented: $creatingNew) {
            IntervalPresetBuilderView(preset: nil) { presets.save($0) }
        }
        .sheet(item: $editing) { p in
            IntervalPresetBuilderView(preset: p) { presets.save($0) }
        }
    }

    private var intervalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INTERVALS").strandOverline()
            ForEach(presets.intervals) { p in
                NavigationLink { PlannedWorkoutView(preset: p) } label: { intervalRow(p) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") { editing = p }
                        Button("Delete", role: .destructive) { presets.deleteInterval(id: p.id) }
                    }
            }
        }
    }

    private func intervalRow(_ p: IntervalPreset) -> some View {
        NoopCard {
            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.system(size: 20)).foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(summary(p)).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                if p.targetZoneLow >= 1 {
                    Text(p.targetZoneLow == p.targetZoneHigh ? "Z\(p.targetZoneLow)" : "Z\(p.targetZoneLow)–\(p.targetZoneHigh)")
                        .font(StrandFont.caption).fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(StrandPalette.hrZoneColor(p.targetZoneHigh)))
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func summary(_ p: IntervalPreset) -> String {
        var parts: [String] = []
        if p.prepareSec > 0 { parts.append("\(p.prepareSec)s prep") }
        parts.append("\(p.workSec)s work")
        if p.restSec > 0 { parts.append("\(p.restSec)s rest") }
        parts.append("×\(p.rounds)")
        if p.cycles > 1 { parts.append("· \(p.cycles) cycles") }
        let mins = p.totalSeconds / 60, secs = p.totalSeconds % 60
        parts.append("· \(mins):\(String(format: "%02d", secs))")
        return parts.joined(separator: " ")
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GOALS").strandOverline()
            ForEach(presets.goals) { g in
                NoopCard {
                    HStack(spacing: 14) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 20)).foregroundStyle(StrandPalette.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(g.name).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                            Text(goalSummary(g)).font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                    }
                }
            }
            Text("Goal workouts (time/distance held in a zone or pace band) are coming to a live GPS screen next.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func goalSummary(_ g: GoalPreset) -> String {
        var s: String
        switch g.goal {
        case .open: s = "Open"
        case .duration(let sec): s = "\(sec / 60) min"
        case .distance(let m): s = m >= 1000 ? "\(m / 1000) km" : "\(m) m"
        }
        if g.targetZoneLow >= 1 { s += " · Zone \(g.targetZoneLow == g.targetZoneHigh ? "\(g.targetZoneLow)" : "\(g.targetZoneLow)–\(g.targetZoneHigh)")" }
        if let pr = g.paceRange { s += " · \(pace(pr.fastSecPerKm))–\(pace(pr.slowSecPerKm))/km" }
        return s
    }

    private func pace(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

// MARK: - Interval builder (TimerPlus-style)

/// Create or edit an `IntervalPreset`: name, prepare, work, rest, rounds, cycles, rest-between-cycles,
/// and an optional target HR-zone band. Mirrors the TimerPlus "custom workout" editor.
struct IntervalPresetBuilderView: View {
    @Environment(\.dismiss) private var dismiss

    let original: IntervalPreset?
    let onSave: (IntervalPreset) -> Void

    @State private var name: String
    @State private var prepareSec: Int
    @State private var workSec: Int
    @State private var restSec: Int
    @State private var rounds: Int
    @State private var cycles: Int
    @State private var restBetweenCyclesSec: Int
    @State private var targetZoneLow: Int
    @State private var targetZoneHigh: Int

    init(preset: IntervalPreset?, onSave: @escaping (IntervalPreset) -> Void) {
        self.original = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "New Workout")
        _prepareSec = State(initialValue: preset?.prepareSec ?? 10)
        _workSec = State(initialValue: preset?.workSec ?? 30)
        _restSec = State(initialValue: preset?.restSec ?? 15)
        _rounds = State(initialValue: preset?.rounds ?? 8)
        _cycles = State(initialValue: preset?.cycles ?? 1)
        _restBetweenCyclesSec = State(initialValue: preset?.restBetweenCyclesSec ?? 60)
        _targetZoneLow = State(initialValue: preset?.targetZoneLow ?? 0)
        _targetZoneHigh = State(initialValue: preset?.targetZoneHigh ?? 0)
    }

    private var built: IntervalPreset {
        IntervalPreset(id: original?.id ?? "user.\(Int(Date().timeIntervalSince1970))",
                       name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Workout" : name,
                       prepareSec: prepareSec, workSec: workSec, restSec: restSec, rounds: rounds,
                       cycles: cycles, restBetweenCyclesSec: restBetweenCyclesSec,
                       targetZoneLow: targetZoneLow, targetZoneHigh: targetZoneHigh)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Workout name", text: $name)
                }
                Section("Intervals") {
                    stepper("Prepare", $prepareSec, 0...120, step: 5, unit: "s")
                    stepper("Work", $workSec, 5...3600, step: 5, unit: "s")
                    stepper("Rest", $restSec, 0...3600, step: 5, unit: "s")
                    stepper("Rounds", $rounds, 1...50, step: 1, unit: "")
                    stepper("Cycles", $cycles, 1...20, step: 1, unit: "")
                    if cycles > 1 {
                        stepper("Rest between cycles", $restBetweenCyclesSec, 0...600, step: 5, unit: "s")
                    }
                }
                Section("Target HR zone (optional)") {
                    Picker("Low", selection: $targetZoneLow) { zoneOptions }
                    Picker("High", selection: $targetZoneHigh) { zoneOptions }
                    Text(targetZoneLow >= 1
                         ? "Alerts when HR leaves the band during work."
                         : "No HR target — timer + transition cues only.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    let s = built.totalSeconds
                    LabeledContent("Total time", value: "\(s / 60):\(String(format: "%02d", s % 60))")
                }
            }
            .navigationTitle(original == nil ? "New Workout" : "Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: targetZoneLow) { _, v in if targetZoneHigh < v { targetZoneHigh = v } }
            .onChange(of: targetZoneHigh) { _, v in if v >= 1 && targetZoneLow == 0 { targetZoneLow = v } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(built); dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private var zoneOptions: some View {
        Text("None").tag(0)
        ForEach(1...5, id: \.self) { Text("Zone \($0)").tag($0) }
    }

    private func stepper(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>,
                         step: Int, unit: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text(unit == "s" && value.wrappedValue >= 60
                     ? "\(value.wrappedValue / 60):\(String(format: "%02d", value.wrappedValue % 60))"
                     : "\(value.wrappedValue)\(unit)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
