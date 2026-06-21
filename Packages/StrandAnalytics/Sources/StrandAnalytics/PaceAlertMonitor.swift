import Foundation

// PaceAlertMonitor.swift — the pace-band analogue of `ZoneAlertMonitor`.
//
// Fed the current running pace (seconds-per-kilometre) and a monotonic timestamp, it polices a target
// `PaceRange` [fast, slow] with the SAME continuous-grace + repeat-cadence debounce the HR monitor uses,
// so a single GPS-noise blip doesn't nag. Note the direction semantics: a SMALLER sec/km is quicker, so
//   • pace < fast bound  → `.tooFast` ("ease off")
//   • pace > slow bound  → `.tooSlow` ("push")
// A nil pace (stopped / no GPS fix yet) is treated as "no data": it neither fires nor disturbs the
// current streak. Pure value type → unit-testable against a fake clock and a synthetic pace stream.

public enum PaceAlertKind: Equatable, Sendable {
    /// Running quicker than the band's fast bound — ease off.
    case tooFast
    /// Running slower than the band's slow bound — push.
    case tooSlow
}

public struct PaceAlertMonitor: Equatable, Sendable {
    public let fastSecPerKm: Double
    public let slowSecPerKm: Double
    public let graceSeconds: Double
    public let repeatSeconds: Double

    private var outSince: Double?
    private var outKind: PaceAlertKind?
    private var lastFiredAt: Double?

    public init(range: PaceRange, graceSeconds: Double = 12, repeatSeconds: Double = 30) {
        self.fastSecPerKm = Double(range.fastSecPerKm)
        self.slowSecPerKm = Double(range.slowSecPerKm)
        self.graceSeconds = graceSeconds
        self.repeatSeconds = repeatSeconds
    }

    public var isArmed: Bool { fastSecPerKm > 0 && slowSecPerKm > 0 }

    /// Feed the current pace (sec/km, or nil when unknown) and a monotonic time. Returns the alert to
    /// fire now, or nil.
    public mutating func evaluate(paceSecPerKm: Double?, at t: Double) -> PaceAlertKind? {
        guard isArmed else { return nil }
        guard let pace = paceSecPerKm, pace > 0, pace.isFinite else { return nil }  // no data → no change

        let kind: PaceAlertKind?
        if pace < fastSecPerKm { kind = .tooFast }
        else if pace > slowSecPerKm { kind = .tooSlow }
        else { kind = nil }

        guard let kind else {
            outSince = nil; outKind = nil; lastFiredAt = nil
            return nil
        }
        if outKind != kind {
            outKind = kind
            outSince = t
            lastFiredAt = nil
        }
        guard let since = outSince else { return nil }
        if let last = lastFiredAt {
            if t - last >= repeatSeconds { lastFiredAt = t; return kind }
            return nil
        }
        if t - since >= graceSeconds { lastFiredAt = t; return kind }
        return nil
    }

    public mutating func reset() { outSince = nil; outKind = nil; lastFiredAt = nil }
}
