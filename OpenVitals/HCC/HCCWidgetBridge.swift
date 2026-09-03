import Foundation
import WidgetKit

// The app side of the widget contract: turn whatever the last refresh cached
// into `HCCWidgetSummary`, write it to the shared container, and tell WidgetKit
// to redraw.
//
// It reads the SAME `hcc.homeByDate` entry Home draws from, so a widget and the
// app can never disagree about a number — and it copies rather than recomputes,
// so there is no second place where a score could be derived differently.

@MainActor
enum HCCWidgetBridge {
  /// Build the summary for the day the store last read, write it, and reload.
  ///
  /// Called at the end of every completed read (`performHCCRead`) and from the
  /// background paths. Cheap: one small JSON write and a WidgetKit ping.
  @discardableResult
  static func publish(from store: HealthDataStore) -> HCCWidgetSummary {
    let summary = summary(from: store)
    HCCWidgetStore.write(summary)
    WidgetCenter.shared.reloadAllTimelines()
    return summary
  }

  /// The summary for the store's current day, without writing it.
  static func summary(from store: HealthDataStore) -> HCCWidgetSummary {
    let day = store.hcc.lastRequestedDay ?? HealthDataStore.hccDayKey(Date())
    guard let home = store.hcc.homeByDate[day] else {
      return .empty(day: day, reason: store.hcc.lastError ?? "No reading has been loaded on this iPhone yet.")
    }

    let recovery = value(of: home.score("recovery"))
    let sleep = value(of: home.score("sleep"))
    let strain = value(of: home.score("strain"))

    return HCCWidgetSummary(
      day: home.date,
      recovery: recovery.map { Int($0.rounded()) },
      // The band word comes from the server's own cutoffs when `/instance` has
      // been read, and from the documented fallbacks otherwise — the same call
      // the rings make, so the widget's colour and Home's never disagree.
      recoveryBand: recovery.map { band(for: $0, store: store) },
      sleep: sleep.map { Int($0.rounded()) },
      strain: strain,
      strainTarget: home.strainTarget,
      hrv: home.hrv,
      rhr: home.rhr,
      updatedAt: Date(),
      reason: firstReason(home: home, store: store)
    )
  }

  /// A calibrating score has a number the server says not to act on yet, so it
  /// is treated as absent here exactly as it is on the rings.
  private static func value(of score: HCCHomeScore?) -> Double? {
    guard let score, !score.calibrating else { return nil }
    return score.value
  }

  private static func band(for recovery: Double, store: HealthDataStore) -> String {
    switch HCCRecoveryBand.band(for: recovery, bands: store.hcc.instance?.scoreBands.recovery) {
    case .primed: return "primed"
    case .moderate: return "moderate"
    case .rest: return "rest"
    }
  }

  /// The server's sentence for whichever score is missing, so the widget can
  /// say WHY rather than just showing "--". The first one wins: a widget has
  /// room for one line, and three reasons on a lock-screen accessory is noise.
  private static func firstReason(home: HCCHome, store: HealthDataStore) -> String? {
    for key in ["recovery", "sleep", "strain"] {
      guard let score = home.score(key) else { continue }
      if score.calibrating || score.value == nil, let reason = score.reason, !reason.isEmpty {
        // Through the copy filter, so a manufacturer name in the server's
        // sentence never reaches a lock screen.
        return HealthDataStore.hccNeutralCopy(reason)
      }
    }
    return store.hcc.lastError
  }
}
