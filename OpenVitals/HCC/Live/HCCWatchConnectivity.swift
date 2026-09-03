import Foundation
import WatchConnectivity

// HCC: the phone half of the watch's battery relay (plan §4.7a).
//
// The mirrored workout session already carries the watch's battery while a
// workout is running — `{"t":"batt","level":…}`, decoded by
// `HCCWatchMirrorSource`. That link exists only for the length of the session,
// so the watch also pushes the same number over `WCSession` every time it
// activates, as an application context:
//
//   { "watchBattery": 0.62, "at": 1756900000.5 }
//
// `updateApplicationContext` keeps exactly one dictionary, always the latest,
// delivered whenever this app next runs. That is a good fit for a level and a
// bad fit for anything historical, which is why nothing else travels this way.
//
// The received level is handed to `HCCWatchMirrorSource.handle(payload:)` as a
// `batt` message rather than being written anywhere directly: that keeps ONE
// decoder and ONE route for the watch's battery, whichever link it arrived on,
// and the live state box is already wired to that route
// (`HCCLiveState.watchBattery`, set from `onBatteryChanged`). The consequence
// is worth stating plainly: outside a live session with the watch source
// selected, nothing is listening, so the value lands in
// `HCCWatchMirrorSource.shared.battery` and goes no further. That is the whole
// of what today's UI does with it — no screen draws a watch battery yet.
//
// Nothing here fabricates: a context with no usable level, or one stamped long
// enough ago that it says nothing about now, is dropped rather than shown.

/// Receives the watch's `WCSession` application context. One per process.
final class HCCWatchConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
  static let shared = HCCWatchConnectivity()

  /// A context older than this is not evidence about the watch's battery now.
  /// The watch pushes on every activation, so a fresh context is cheap; a stale
  /// one is the case where the watch has been off, and a day-old percentage
  /// presented as current would be a fabricated reading.
  private static let maxAge: TimeInterval = 12 * 60 * 60

  private var activated = false

  /// Activate the session and drain whatever context is already waiting.
  /// Idempotent, and a no-op where `WCSession` is unsupported (iPad, and any
  /// build running without a paired-watch capability).
  static func activate() {
    #if DEBUG
    HCCWatchConnectivitySelfCheck.runIfRequested()
    #endif
    shared.activateIfNeeded()
  }

  private func activateIfNeeded() {
    guard !activated, WCSession.isSupported() else { return }
    activated = true
    let session = WCSession.default
    session.delegate = self
    session.activate()
  }

  /// Decode one context and route its battery level.
  ///
  /// Internal rather than private so the contract can be exercised without a
  /// watch — see `HCCWatchConnectivitySelfCheck`.
  @discardableResult
  func apply(context: [String: Any], now: Date = Date()) -> Double? {
    guard let level = context["watchBattery"] as? Double, level >= 0, level <= 1 else {
      return nil
    }
    if let at = context["at"] as? Double {
      let reportedAt = Date(timeIntervalSince1970: at)
      guard now.timeIntervalSince(reportedAt) <= Self.maxAge else { return nil }
    }
    // One decoder for the watch's battery, whichever link it came in on.
    let message = #"{"t":"batt","level":\#(level)}"#
    HCCWatchMirrorSource.shared.handle(payload: Data(message.utf8))
    return level
  }

  // ── WCSessionDelegate ──────────────────────────────────────────────────────

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    // A context delivered while this app was not running is held by the OS and
    // is readable the moment activation completes.
    apply(context: session.receivedApplicationContext)
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    apply(context: context)
  }

  /// Required on iOS: the pairing can change under a running app. Reactivating
  /// is the documented response and costs nothing.
  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    WCSession.default.activate()
  }
}

#if DEBUG
/// `HCC_DEBUG_WATCH_CONTEXT=1` runs the four cases this file decides between —
/// a good context, a stale one, one with no level, and one out of range — and
/// prints what each routed to. The watch relay cannot otherwise be exercised in
/// a simulator: `WCSession` needs a paired watch, and there is no watchOS
/// runtime installed here.
enum HCCWatchConnectivitySelfCheck {
  static func runIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_WATCH_CONTEXT"] == "1" else { return }
    let now = Date()
    let fresh = now.timeIntervalSince1970
    let old = now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
    let cases: [(String, [String: Any])] = [
      ("fresh 0.62", ["watchBattery": 0.62, "at": fresh]),
      ("no stamp 0.31", ["watchBattery": 0.31]),
      ("24h old 0.62", ["watchBattery": 0.62, "at": old]),
      ("no level", ["at": fresh]),
      ("out of range", ["watchBattery": 1.4, "at": fresh]),
    ]
    for (name, context) in cases {
      let routed = HCCWatchConnectivity.shared.apply(context: context, now: now)
      // The second half of the route: what the shared mirror source now holds.
      // A dropped context must leave it exactly as it was.
      let landed = HCCWatchMirrorSource.shared.battery
      print(
        "[HCCWatchConnectivity] \(name)"
          + " -> \(routed.map { String($0) } ?? "dropped")"
          + " | mirror source battery = \(landed.map { String($0) } ?? "nil")"
      )
    }
  }
}
#endif
