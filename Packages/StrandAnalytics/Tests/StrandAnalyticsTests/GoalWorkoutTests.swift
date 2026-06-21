import XCTest
@testable import StrandAnalytics

final class GoalWorkoutTests: XCTestCase {

    func testDistanceGoalProgressAndCompletion() {
        let g = GoalPreset(id: "5k", name: "5K Z2", sport: "Running", goal: .distance(5000),
                           targetZoneLow: 2, targetZoneHigh: 2)
        XCTAssertEqual(g.fractionComplete(elapsedSec: 600, distanceM: 2500), 0.5)
        XCTAssertEqual(g.metresRemaining(distanceM: 2500), 2500)
        XCTAssertFalse(g.isComplete(elapsedSec: 600, distanceM: 4999))
        XCTAssertTrue(g.isComplete(elapsedSec: 1200, distanceM: 5000))
        XCTAssertNil(g.secondsRemaining(elapsedSec: 600))   // not a time goal
        XCTAssertTrue(g.hasHRTarget)
        XCTAssertFalse(g.hasPaceTarget)
    }

    func testDurationGoalProgress() {
        let g = GoalPreset(id: "30", name: "30min", goal: .duration(1800),
                           paceRange: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360))
        XCTAssertEqual(g.fractionComplete(elapsedSec: 900, distanceM: 0), 0.5)
        XCTAssertEqual(g.secondsRemaining(elapsedSec: 900), 900)
        XCTAssertTrue(g.isComplete(elapsedSec: 1800, distanceM: 0))
        XCTAssertNil(g.metresRemaining(distanceM: 100))
        XCTAssertTrue(g.hasPaceTarget)
    }

    func testOpenGoalNeverCompletes() {
        let g = GoalPreset(id: "free", name: "Free", goal: .open, targetZoneLow: 2, targetZoneHigh: 3)
        XCTAssertNil(g.fractionComplete(elapsedSec: 99999, distanceM: 99999))
        XCTAssertFalse(g.isComplete(elapsedSec: 99999, distanceM: 99999))
    }

    func testPaceRangeNormalisesOrder() {
        let r = PaceRange(fastSecPerKm: 360, slowSecPerKm: 330)  // passed reversed
        XCTAssertEqual(r.fastSecPerKm, 330)
        XCTAssertEqual(r.slowSecPerKm, 360)
    }

    func testCodableRoundTrip() throws {
        let g = GoalPreset(id: "5k", name: "5K Z2", goal: .distance(5000), targetZoneLow: 2,
                           targetZoneHigh: 2, paceRange: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360))
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(GoalPreset.self, from: data)
        XCTAssertEqual(g, back)
    }
}

final class PaceAlertMonitorTests: XCTestCase {

    func testInBandNeverAlerts() {
        var m = PaceAlertMonitor(range: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360),
                                 graceSeconds: 10, repeatSeconds: 30)
        for t in stride(from: 0.0, through: 120, by: 2) {
            XCTAssertNil(m.evaluate(paceSecPerKm: 345, at: t))
        }
    }

    func testTooSlowFiresAfterGrace() {
        var m = PaceAlertMonitor(range: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360),
                                 graceSeconds: 12, repeatSeconds: 30)
        XCTAssertNil(m.evaluate(paceSecPerKm: 400, at: 0))
        XCTAssertNil(m.evaluate(paceSecPerKm: 400, at: 11))
        XCTAssertEqual(m.evaluate(paceSecPerKm: 400, at: 12), .tooSlow)
    }

    func testTooFastFires() {
        var m = PaceAlertMonitor(range: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360), graceSeconds: 5)
        XCTAssertNil(m.evaluate(paceSecPerKm: 300, at: 0))
        XCTAssertEqual(m.evaluate(paceSecPerKm: 300, at: 5), .tooFast)
    }

    func testNilPaceDoesNotDisturbStreak() {
        var m = PaceAlertMonitor(range: PaceRange(fastSecPerKm: 330, slowSecPerKm: 360), graceSeconds: 10)
        XCTAssertNil(m.evaluate(paceSecPerKm: 400, at: 0))   // start slow streak
        XCTAssertNil(m.evaluate(paceSecPerKm: nil, at: 5))   // GPS dropout — no change
        XCTAssertEqual(m.evaluate(paceSecPerKm: 400, at: 10), .tooSlow)  // grace still measured from t=0
    }
}
