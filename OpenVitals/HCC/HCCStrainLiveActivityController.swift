import ActivityKit
import Foundation

// The strain Live Activity: today's strain against today's target, on the lock
// screen and in the Dynamic Island.
//
// Three things this deliberately does NOT do:
//
//  * It never starts itself. The toggle in More defaults to OFF, because a Live
//    Activity is a persistent claim on the lock screen and the app should not
//    make one on the owner's behalf.
//  * It never invents a number. No strain for today means no activity at all,
//    rather than a bar sitting at zero — a zero would read as "you have done
//    nothing today", which is a claim the server has not made.
//  * It never posts the push token anywhere. The activity is requested with
//    `pushType: .token` so the instance CAN drive it later, and the latest token
//    is kept here for that day; there is no server route to send it to yet and
//    inventing one would be a call to an endpoint that does not exist.

@MainActor
final class HCCStrainLiveActivityController: ObservableObject {
  static let shared = HCCStrainLiveActivityController()

  private static let enabledKey = "open_vitals.hcc.liveActivity.strain.enabled"

  /// The owner's switch. Off until they turn it on.
  @Published private(set) var isEnabled: Bool
  /// Why there is no activity on screen, when the switch is on.
  @Published private(set) var note: String?
  /// The APNs token for the running activity, hex. Kept for the day the server
  /// gains a route to accept it; never sent anywhere today.
  @Published private(set) var pushTokenHex: String?

  private var activity: Activity<HCCStrainActivityAttributes>?
  private var tokenTask: Task<Void, Never>?

  private init() {
    #if DEBUG
    // `HCC_DEBUG_LIVE_ACTIVITY=1` turns the switch on FOR THIS LAUNCH ONLY. The
    // toggle is a tap and `simctl` cannot tap, so this is how the Live Activity
    // gets on screen for a screenshot. Deliberately not written to defaults: a
    // verification run must not leave the next launch — or the next agent's —
    // with a setting the owner never chose.
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
      || ProcessInfo.processInfo.environment["HCC_DEBUG_LIVE_ACTIVITY"] == "1"
    #else
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    #endif
    // A Live Activity outlives the process that started it. Reclaiming the
    // running one is what makes a relaunch update it instead of orphaning it —
    // and orphaned is the bad state: a banner that never changes again and that
    // nothing in the app can end.
    activity = Activity<HCCStrainActivityAttributes>.activities.first
    if let activity { observeToken(of: activity) }
  }

  // ── The toggle ─────────────────────────────────────────────────────────────

  func setEnabled(_ enabled: Bool, store: HealthDataStore?) {
    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    if enabled {
      if let store { sync(from: store) } else { note = "No reading loaded yet." }
    } else {
      end()
    }
  }

  /// The row's right-hand line on More.
  var rowDetail: String {
    guard isEnabled else { return "Off" }
    if activity != nil { return "On · showing today" }
    return note.map { "On · \($0)" } ?? "On · waiting for today's strain"
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  /// Start, update or end the activity to match what the store now holds.
  /// Called after every completed read and from the background paths.
  func sync(from store: HealthDataStore) {
    guard isEnabled else {
      end()
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      note = "Live Activities are off in iOS Settings."
      end()
      return
    }

    let summary = HCCWidgetBridge.summary(from: store)
    let today = HealthDataStore.hccDayKey(Date())
    // Only ever today: a Live Activity for a day the user is browsing backwards
    // into would put a past number on the lock screen as if it were current.
    guard summary.day == today else {
      note = "Showing an earlier day in the app."
      return
    }
    guard let strain = summary.strain else {
      // The STRAIN score's own reason, not whichever score the widget summary
      // happened to explain first — this row is about strain.
      let strainScore = store.hcc.homeByDate[today]?.score("strain")
      note = HealthDataStore.hccNeutralCopy(strainScore?.reason)
        ?? "No strain scored for today yet."
      end()
      return
    }

    let state = HCCStrainActivityAttributes.ContentState(
      strain: strain,
      target: summary.strainTarget,
      recovery: summary.recovery,
      updatedAt: Date(),
      reason: summary.reason
    )

    if let activity, activity.attributes.day == today {
      note = nil
      Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      return
    }
    // A different day (or nothing running): end yesterday's and start today's.
    end()
    start(day: today, state: state)
  }

  private func start(day: String, state: HCCStrainActivityAttributes.ContentState) {
    do {
      let activity = try Activity.request(
        attributes: HCCStrainActivityAttributes(day: day),
        content: ActivityContent(state: state, staleDate: nil),
        // `.token` rather than nil so the instance can update the banner while
        // the app is closed once a route exists to accept the token.
        pushType: .token
      )
      self.activity = activity
      note = nil
      observeToken(of: activity)
    } catch {
      note = error.localizedDescription
    }
  }

  private func observeToken(of activity: Activity<HCCStrainActivityAttributes>) {
    tokenTask?.cancel()
    tokenTask = Task { [weak self] in
      for await token in activity.pushTokenUpdates {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        await MainActor.run { self?.pushTokenHex = hex }
      }
    }
  }

  #if DEBUG
  /// `HCC_DEBUG_LIVE_ACTIVITY_FIXTURE=1` starts the activity from a fixture.
  ///
  /// Only a day with a NON-calibrating strain starts a real one, and a fixture
  /// instance has none until the engine has its baseline — so without this the
  /// presentation could not be screenshotted at all. The numbers it shows are
  /// this hook's, not the instance's; nothing in a Release build can reach it,
  /// and `sync(from:)` overwrites the state with the server's the moment a real
  /// score exists. Same category as `HCC_DEBUG_HK_SEED`.
  func debugStartFixtureIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_LIVE_ACTIVITY_FIXTURE"] == "1",
          ActivityAuthorizationInfo().areActivitiesEnabled,
          activity == nil
    else {
      return
    }
    end()
    start(
      day: HealthDataStore.hccDayKey(Date()),
      state: HCCStrainActivityAttributes.ContentState(
        strain: 12.4, target: 14.9, recovery: 69, updatedAt: Date(), reason: nil
      )
    )
  }
  #endif

  /// End the activity — a day rollover, the toggle going off, or sign-out.
  func end() {
    tokenTask?.cancel()
    tokenTask = nil
    pushTokenHex = nil
    guard let activity else { return }
    self.activity = nil
    Task { await activity.end(nil, dismissalPolicy: .immediate) }
  }
}
