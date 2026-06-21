import XCTest
@testable import StrandAnalytics

final class ZoneAlertMonitorTests: XCTestCase {

    func testInBandNeverAlerts() {
        var m = ZoneAlertMonitor(low: 2, high: 3, graceSeconds: 10, repeatSeconds: 30)
        for t in stride(from: 0.0, through: 120, by: 1) {
            XCTAssertNil(m.evaluate(zone: 2, at: t))
        }
    }

    func testAboveBandFiresAfterGraceThenRepeats() {
        var m = ZoneAlertMonitor(low: 2, high: 2, graceSeconds: 10, repeatSeconds: 30)
        // Within grace: no alert.
        XCTAssertNil(m.evaluate(zone: 4, at: 0))
        XCTAssertNil(m.evaluate(zone: 4, at: 9))
        // Grace elapsed → first alert.
        XCTAssertEqual(m.evaluate(zone: 4, at: 10), .above)
        // No re-alert until repeatSeconds passes.
        XCTAssertNil(m.evaluate(zone: 4, at: 30))
        XCTAssertNil(m.evaluate(zone: 4, at: 39))
        // repeatSeconds after the first fire (10 + 30 = 40) → repeat alert.
        XCTAssertEqual(m.evaluate(zone: 4, at: 40), .above)
    }

    func testBelowBandFires() {
        var m = ZoneAlertMonitor(low: 3, high: 4, graceSeconds: 5, repeatSeconds: 30)
        XCTAssertNil(m.evaluate(zone: 1, at: 0))
        XCTAssertEqual(m.evaluate(zone: 1, at: 5), .below)
        // Zone 0 (below Zone 1) is also "below".
        var m2 = ZoneAlertMonitor(low: 2, high: 2, graceSeconds: 0)
        XCTAssertEqual(m2.evaluate(zone: 0, at: 0), .below)
    }

    func testReturnToBandResetsGrace() {
        var m = ZoneAlertMonitor(low: 2, high: 2, graceSeconds: 10, repeatSeconds: 30)
        XCTAssertNil(m.evaluate(zone: 4, at: 0))
        XCTAssertNil(m.evaluate(zone: 4, at: 8))
        XCTAssertNil(m.evaluate(zone: 2, at: 9))   // back in band → streak reset
        XCTAssertNil(m.evaluate(zone: 4, at: 10))  // new streak starts here
        XCTAssertNil(m.evaluate(zone: 4, at: 19))  // 9s into new streak — still within grace
        XCTAssertEqual(m.evaluate(zone: 4, at: 20), .above)  // 10s into new streak
    }

    func testDirectionFlipRestartsStreak() {
        var m = ZoneAlertMonitor(low: 3, high: 3, graceSeconds: 10, repeatSeconds: 30)
        XCTAssertNil(m.evaluate(zone: 5, at: 0))   // above
        XCTAssertEqual(m.evaluate(zone: 5, at: 10), .above)
        XCTAssertNil(m.evaluate(zone: 1, at: 11))  // flipped to below → grace re-arms
        XCTAssertNil(m.evaluate(zone: 1, at: 20))  // 9s into below streak
        XCTAssertEqual(m.evaluate(zone: 1, at: 21), .below)  // 10s into below streak
    }

    func testUnarmedMonitorNeverFires() {
        var m = ZoneAlertMonitor(low: 0, high: 0)
        XCTAssertFalse(m.isArmed)
        XCTAssertNil(m.evaluate(zone: 5, at: 100))
    }
}
