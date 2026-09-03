import Foundation
import WatchConnectivity
import WatchKit

// HCC: the watch's battery level, and the one channel that is not the workout.
//
// The mirrored workout session carries the battery while a workout is running
// (`{"t":"batt","level":…}`), but it exists only for the length of that
// workout. The phone's device row wants a level the rest of the time too, and
// the only link that survives outside a session is `WCSession`.
//
// `updateApplicationContext` is the right verb for it: one small dictionary
// that always holds the LATEST value, coalesced by the OS, delivered whenever
// the phone next runs. A queued message would be wrong — nobody wants yesterday's
// battery replayed — and `transferUserInfo` would keep a backlog of readings
// that are already stale by the time they land.
//
// The `at` stamp goes with the level so the phone can decide the reading is too
// old to show rather than presenting a number from last week as current.

/// Battery monitoring on the watch, and the `WCSession` relay to the phone.
final class HCCWatchBattery: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = HCCWatchBattery()

  /// The watch's battery, 0–1, or nil when watchOS will not say.
  ///
  /// `batteryLevel` returns -1 when monitoring is off or the value is unknown;
  /// that is reported as "no reading", never as 0 %.
  var level: Double? {
    let raw = WKInterfaceDevice.current().batteryLevel
    guard raw >= 0 else { return nil }
    return Double(raw)
  }

  private var activated = false

  /// Turn on battery monitoring and activate the session. Idempotent; call it
  /// at launch and on every foreground.
  func activate() {
    WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    if !activated {
      activated = true
      session.delegate = self
      session.activate()
    }
    report()
  }

  /// Push the current level to the phone. A no-op when there is no level to
  /// send — an absent battery is reported by saying nothing, never by sending a
  /// made-up one.
  func report() {
    guard WCSession.isSupported(), let level else { return }
    let session = WCSession.default
    guard session.activationState == .activated else { return }
    try? session.updateApplicationContext([
      "watchBattery": level,
      "at": Date().timeIntervalSince1970,
    ])
  }

  // ── WCSessionDelegate ──────────────────────────────────────────────────────

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    report()
  }
}
