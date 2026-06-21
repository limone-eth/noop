import Foundation
#if os(iOS)
import AudioToolbox
import UIKit
#endif

// AlertSound.swift — phone-side audible + tactile cue for "out of planned zone" / interval transitions.
//
// The app had NO sound path before this (coaching was strap-buzz only). On iPhone we want a cue that
// works even when the strap isn't bonded (e.g. a WHOOP 5 streaming HR over the unbonded standard
// profile) and that the user can hear over a run. `AudioServicesPlayAlertSound` plays a short system
// tone AND vibrates the device on a phone, with no audio-session setup and no asset bundling. Distinct
// tones per cue so "too hard" and "too easy" sound different without looking at the screen.
//
// No-op on macOS (no AudioToolbox alert vibration; the Mac path stays strap-buzz only).
enum AlertSound {

    /// The semantic cue to play. Mapped to distinct system sound IDs so they're audibly distinguishable.
    enum Cue {
        case tooHigh        // HR above the planned band — "ease off"
        case tooLow         // HR below the planned band — "push"
        case paceTooFast
        case paceTooSlow
        case work           // interval entered a WORK block
        case rest           // interval entered a REST block
        case finished       // whole workout complete
    }

    /// Play the cue's tone + device vibration. Safe to call from the main actor each transition.
    static func play(_ cue: Cue) {
        #if os(iOS)
        AudioServicesPlaySystemSound(systemSoundID(for: cue))
        // A matching Taptic cue so it's felt as well as heard (silent-switch friendly).
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
    }

    #if os(iOS)
    // System sound IDs (the built-in UISounds set). These are short, distinct, always-present tones —
    // chosen so up/down cues differ. Documented IDs, stable across iOS versions.
    private static func systemSoundID(for cue: Cue) -> SystemSoundID {
        switch cue {
        case .tooHigh:      return 1005   // "received" alert — sharper, for "ease off"
        case .tooLow:       return 1306   // "Tink" — gentler, for "push"
        case .paceTooFast:  return 1005
        case .paceTooSlow:  return 1306
        case .work:         return 1057   // "Tock" — crisp start-of-work
        case .rest:         return 1103   // "begin record" — softer rest cue
        case .finished:     return 1025   // "fanfare"-ish completion
        }
    }
    #endif
}
