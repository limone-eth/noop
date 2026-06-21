import Foundation

// IntervalPlan.swift — TimerPlus-style structured interval workouts (prepare / work / rest /
// rounds / cycles / rest-between-cycles), plus a pure timeline engine.
//
// The whole app's two workout shapes collapse onto ONE model: a workout is an ordered list of timed
// segments, each optionally carrying a planned HR-zone band ([targetZoneLow, targetZoneHigh]).
//   • A free outdoor RUN is a single open-ended segment with a target zone (duration 0 = open-ended).
//   • A Tabata / HIIT circuit is many fixed-duration work/rest segments.
//
// `IntervalPreset` is the saveable, user-editable definition (the "Create custom workout" sheet binds
// to it). `IntervalPreset.steps()` expands it into a flat `[IntervalStep]` timeline, and
// `IntervalTimeline` answers "which step am I in at elapsed time T?" and "did I just cross a boundary?"
// — the two questions the live timer screen and the cue/buzz dispatcher need.
//
// Everything here is pure value types (no Combine / CoreLocation / CoreBluetooth) so the expansion and
// the time math are fully unit-testable off any platform clock. HR-zone evaluation is layered on top by
// `ZoneAlertMonitor`, reading each step's target band.

/// The kind of a single timed segment. Drives the live screen's colour + the spoken/haptic cue.
public enum IntervalPhase: String, Codable, Equatable, Sendable, CaseIterable {
    case prepare   // lead-in countdown before the first work block
    case work      // an effort interval
    case rest      // recovery between rounds
    case recover   // longer recovery between cycles ("rest between cycles")
}

/// One concrete segment in an expanded timeline.
public struct IntervalStep: Equatable, Sendable {
    public let phase: IntervalPhase
    /// Segment length in seconds. 0 means OPEN-ENDED (only valid as a lone segment, e.g. a free run).
    public let duration: Int
    /// 1-based round index within its cycle (0 for prepare / cross-cycle recover).
    public let round: Int
    /// 1-based cycle index (0 for prepare).
    public let cycle: Int
    /// Planned HR-zone band for this segment (1...5); 0/0 means "no target".
    public let targetZoneLow: Int
    public let targetZoneHigh: Int

    public init(phase: IntervalPhase, duration: Int, round: Int = 0, cycle: Int = 0,
                targetZoneLow: Int = 0, targetZoneHigh: Int = 0) {
        self.phase = phase
        self.duration = max(0, duration)
        self.round = round
        self.cycle = cycle
        self.targetZoneLow = targetZoneLow
        self.targetZoneHigh = targetZoneHigh
    }

    /// True when the segment never ends on its own (the timeline runs until the user stops).
    public var isOpenEnded: Bool { duration == 0 }
}

/// A saveable, user-editable interval workout definition — the TimerPlus "custom workout" shape.
public struct IntervalPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Lead-in countdown before the first work block (seconds; 0 = none).
    public var prepareSec: Int
    /// Work interval length (seconds).
    public var workSec: Int
    /// Rest interval length between rounds (seconds; 0 = back-to-back work).
    public var restSec: Int
    /// Rounds per cycle. "One round is work + rest."
    public var rounds: Int
    /// Number of cycles. "One cycle is `rounds` rounds."
    public var cycles: Int
    /// Recovery between cycles (seconds; 0 = none). Not added after the final cycle.
    public var restBetweenCyclesSec: Int
    /// Default planned HR-zone band applied to every WORK step (1...5); 0/0 = no target.
    public var targetZoneLow: Int
    public var targetZoneHigh: Int
    /// When true, the final rest of the final round of the final cycle is dropped (the workout ends on
    /// the last work block rather than a trailing rest — TimerPlus's common "no dangling rest" behaviour).
    public var trimTrailingRest: Bool

    public init(id: String, name: String, prepareSec: Int = 10, workSec: Int = 30, restSec: Int = 10,
                rounds: Int = 8, cycles: Int = 1, restBetweenCyclesSec: Int = 60,
                targetZoneLow: Int = 0, targetZoneHigh: Int = 0, trimTrailingRest: Bool = true) {
        self.id = id
        self.name = name
        self.prepareSec = max(0, prepareSec)
        self.workSec = max(0, workSec)
        self.restSec = max(0, restSec)
        self.rounds = max(1, rounds)
        self.cycles = max(1, cycles)
        self.restBetweenCyclesSec = max(0, restBetweenCyclesSec)
        self.targetZoneLow = targetZoneLow
        self.targetZoneHigh = targetZoneHigh
        self.trimTrailingRest = trimTrailingRest
    }

    /// Expand the preset into a flat, ordered timeline of concrete segments.
    public func steps() -> [IntervalStep] {
        var out: [IntervalStep] = []
        if prepareSec > 0 {
            out.append(IntervalStep(phase: .prepare, duration: prepareSec))
        }
        for c in 1...cycles {
            for r in 1...rounds {
                if workSec > 0 {
                    out.append(IntervalStep(phase: .work, duration: workSec, round: r, cycle: c,
                                            targetZoneLow: targetZoneLow, targetZoneHigh: targetZoneHigh))
                }
                let isFinalRound = (c == cycles && r == rounds)
                if restSec > 0 && !(isFinalRound && trimTrailingRest) {
                    out.append(IntervalStep(phase: .rest, duration: restSec, round: r, cycle: c))
                }
            }
            if c < cycles && restBetweenCyclesSec > 0 {
                out.append(IntervalStep(phase: .recover, duration: restBetweenCyclesSec, cycle: c))
            }
        }
        return out
    }

    /// Total scheduled duration in seconds (0 if any segment is open-ended, which never happens for a
    /// fixed preset but is documented for the free-run convention).
    public var totalSeconds: Int {
        let s = steps()
        if s.contains(where: { $0.isOpenEnded }) { return 0 }
        return s.reduce(0) { $0 + $1.duration }
    }

    /// A free, open-ended outdoor run with a single target-zone segment — the running-in-a-zone use case
    /// expressed in the same model. `steps()` is NOT used for this; callers build the lone open segment.
    public static func freeRun(targetZoneLow: Int, targetZoneHigh: Int) -> IntervalStep {
        IntervalStep(phase: .work, duration: 0, targetZoneLow: targetZoneLow, targetZoneHigh: targetZoneHigh)
    }
}

/// Live progress through a timeline at a given elapsed time.
public struct IntervalProgress: Equatable, Sendable {
    /// Index into the expanded `steps` (clamped to the last step once finished).
    public let stepIndex: Int
    public let phase: IntervalPhase
    /// Whole seconds remaining in the CURRENT segment (ceil), 0 once finished.
    public let remainingInStep: Int
    /// 1-based round / cycle of the current segment (0 when not applicable, e.g. prepare).
    public let round: Int
    public let cycle: Int
    /// Rounds remaining in the CURRENT cycle (including the current one), 0 when not in work/rest.
    public let roundsLeft: Int
    /// Cycles remaining overall (including the current one).
    public let cyclesLeft: Int
    /// Planned HR band of the current segment (0/0 = none).
    public let targetZoneLow: Int
    public let targetZoneHigh: Int
    /// Whole seconds remaining across the whole workout (ceil), 0 once finished.
    public let totalRemaining: Int
    public let finished: Bool
}

/// Pure timeline engine over an expanded `[IntervalStep]`. Answers progress-at-time and boundary
/// crossings. Built once per workout; queried each tick (~1 Hz) by the live screen + cue dispatcher.
public struct IntervalTimeline: Equatable, Sendable {
    public let steps: [IntervalStep]
    /// Cumulative END time (seconds from start) of each step. `ends[i]` = sum of durations 0...i.
    private let ends: [Int]
    public let totalCycles: Int

    public init(steps: [IntervalStep]) {
        self.steps = steps
        var acc = 0
        var e: [Int] = []
        for s in steps { acc += s.duration; e.append(acc) }
        self.ends = e
        self.totalCycles = steps.map(\.cycle).max() ?? 0
    }

    public init(preset: IntervalPreset) { self.init(steps: preset.steps()) }

    /// Total scheduled seconds (end of the last step), 0 for an empty timeline.
    public var totalSeconds: Int { ends.last ?? 0 }

    /// Resolve progress at `elapsed` seconds from the start.
    public func progress(atElapsed elapsed: Double) -> IntervalProgress {
        guard !steps.isEmpty else {
            return IntervalProgress(stepIndex: 0, phase: .work, remainingInStep: 0, round: 0, cycle: 0,
                                    roundsLeft: 0, cyclesLeft: 0, targetZoneLow: 0, targetZoneHigh: 0,
                                    totalRemaining: 0, finished: true)
        }
        let total = totalSeconds
        if elapsed >= Double(total) {
            let last = steps[steps.count - 1]
            return IntervalProgress(stepIndex: steps.count - 1, phase: last.phase, remainingInStep: 0,
                                    round: last.round, cycle: last.cycle, roundsLeft: 0, cyclesLeft: 0,
                                    targetZoneLow: last.targetZoneLow, targetZoneHigh: last.targetZoneHigh,
                                    totalRemaining: 0, finished: true)
        }
        let e = max(0, elapsed)
        // First step whose cumulative end is strictly after `elapsed`.
        var idx = 0
        while idx < ends.count && Double(ends[idx]) <= e { idx += 1 }
        if idx >= steps.count { idx = steps.count - 1 }
        let step = steps[idx]
        let stepStart = idx == 0 ? 0 : ends[idx - 1]
        let remainingInStep = max(0, Int((Double(ends[idx]) - e).rounded(.up)))
        let totalRemaining = max(0, Int((Double(total) - e).rounded(.up)))
        // rounds left within the current cycle (count remaining steps in this cycle that start a round).
        let roundsLeft: Int
        if step.round > 0 {
            let roundsInCycle = steps.filter { $0.cycle == step.cycle && $0.phase == .work }.map(\.round)
            let maxRound = roundsInCycle.max() ?? step.round
            roundsLeft = max(0, maxRound - step.round + 1)
        } else {
            roundsLeft = 0
        }
        let cyclesLeft = step.cycle > 0 ? max(0, totalCycles - step.cycle + 1) : 0
        _ = stepStart
        return IntervalProgress(stepIndex: idx, phase: step.phase, remainingInStep: remainingInStep,
                                round: step.round, cycle: step.cycle, roundsLeft: roundsLeft,
                                cyclesLeft: cyclesLeft, targetZoneLow: step.targetZoneLow,
                                targetZoneHigh: step.targetZoneHigh, totalRemaining: totalRemaining,
                                finished: false)
    }

    /// The step the clock ENTERED between `from` and `to` elapsed seconds, if a boundary was crossed —
    /// i.e. the next segment just started, so the live layer should fire its transition cue (sound/buzz).
    /// Returns nil when both times fall inside the same step. Also returns the step at index 0 when the
    /// workout itself just started (from < 0 ≤ to). Designed to be called each tick with the prior tick's
    /// elapsed as `from`.
    public func boundaryCrossed(from: Double, to: Double) -> IntervalStep? {
        guard !steps.isEmpty, to > from else { return nil }
        let fromIdx = stepIndex(atElapsed: from)
        let toIdx = stepIndex(atElapsed: to)
        guard toIdx != fromIdx, toIdx < steps.count else { return nil }
        return steps[toIdx]
    }

    /// Index of the step containing `elapsed` (clamped to last step at/after the end). -1 before start.
    public func stepIndex(atElapsed elapsed: Double) -> Int {
        if elapsed < 0 { return -1 }
        if elapsed >= Double(totalSeconds) { return steps.count - 1 }
        var idx = 0
        while idx < ends.count && Double(ends[idx]) <= elapsed { idx += 1 }
        return Swift.min(idx, steps.count - 1)
    }
}
