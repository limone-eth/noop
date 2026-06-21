import Foundation

// ZoneAlertMonitor.swift — decides WHEN to fire an "out of planned HR zone" alert during a workout.
//
// Fed the current HR zone (1...5, or 0 = below Zone 1) on each sample plus a monotonic timestamp, it
// compares against a planned [low, high] zone band and emits an alert only after the user has been
// CONTINUOUSLY outside the band for `graceSeconds` (so a one-off spike crossing a boundary doesn't
// nag), then re-emits every `repeatSeconds` while they stay out (a sustained drift = periodic nudges).
// A direction flip (above ↔ below) or a return into the band resets the streak.
//
// Pure value type, no platform/Combine/CoreBluetooth dependency → unit-testable against a fake clock.
// The HR→zone mapping lives in `HRZoneSet.zoneNumber(forBPM:)`; this monitor only sees the zone number.

/// Which side of the planned band the heart rate drifted to.
public enum ZoneAlertKind: Equatable, Sendable {
    /// HR climbed ABOVE the planned band — the cue means "ease off".
    case above
    /// HR dropped BELOW the planned band — the cue means "push".
    case below
}

/// Stateful (but pure) debounce machine for planned-zone drift alerts.
public struct ZoneAlertMonitor: Equatable, Sendable {
    /// Planned band lower zone (1...5), inclusive.
    public let low: Int
    /// Planned band upper zone (1...5), inclusive.
    public let high: Int
    /// How long the user must be continuously out-of-band before the FIRST alert (seconds).
    public let graceSeconds: Double
    /// Cadence of repeat alerts while still out-of-band in the same direction (seconds).
    public let repeatSeconds: Double

    // MARK: streak state
    private var outSince: Double?        // when the current out-of-band streak began
    private var outKind: ZoneAlertKind?  // which direction the current streak is
    private var lastFiredAt: Double?     // when we last emitted for this streak (nil = not yet)

    /// - Parameters:
    ///   - low/high: the planned zone band (order-independent; min/max are taken).
    ///   - graceSeconds: continuous out-of-band time before the first nudge (default 10 s).
    ///   - repeatSeconds: re-nudge cadence while still out (default 30 s).
    public init(low: Int, high: Int, graceSeconds: Double = 10, repeatSeconds: Double = 30) {
        self.low = Swift.min(low, high)
        self.high = Swift.max(low, high)
        self.graceSeconds = graceSeconds
        self.repeatSeconds = repeatSeconds
    }

    /// True when this monitor has a usable band to police (a non-positive band means "no target").
    public var isArmed: Bool { low >= 1 && high >= 1 }

    /// Feed the current zone number and a monotonic time. Returns the alert to fire NOW, or nil.
    ///
    /// - Parameters:
    ///   - zone: current HR zone, 1...5 (0 = below Zone 1).
    ///   - t: monotonic timestamp in seconds (e.g. elapsed workout time or `Date` epoch).
    public mutating func evaluate(zone: Int, at t: Double) -> ZoneAlertKind? {
        guard isArmed else { return nil }

        let kind: ZoneAlertKind?
        if zone < low { kind = .below }
        else if zone > high { kind = .above }
        else { kind = nil }                    // inside the band

        guard let kind else {                  // recovered into band → reset the streak
            outSince = nil; outKind = nil; lastFiredAt = nil
            return nil
        }

        // First out-of-band sample, or a direction flip → (re)start the streak and re-arm the grace wait.
        if outKind != kind {
            outKind = kind
            outSince = t
            lastFiredAt = nil
        }

        guard let since = outSince else { return nil }

        if let last = lastFiredAt {            // already nudged once this streak → repeat-cadence gate
            if t - last >= repeatSeconds { lastFiredAt = t; return kind }
            return nil
        }
        // Not yet nudged → wait out the grace period.
        if t - since >= graceSeconds { lastFiredAt = t; return kind }
        return nil
    }

    /// Drop any in-flight streak (e.g. when the workout's active segment changes its target band).
    public mutating func reset() {
        outSince = nil; outKind = nil; lastFiredAt = nil
    }
}
