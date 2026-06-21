import Foundation

// GoalWorkout.swift — the third saveable workout kind: an endurance GOAL held inside a target band.
//
// "Run 5 km / 30 min while keeping HR in Zone 2" or "hold 5:30–6:00 /km for 10 km". A goal workout is a
// single open-ended effort with (a) a COMPLETION GOAL — by time, by distance, or open (manual stop) —
// and (b) zero or more TARGET BANDS the user wants to hold: an HR-zone band ([targetZoneLow,High]) and/or
// a pace band (`PaceRange`). The HR band is policed by `ZoneAlertMonitor`, the pace band by
// `PaceAlertMonitor`; this file owns the goal model + the pure completion/progress math.
//
// Together with `IntervalPreset` (Tabata/HIIT) this is the second saveable preset shape; the app's
// store layer persists either kind. All pure value types → unit-testable off any clock/GPS.

/// How a goal workout decides it is finished.
public enum WorkoutGoal: Codable, Equatable, Sendable {
    /// Runs until the user stops (a free session held in a band).
    case open
    /// Finish after this many seconds.
    case duration(Int)
    /// Finish after this many metres.
    case distance(Int)
}

/// A pace band to hold, in seconds-per-kilometre. `fast` is the lower (quicker) bound, `slow` the upper
/// (easier) bound, so a valid band has `fast <= slow`. Smaller sec/km = quicker.
public struct PaceRange: Codable, Equatable, Sendable {
    public var fastSecPerKm: Int
    public var slowSecPerKm: Int
    public init(fastSecPerKm: Int, slowSecPerKm: Int) {
        self.fastSecPerKm = Swift.min(fastSecPerKm, slowSecPerKm)
        self.slowSecPerKm = Swift.max(fastSecPerKm, slowSecPerKm)
    }
}

/// A saveable endurance-goal workout definition.
public struct GoalPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Catalogue sport name ("Running", "Cycling", "Walking" …). Distance sports arm GPS.
    public var sport: String
    public var goal: WorkoutGoal
    /// Planned HR-zone band (1...5); 0/0 = no HR target.
    public var targetZoneLow: Int
    public var targetZoneHigh: Int
    /// Optional pace band (nil = no pace target).
    public var paceRange: PaceRange?

    public init(id: String, name: String, sport: String = "Running", goal: WorkoutGoal = .open,
                targetZoneLow: Int = 0, targetZoneHigh: Int = 0, paceRange: PaceRange? = nil) {
        self.id = id
        self.name = name
        self.sport = sport
        self.goal = goal
        self.targetZoneLow = targetZoneLow
        self.targetZoneHigh = targetZoneHigh
        self.paceRange = paceRange
    }

    public var hasHRTarget: Bool { targetZoneLow >= 1 && targetZoneHigh >= 1 }
    public var hasPaceTarget: Bool { paceRange != nil }

    /// True when live GPS is required to evaluate the goal (a distance goal or a pace band).
    public var needsGps: Bool {
        if case .distance = goal { return true }
        return paceRange != nil
    }

    /// Fraction of the goal completed (0...1), or nil for an `.open` goal (no finish line).
    public func fractionComplete(elapsedSec: Double, distanceM: Double) -> Double? {
        switch goal {
        case .open: return nil
        case .duration(let s): return s > 0 ? min(1, max(0, elapsedSec / Double(s))) : 1
        case .distance(let m): return m > 0 ? min(1, max(0, distanceM / Double(m))) : 1
        }
    }

    /// True once the completion goal has been reached. Always false for `.open`.
    public func isComplete(elapsedSec: Double, distanceM: Double) -> Bool {
        switch goal {
        case .open: return false
        case .duration(let s): return elapsedSec >= Double(s)
        case .distance(let m): return distanceM >= Double(m)
        }
    }

    /// Remaining seconds to a time goal (nil if the goal isn't time-based).
    public func secondsRemaining(elapsedSec: Double) -> Int? {
        guard case .duration(let s) = goal else { return nil }
        return max(0, Int((Double(s) - elapsedSec).rounded(.up)))
    }

    /// Remaining metres to a distance goal (nil if the goal isn't distance-based).
    public func metresRemaining(distanceM: Double) -> Int? {
        guard case .distance(let m) = goal else { return nil }
        return max(0, Int((Double(m) - distanceM).rounded(.up)))
    }
}
