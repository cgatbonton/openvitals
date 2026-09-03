import SwiftUI

// HCC: the watchOS companion's entry point (plan §4.7a).
//
// A separate target, not a second copy of the app: it shares no code with the
// iPhone build, holds no credentials, and reads nothing from the HCC server.
// The only two things it does are start a workout session the phone cannot
// start itself, and say how charged the watch is.

@main
struct HCCWatchApp: App {
  init() {
    // Battery monitoring has to be on before the first read, and the session
    // has to exist before the phone can receive anything. Both are idempotent.
    HCCWatchBattery.shared.activate()
  }

  var body: some Scene {
    WindowGroup {
      HCCWatchContentView()
    }
  }
}
