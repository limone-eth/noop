import XCTest
@testable import StrandAnalytics

final class IntervalPlanTests: XCTestCase {

    func testTabataExpansion() {
        // Classic Tabata: 10s prepare, 8 rounds of 20s work / 10s rest, 1 cycle, trim trailing rest.
        let p = IntervalPreset(id: "tabata", name: "Tabata", prepareSec: 10, workSec: 20, restSec: 10,
                               rounds: 8, cycles: 1, restBetweenCyclesSec: 0, trimTrailingRest: true)
        let steps = p.steps()
        // 1 prepare + 8 work + 7 rest (last rest trimmed) = 16 steps.
        XCTAssertEqual(steps.count, 16)
        XCTAssertEqual(steps.first?.phase, .prepare)
        XCTAssertEqual(steps.filter { $0.phase == .work }.count, 8)
        XCTAssertEqual(steps.filter { $0.phase == .rest }.count, 7)
        XCTAssertEqual(steps.last?.phase, .work)
        // total = 10 + 8*20 + 7*10 = 240
        XCTAssertEqual(p.totalSeconds, 240)
    }

    func testCyclesAddRecoverBetweenButNotAfterLast() {
        // 2 cycles of 2 rounds (5s work / 5s rest), 7s recover between cycles, no prepare, keep rests.
        let p = IntervalPreset(id: "c", name: "C", prepareSec: 0, workSec: 5, restSec: 5,
                               rounds: 2, cycles: 2, restBetweenCyclesSec: 7, trimTrailingRest: false)
        let steps = p.steps()
        // per cycle: 2*(work+rest)=4 steps; 2 cycles=8; +1 recover between (not after last)=9.
        XCTAssertEqual(steps.count, 9)
        XCTAssertEqual(steps.filter { $0.phase == .recover }.count, 1)
        // total = 2*(2*(5+5)) + 7 = 40 + 7 = 47
        XCTAssertEqual(p.totalSeconds, 47)
    }

    func testProgressResolvesSegmentAndRemaining() {
        let p = IntervalPreset(id: "x", name: "X", prepareSec: 10, workSec: 20, restSec: 10,
                               rounds: 2, cycles: 1, restBetweenCyclesSec: 0, trimTrailingRest: true)
        let tl = IntervalTimeline(preset: p)
        // timeline: prepare[0,10) work[10,30) rest[30,40) work[40,60)  total=60
        XCTAssertEqual(tl.totalSeconds, 60)

        let atPrepare = tl.progress(atElapsed: 3)
        XCTAssertEqual(atPrepare.phase, .prepare)
        XCTAssertEqual(atPrepare.remainingInStep, 7)

        let atWork = tl.progress(atElapsed: 15)
        XCTAssertEqual(atWork.phase, .work)
        XCTAssertEqual(atWork.round, 1)
        XCTAssertEqual(atWork.remainingInStep, 15)
        XCTAssertEqual(atWork.roundsLeft, 2)

        let atRest = tl.progress(atElapsed: 35)
        XCTAssertEqual(atRest.phase, .rest)

        let done = tl.progress(atElapsed: 60)
        XCTAssertTrue(done.finished)
        XCTAssertEqual(done.totalRemaining, 0)
    }

    func testBoundaryCrossingDetectsEnteredStep() {
        let p = IntervalPreset(id: "x", name: "X", prepareSec: 10, workSec: 20, restSec: 10,
                               rounds: 2, cycles: 1, restBetweenCyclesSec: 0, trimTrailingRest: true)
        let tl = IntervalTimeline(preset: p)
        // crossing 10s (prepare→work)
        let entered = tl.boundaryCrossed(from: 9.5, to: 10.5)
        XCTAssertEqual(entered?.phase, .work)
        // no crossing inside the same work block
        XCTAssertNil(tl.boundaryCrossed(from: 11, to: 12))
        // crossing 30s (work→rest)
        XCTAssertEqual(tl.boundaryCrossed(from: 29.5, to: 30.5)?.phase, .rest)
    }

    func testTargetZonePropagatesToWorkSteps() {
        let p = IntervalPreset(id: "z", name: "Z", prepareSec: 0, workSec: 30, restSec: 30,
                               rounds: 1, cycles: 1, restBetweenCyclesSec: 0,
                               targetZoneLow: 4, targetZoneHigh: 5, trimTrailingRest: false)
        let work = p.steps().first { $0.phase == .work }
        XCTAssertEqual(work?.targetZoneLow, 4)
        XCTAssertEqual(work?.targetZoneHigh, 5)
        // rest carries no target
        let rest = p.steps().first { $0.phase == .rest }
        XCTAssertEqual(rest?.targetZoneLow, 0)
    }
}
