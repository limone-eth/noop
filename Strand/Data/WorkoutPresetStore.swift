import Foundation
import Combine
import StrandAnalytics

// WorkoutPresetStore.swift — saveable workout presets (the TimerPlus-style "custom workout" library).
//
// Holds the user's saved `IntervalPreset` (Tabata/HIIT) and `GoalPreset` (time/distance held in a band)
// definitions, JSON-encoded into `UserDefaults` — the same on-device, single-user persistence idiom as
// `BehaviorStore` and `ActiveWorkoutPersistence`. Seeded once with a few sensible starters so the
// library is never empty on first run. Pure model lives in `StrandAnalytics`; this is just the store.
@MainActor
final class WorkoutPresetStore: ObservableObject {

    /// Saved interval workouts (Tabata / HIIT / circuits), newest-edited last.
    @Published private(set) var intervals: [IntervalPreset] = []
    /// Saved endurance-goal workouts (run X km / Y min holding an HR zone or pace band).
    @Published private(set) var goals: [GoalPreset] = []

    private let d: UserDefaults
    private enum K {
        static let intervals = "presets.intervals.v1"
        static let goals = "presets.goals.v1"
        static let seeded = "presets.seeded.v1"
        static let zone2DistanceGoals = "presets.zone2DistanceGoals.v1"
        static let vo2Migration = "presets.vo2Migration.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        intervals = Self.decode([IntervalPreset].self, d.data(forKey: K.intervals)) ?? []
        goals = Self.decode([GoalPreset].self, d.data(forKey: K.goals)) ?? []
        if !d.bool(forKey: K.seeded) {
            seedDefaults()
            d.set(true, forKey: K.seeded)
        }
        addZone2DistanceGoalsOnce()
        migrateToVO2MaxOnce()
    }

    /// One-time migration: replace the original interval seeds (Tabata / HIIT / EMOM) with the two VO2
    /// max workouts, and drop the "30 min aerobic" + "Tempo" goal seeds. Targets only those seed ids, so
    /// any preset the user created is left untouched. Runs once.
    private func migrateToVO2MaxOnce() {
        guard !d.bool(forKey: K.vo2Migration) else { return }
        intervals.removeAll { ["seed.tabata", "seed.hiit", "seed.emom"].contains($0.id) }
        for p in Self.vo2MaxPresets where !intervals.contains(where: { $0.id == p.id }) {
            intervals.append(p)
        }
        goals.removeAll { ["seed.30min", "seed.tempo"].contains($0.id) }
        persistIntervals(); persistGoals()
        d.set(true, forKey: K.vo2Migration)
    }

    /// One-time migration that adds the 10 km and 7 km Zone-2 goal presets to existing installs (the
    /// initial seed already ran, so they wouldn't otherwise appear). Idempotent + respects deletion: it
    /// runs once, only inserting ids that aren't already present.
    private func addZone2DistanceGoalsOnce() {
        guard !d.bool(forKey: K.zone2DistanceGoals) else { return }
        let builtins = [
            GoalPreset(id: "builtin.10k.z2", name: "10 km · Zone 2", sport: "Running",
                       goal: .distance(10_000), targetZoneLow: 2, targetZoneHigh: 2),
            GoalPreset(id: "builtin.7k.z2", name: "7 km · Zone 2", sport: "Running",
                       goal: .distance(7_000), targetZoneLow: 2, targetZoneHigh: 2),
        ]
        var changed = false
        for b in builtins where !goals.contains(where: { $0.id == b.id }) {
            goals.append(b); changed = true
        }
        if changed { persistGoals() }
        d.set(true, forKey: K.zone2DistanceGoals)
    }

    // MARK: - Mutators (each persists immediately)

    /// Insert or replace an interval preset by id.
    func save(_ p: IntervalPreset) {
        if let i = intervals.firstIndex(where: { $0.id == p.id }) { intervals[i] = p }
        else { intervals.append(p) }
        persistIntervals()
    }

    /// Insert or replace a goal preset by id.
    func save(_ p: GoalPreset) {
        if let i = goals.firstIndex(where: { $0.id == p.id }) { goals[i] = p }
        else { goals.append(p) }
        persistGoals()
    }

    func deleteInterval(id: String) { intervals.removeAll { $0.id == id }; persistIntervals() }
    func deleteGoal(id: String) { goals.removeAll { $0.id == id }; persistGoals() }

    // MARK: - Persistence

    private func persistIntervals() { d.set(Self.encode(intervals), forKey: K.intervals) }
    private func persistGoals() { d.set(Self.encode(goals), forKey: K.goals) }

    private static func encode<T: Encodable>(_ v: T) -> Data? { try? JSONEncoder().encode(v) }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Seeds

    /// A handful of recognisable starters so the library is useful on first open. Ids are stable so a
    /// re-seed (only ever runs once) can't duplicate them. Zone targets use the conventional bands.
    private func seedDefaults() {
        if intervals.isEmpty {
            intervals = Self.vo2MaxPresets
            persistIntervals()
        }
        if goals.isEmpty {
            goals = [
                GoalPreset(id: "seed.5k", name: "5K easy (Zone 2)", sport: "Running",
                           goal: .distance(5000), targetZoneLow: 2, targetZoneHigh: 2),
            ]
            persistGoals()
        }
    }

    /// The two VO2 max interval workouts (Zone 4–5):
    ///   • VO2 max 1 — 4 min work / 4 min recovery × 5 rounds
    ///   • VO2 max 2 — 3 min work / 3 min recovery × 6 rounds
    static let vo2MaxPresets: [IntervalPreset] = [
        IntervalPreset(id: "builtin.vo2.1", name: "VO2 max 1", prepareSec: 10, workSec: 240,
                       restSec: 240, rounds: 5, cycles: 1, restBetweenCyclesSec: 0,
                       targetZoneLow: 4, targetZoneHigh: 5),
        IntervalPreset(id: "builtin.vo2.2", name: "VO2 max 2", prepareSec: 10, workSec: 180,
                       restSec: 180, rounds: 6, cycles: 1, restBetweenCyclesSec: 0,
                       targetZoneLow: 4, targetZoneHigh: 5),
    ]
}
