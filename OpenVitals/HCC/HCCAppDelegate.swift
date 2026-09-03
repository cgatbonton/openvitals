import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

// The app delegate cloud mode needs, and the only one this app has.
//
// SwiftUI's `App` lifecycle covers everything the bridge build does, but four
// things have no SwiftUI equivalent and all four are Phase 4's: the APNs device
// token, a silent push's background-fetch result, a finished background upload's
// relaunch, and the `UNUserNotificationCenter` delegate that decides what a
// notification does when it is tapped.
//
// EVERY method below returns immediately in bridge mode. That is deliberate and
// load-bearing: a fork that changed how the upstream local-only app behaves —
// asked for push permission it never needed, woke for pushes it never receives —
// would be a fork upstream cannot merge. Cloud mode is the only mode that
// registers for anything.
//
// DEBUG hooks (compiled out of Release, documented in docs/hcc-provider.md):
//   HCC_DEBUG_DEEPLINK=openvitals://…   opens that link a moment after launch,
//                                       which is the only way to exercise the
//                                       notification-tap path in a simulator
//                                       (`simctl` cannot tap a banner).

final class HCCAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  /// The `aps.category` values the server sends (`src/lib/push/payload.ts`).
  /// Registered with no custom actions: an action button that does nothing on
  /// tap is worse than no button, and none of these have a server-side action
  /// to fire yet.
  static let categoryIdentifiers = ["recovery", "reauth", "insight", "weekly", "system"]

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard HCCProviderSettings.isCloud else { return true }

    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().setNotificationCategories(Self.categories())

    // Registration must happen before the launch sequence ends or the task
    // scheduler throws when the identifier is later submitted.
    HCCBackgroundRefresh.shared.registerTask()
    HCCBackgroundRefresh.shared.schedule()

    // The alarm the server holds must survive a reinstall without the user
    // visiting More, so the scheduler is pointed at the store as soon as one
    // exists. `observe(_:)` is idempotent and no-ops if More got there first.
    HCCAppServices.shared.whenStoreAvailable { store in
      // DEBUG: `HCC_DEBUG_SKIP_ALARM=1` leaves the scheduler alone. Starting it
      // raises the AlarmKit permission alert on a fresh install, and a system
      // alert cannot be dismissed by `simctl` — it blocks every other
      // screenshot in this workstream. Release always starts it.
      #if DEBUG
      if ProcessInfo.processInfo.environment["HCC_DEBUG_SKIP_ALARM"] != "1" {
        HCCAlarmScheduler.shared.observe(store)
      }
      #else
      HCCAlarmScheduler.shared.observe(store)
      #endif
      HCCStrainLiveActivityController.shared.sync(from: store)
    }

    // HCC: the Watch companion mirrors its workout session to the phone; the
    // handler has to be installed before any session arrives (plan §4.7a).
    HCCWatchMirrorSource.installHandler()

    Task { await self.registerForPushIfAllowed() }

    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      // The onboarding notifications step may have granted permission since
      // launch; re-asking here is what turns that grant into a device token
      // without making the user relaunch.
      Task { @MainActor in await HCCAppDelegate.registerForPushIfAllowedStatic() }
    }

    #if DEBUG
    openDebugDeepLinkIfRequested()
    runDebugSilentPushIfRequested()
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      HCCStrainLiveActivityController.shared.debugStartFixtureIfRequested()
    }
    #endif
    return true
  }

  // ── APNs registration ──────────────────────────────────────────────────────

  private func registerForPushIfAllowed() async {
    await Self.registerForPushIfAllowedStatic()
  }

  /// Ask iOS for a device token only when the user has already allowed
  /// notifications. Calling `registerForRemoteNotifications()` never prompts,
  /// but a token for a denied app is a token the server would push into a void.
  @MainActor
  fileprivate static func registerForPushIfAllowedStatic() async {
    guard HCCProviderSettings.isCloud else { return }
    #if DEBUG
    await grantProvisionalIfRequested()
    #endif
    await HCCPushRegistrar.shared.refreshAuthorization()
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      UIApplication.shared.registerForRemoteNotifications()
    default:
      return
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Hex, lowercase, no separators — the exact shape the server's
    // `/push-devices` schema validates (`/^[0-9a-fA-F]{32,200}$/`).
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    Task { @MainActor in HCCPushRegistrar.shared.register(hex) }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    Task { @MainActor in HCCPushRegistrar.shared.recordRegistrationFailure(error) }
  }

  // ── Silent push ────────────────────────────────────────────────────────────

  /// `aps.content-available: 1`, sent with `apns-push-type: background`.
  ///
  /// The server sends these so the widgets and the Live Activity can move
  /// without the app being opened. iOS grants a few seconds and counts how
  /// often the result was `.noData`, so the honest answer matters: reporting
  /// new data that did not arrive is how an app loses its background budget.
  ///
  /// The completion-handler form rather than the `async` one on purpose: the
  /// async import carries `[AnyHashable: Any]` across an actor boundary, and
  /// nothing here reads the payload — a silent push is a nudge, not data.
  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard HCCProviderSettings.isCloud else {
      completionHandler(.noData)
      return
    }
    Task { @MainActor in
      let didUpdate = await HCCBackgroundRefresh.shared.run(store: HCCAppServices.shared.store())
      completionHandler(didUpdate ? .newData : .noData)
    }
  }

  // ── Background uploads ─────────────────────────────────────────────────────

  /// iOS relaunched the app because a background upload finished.
  ///
  /// The HealthKit uploader's background `URLSession` is what these belong to;
  /// handing it the completion handler is what lets the system stop holding the
  /// app awake once the session has delivered its events.
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == HCCHealthKitUploader.backgroundSessionIdentifier else {
      completionHandler()
      return
    }
    HCCHealthKitBackgroundDelivery.shared.setCompletionHandler(completionHandler)
  }

  // ── Notification presentation and taps ─────────────────────────────────────

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    #if DEBUG
    // A delivered notification leaves no trace a script can read; this is how a
    // simulator run proves the payload arrived and with which category.
    let content = notification.request.content
    print("[HCC] willPresent category=\(content.categoryIdentifier) title=\(content.title)")
    #endif
    return [.banner, .list, .sound]
  }

  /// A tapped notification.
  ///
  /// The deep link is opened through `UIApplication.open` rather than being
  /// routed here directly, so a push tap goes through exactly the same
  /// `onOpenURL` → `AppRouter.handleDeepLink` path a link from anywhere else
  /// does. One router, one set of destinations, one thing to test.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let userInfo = response.notification.request.content.userInfo
    // `deepLink` rides at the TOP level of the payload, not inside `aps`:
    // Apple owns the `aps` namespace and drops unknown keys from it.
    guard let raw = userInfo["deepLink"] as? String,
          let url = URL(string: raw),
          url.scheme?.lowercased() == "openvitals"
    else {
      return
    }
    #if DEBUG
    print("[HCC] notification tapped deepLink=\(raw)")
    #endif
    // The completion-handler overload, which is the synchronous one — the
    // `async` variant would suspend this delegate call on the tap.
    await MainActor.run { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
  }

  // ── Categories ─────────────────────────────────────────────────────────────

  private static func categories() -> Set<UNNotificationCategory> {
    Set(
      categoryIdentifiers.map { identifier in
        UNNotificationCategory(
          identifier: identifier,
          actions: [],
          intentIdentifiers: [],
          options: []
        )
      }
    )
  }

  // ── Verification hook ──────────────────────────────────────────────────────

  #if DEBUG
  /// The same `HCC_DEBUG_NOTIF_PROVISIONAL=1` hook P3-A's alarm scheduler uses,
  /// applied to the push path.
  ///
  /// Provisional and not full authorization on purpose: a full prompt is a
  /// system alert, and `simctl` cannot tap one — the user declined
  /// screen-control access to the Simulator, so there is no path to a granted
  /// state that a script can reach. Provisional is granted silently, which is
  /// exactly what makes the delivery path testable without a tap.
  private static func grantProvisionalIfRequested() async {
    let center = UNUserNotificationCenter.current()
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_NOTIF_PROVISIONAL"] == "1",
          await center.notificationSettings().authorizationStatus == .notDetermined
    else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
  }

  /// `HCC_DEBUG_SILENT_PUSH=1` hands the delegate the payload a silent push
  /// carries, through the real entry point.
  ///
  /// It exists because the iOS Simulator does not deliver a background wake:
  /// `xcrun simctl push` presents alert payloads but an `aps.content-available`
  /// one never reaches `didReceiveRemoteNotification` (verified — the alert in
  /// the same run does arrive). This calls the same method the system would, so
  /// what is unverified is Apple's delivery, not this app's handling.
  private func runDebugSilentPushIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SILENT_PUSH"] == "1" else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      self.application(
        UIApplication.shared,
        didReceiveRemoteNotification: ["aps": ["content-available": 1]]
      ) { result in
        print("[HCC] silent push handled result=\(result.rawValue)")
      }
    }
  }

  /// `HCC_DEBUG_DEEPLINK=openvitals://health/recovery` opens that link shortly
  /// after launch. `simctl` can deliver a push but cannot tap the banner it
  /// draws, so this is the only way to screenshot where a tap LANDS; it runs
  /// the identical `UIApplication.open` the tap handler above runs.
  private func openDebugDeepLinkIfRequested() {
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_DEEPLINK"],
          !raw.isEmpty,
          let url = URL(string: raw)
    else {
      return
    }
    Task { @MainActor in
      // Long enough for the shell to install its `onOpenURL` handler.
      try? await Task.sleep(for: .seconds(2))
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }
  #endif
}

// ── Shared references ────────────────────────────────────────────────────────

/// The one place non-view code can reach the app's `HealthDataStore`.
///
/// The store is a `@StateObject` on the shell, which means it does not exist
/// until a window does — and a silent push or a `BGAppRefreshTask` wakes the
/// process with no window at all. So the shell's store REGISTERS itself on its
/// first completed cloud read, and a background wake that finds none builds one
/// of its own rather than skipping the refresh. Either way there is exactly one
/// store in the process, and callbacks queued before it existed run as soon as
/// it does.
@MainActor
final class HCCAppServices {
  static let shared = HCCAppServices()

  private weak var registered: HealthDataStore?
  /// Retained only when a background wake had to build its own.
  private var backgroundStore: HealthDataStore?
  private var pending: [(HealthDataStore) -> Void] = []

  private init() {}

  /// Called from `performHCCRead` — the first cloud read of the process.
  func register(_ store: HealthDataStore) {
    guard registered !== store else { return }
    registered = store
    if backgroundStore !== store { backgroundStore = nil }
    let callbacks = pending
    pending = []
    for callback in callbacks { callback(store) }
  }

  /// The process's store, building one if a background wake got here first.
  func store() -> HealthDataStore {
    if let registered { return registered }
    if let backgroundStore { return backgroundStore }
    let store = HealthDataStore()
    backgroundStore = store
    let callbacks = pending
    pending = []
    for callback in callbacks { callback(store) }
    return store
  }

  /// Run `body` with the store — now if there is one, otherwise on the first
  /// read that produces one.
  func whenStoreAvailable(_ body: @escaping (HealthDataStore) -> Void) {
    if let store = registered ?? backgroundStore {
      body(store)
      return
    }
    pending.append(body)
  }
}
