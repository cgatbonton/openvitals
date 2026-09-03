import AlarmKit
import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

// The phone side of the alarm.
//
// `HCCAlarmSheet` writes the INTENT — a wall clock, a mode, a smart window —
// to the server, because that row is read by the web app too. This file is the
// only place that turns that intent into something the OS will actually ring,
// and it is deliberately the only place: a second scheduler would be free to
// resolve a different minute than the one the sheet shows.
//
// Three rules it keeps:
//
//  * **The server's row is the input, never the output.** Nothing here writes
//    back. If the phone cannot schedule, the row stands and the sheet says the
//    phone did not.
//  * **One alarm, cancelled and re-scheduled on every change.** The id is a
//    UUID minted once and kept in `UserDefaults`, so a reinstall gets a fresh
//    one and an update never orphans the old one.
//  * **A wake time is a wall clock in the INSTANCE's timezone.** The device's
//    own zone never enters the arithmetic — a phone that flew somewhere still
//    rings at the hour the Command Center reasons about.

/// Whether the OS will let this app raise a real alarm.
enum HCCAlarmAuthorization: Equatable {
  case notDetermined
  case authorized
  case denied
}

/// What is actually holding the wake time right now.
enum HCCAlarmEngine: Equatable {
  /// AlarmKit — breaks through silent mode and Focus, like the system clock.
  case alarmKit
  /// A time-sensitive notification, because AlarmKit was refused or unavailable.
  case notification
  /// Nothing scheduled: the alarm is off, or nothing has been read yet.
  case none
}

/// What the notification fallback will amount to, once registered.
///
/// Registering the request and being allowed to SHOW it are two different
/// facts, and the status card is only allowed to say "scheduled" for the
/// second — hence three outcomes rather than a bool.
enum HCCAlarmFallbackDelivery: Equatable {
  /// Registered, and notifications are allowed: it will alert.
  case willAlert
  /// Registered, but the user has not answered the permission prompt yet.
  case awaitingPermission
  /// Registered, and notifications are refused: nothing will be shown.
  case blocked
  /// The OS would not take the request at all.
  case failed
}

/// The single alarm this app hands the OS, resolved from the server's row.
///
/// `Equatable` on purpose: re-resolving on every store change is cheap, and
/// comparing against the last resolution is what stops a re-render from
/// cancelling and re-arming an alarm that did not move.
struct HCCAlarmResolution: Equatable {
  let isOn: Bool
  /// The instant it should fire. `nil` while on but unresolvable — a malformed
  /// `HH:MM` from the server is a reason to say nothing, not to pick a minute.
  let fireAt: Date?
  /// True when the server's sleep plan moved the alarm inside its smart window.
  let usedSleepPlan: Bool

  static let off = HCCAlarmResolution(isOn: false, fireAt: nil, usedSleepPlan: false)
}

@MainActor
final class HCCAlarmScheduler: ObservableObject {
  static let shared = HCCAlarmScheduler()

  @Published private(set) var authorization: HCCAlarmAuthorization = .notDetermined
  @Published private(set) var scheduledFor: Date?
  @Published private(set) var lastError: String?
  @Published private(set) var engine: HCCAlarmEngine = .none

  private weak var store: HealthDataStore?
  private var storeObserver: AnyCancellable?
  private var foregroundObserver: (any NSObjectProtocol)?
  private var applyTask: Task<Void, Never>?
  private var commitTask: Task<Void, Never>?
  /// The last resolution handed to the OS, so an unchanged one is a no-op.
  private var lastApplied: HCCAlarmResolution?
  private var fallbackDelivery: HCCAlarmFallbackDelivery?
  private var isAskingNotificationPermission = false

  private static let alarmIdKey = "hcc.alarm.scheduledAlarmId"
  private static let notificationId = "hcc.alarm.fallback"

  /// Registering the foreground observer in `init` is what makes "touch
  /// `.shared` once" enough to keep the alarm honest for the rest of the
  /// process: a phone that sat overnight re-resolves the moment it comes back,
  /// so "Scheduled for Thu 6:30 a.m." is never yesterday's answer.
  private init() {
    authorization = Self.readAuthorization()
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reapplyFromStore(force: true) }
    }
  }

  // ── Wiring ─────────────────────────────────────────────────────────────────

  /// Follow one store's cloud state.
  ///
  /// `hcc` is a plain reference on `HealthDataStore`, so `objectWillChange` is
  /// the only signal a read landed — see `hccWillChange()`. It fires BEFORE the
  /// mutation, so the re-resolve is hopped onto the next main-actor turn rather
  /// than reading the value that is about to be replaced.
  func observe(_ store: HealthDataStore) {
    guard self.store !== store else { return }
    self.store = store
    storeObserver = store.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.reapplyFromStore(force: false) }
    }
    reapplyFromStore(force: true)
  }

  private func reapplyFromStore(force: Bool) {
    applyTask?.cancel()
    applyTask = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled, let store = self.store else { return }
      self.apply(alarm: store.hcc.alarm, sleepPlan: store.hcc.sleepPlan, force: force)
    }
  }

  /// Resolve the server's row and hand the result to the OS.
  ///
  /// Called by the sheet right after a successful save, and by the store
  /// observer / foreground hook. A `nil` alarm means the row has not been read
  /// yet — which is not the same as "off", so nothing is cancelled.
  func apply(alarm: HCCAlarm?, sleepPlan: HCCSleepPlan?, force: Bool = false) {
    guard let alarm else { return }
    let resolution = Self.resolve(
      alarm: alarm,
      plan: sleepPlan,
      now: Date(),
      zone: HCCInstanceZone.current
    )
    guard force || resolution != lastApplied else { return }
    lastApplied = resolution

    #if DEBUG
    let when = resolution.fireAt.map(ISO8601DateFormatter().string(from:)) ?? "nil"
    print("[HCCAlarmScheduler] resolved on=\(resolution.isOn) fireAt=\(when) fromPlan=\(resolution.usedSleepPlan) zone=\(HCCInstanceZone.current.identifier)")
    #endif

    commitTask?.cancel()
    commitTask = Task { @MainActor [weak self] in
      await self?.commit(resolution)
    }
  }

  // ── Resolution ─────────────────────────────────────────────────────────────

  /// The server's row → the instant to ring, in the instance's timezone.
  ///
  /// `exact` is the next occurrence of the wall clock. `goal` prefers the
  /// server's `recommendedWake`, but ONLY when it lands inside the smart window
  /// the user set — `[time − smartWindowMin, time]`. Anything outside that is
  /// the server disagreeing with the user's own ceiling, and the user's ceiling
  /// wins; a wake time later than the alarm would be an alarm that overslept.
  ///
  /// Pure and static so the arithmetic can be reasoned about (and printed) on
  /// its own, with no OS call in the way.
  static func resolve(
    alarm: HCCAlarm,
    plan: HCCSleepPlan?,
    now: Date,
    zone: TimeZone
  ) -> HCCAlarmResolution {
    guard alarm.on else { return .off }
    guard let minutes = HCCWallClock.minutes(from: alarm.time),
          let target = nextOccurrence(minutesFromMidnight: minutes, after: now, zone: zone)
    else {
      // A wall clock the contract says cannot occur. Say "on, unresolved"
      // rather than inventing a minute.
      return HCCAlarmResolution(isOn: true, fireAt: nil, usedSleepPlan: false)
    }

    let exact = HCCAlarmResolution(isOn: true, fireAt: target, usedSleepPlan: false)
    guard alarm.mode == "goal" else { return exact }

    let window = TimeInterval(max(alarm.smartWindowMin, 0) * 60)
    guard let wake = HCCTime.instant(plan?.recommendedWake),
          wake > now,
          wake <= target,
          wake >= target.addingTimeInterval(-window)
    else { return exact }

    return HCCAlarmResolution(isOn: true, fireAt: wake, usedSleepPlan: true)
  }

  /// The next `HH:MM` strictly after `now`, on the instance's calendar.
  static func nextOccurrence(minutesFromMidnight: Int, after now: Date, zone: TimeZone) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = DateComponents()
    components.hour = minutesFromMidnight / 60
    components.minute = minutesFromMidnight % 60
    components.second = 0
    // `.nextTime` rather than `.nextTimePreservingSmallerComponents`: a DST
    // spring-forward can delete the requested minute, and the next real minute
    // is a better answer than no alarm at all.
    return calendar.nextDate(
      after: now,
      matching: components,
      matchingPolicy: .nextTime,
      direction: .forward
    )
  }

  // ── Commit ─────────────────────────────────────────────────────────────────

  private func commit(_ resolution: HCCAlarmResolution) async {
    guard resolution.isOn, let fireAt = resolution.fireAt else {
      cancelAlarmKit()
      cancelNotification()
      scheduledFor = nil
      engine = .none
      lastError = resolution.isOn ? "The saved wake time could not be read." : nil
      return
    }

    let state = await requestAuthorizationIfNeeded()
    authorization = state

    if state == .authorized, await scheduleAlarmKit(at: fireAt) {
      cancelNotification()
      scheduledFor = fireAt
      engine = .alarmKit
      lastError = nil
      return
    }

    // AlarmKit refused, or is not there. A time-sensitive notification is the
    // honest second best — it can be silenced, so the sheet says so rather than
    // letting the row imply a real alarm.
    cancelAlarmKit()
    let delivery = await scheduleNotification(at: fireAt)
    engine = .notification
    fallbackDelivery = delivery

    switch delivery {
    case .willAlert:
      scheduledFor = fireAt
      lastError = nil
    case .awaitingPermission:
      // The request is armed; the OS is asking the user whether it may be
      // shown. Claiming "scheduled" before that answer would be a promise the
      // next tap could break.
      scheduledFor = nil
      lastError = nil
      askForNotificationPermission()
    case .blocked:
      scheduledFor = nil
      lastError = "Nothing will wake you: this iPhone has not allowed alarms or notifications for Command Center."
    case .failed:
      scheduledFor = nil
      engine = .none
    }
  }

  /// Ask for notification permission WITHOUT holding up the commit.
  ///
  /// The prompt is modal and can sit unanswered for as long as the user likes.
  /// Awaiting it inside `commit` meant the alarm was not armed until the tap
  /// landed — the one moment the arming actually mattered. So the request is
  /// registered first, the question is asked here, and the answer re-runs the
  /// resolution so the card catches up.
  private func askForNotificationPermission() {
    guard !isAskingNotificationPermission else { return }
    isAskingNotificationPermission = true
    Task { @MainActor [weak self] in
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      self?.isAskingNotificationPermission = false
      self?.reapplyFromStore(force: true)
    }
  }

  /// AlarmKit's answer, asking once if it has never been asked.
  ///
  /// A throw here is NOT recorded as `lastError`: "AlarmKit said no" is the
  /// documented route into the notification fallback, not something the user
  /// did wrong, and putting a framework error string at the top of the card
  /// would bury the sentence that actually tells them what this phone will do.
  private func requestAuthorizationIfNeeded() async -> HCCAlarmAuthorization {
    let current = Self.readAuthorization()
    guard current == .notDetermined else { return current }
    do {
      return Self.map(try await AlarmManager.shared.requestAuthorization())
    } catch {
      #if DEBUG
      print("[HCCAlarmScheduler] AlarmKit authorization unavailable: \(error)")
      #endif
      return .denied
    }
  }

  private static func readAuthorization() -> HCCAlarmAuthorization {
    map(AlarmManager.shared.authorizationState)
  }

  private static func map(_ state: AlarmManager.AuthorizationState) -> HCCAlarmAuthorization {
    switch state {
    case .authorized: .authorized
    case .denied: .denied
    case .notDetermined: .notDetermined
    @unknown default: .denied
    }
  }

  // ── AlarmKit ───────────────────────────────────────────────────────────────

  /// One id for the life of the install, so a re-schedule replaces rather than
  /// stacks.
  private static var alarmId: UUID {
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: alarmIdKey), let stored = UUID(uuidString: raw) {
      return stored
    }
    let minted = UUID()
    defaults.set(minted.uuidString, forKey: alarmIdKey)
    return minted
  }

  /// Arm the one alarm, replacing whatever was armed before.
  ///
  /// Awaited rather than fired and forgotten: the status line is a claim about
  /// what the OS holds, so it must not be written until the OS has agreed.
  private func scheduleAlarmKit(at date: Date) async -> Bool {
    cancelAlarmKit()
    let attributes = AlarmAttributes<HCCAlarmMetadata>(
      presentation: AlarmPresentation(alert: Self.alertPresentation()),
      metadata: HCCAlarmMetadata(),
      tintColor: HCCTheme.Color.accent
    )
    let configuration = AlarmManager.AlarmConfiguration.alarm(
      schedule: .fixed(date),
      attributes: attributes
    )
    do {
      _ = try await AlarmManager.shared.schedule(id: Self.alarmId, configuration: configuration)
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  private func cancelAlarmKit() {
    try? AlarmManager.shared.cancel(id: Self.alarmId)
  }

  private static func alertPresentation() -> AlarmPresentation.Alert {
    let title: LocalizedStringResource = "Command Center"
    if #available(iOS 26.1, *) {
      return AlarmPresentation.Alert(title: title)
    }
    return legacyAlertPresentation(title: title)
  }

  /// iOS 26.0 only. The 26.1 initialiser does not exist there, so the stop
  /// button still has to be supplied; the declaration carries the same
  /// deprecation as the initialiser it calls so the compiler does not warn
  /// about a call the deployment target requires.
  @available(iOS, deprecated: 26.1, message: "Pre-26.1 initialiser, kept for the 26.0 deployment target.")
  private static func legacyAlertPresentation(title: LocalizedStringResource) -> AlarmPresentation.Alert {
    AlarmPresentation.Alert(
      title: title,
      stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
    )
  }

  // ── Notification fallback ──────────────────────────────────────────────────

  /// Arm the fallback, and say what will come of it.
  ///
  /// Permission is settled BEFORE the request is registered, because iOS
  /// silently discards a request added while authorization is undetermined —
  /// measured, not assumed: `add` returns without throwing and
  /// `pendingNotificationRequests()` then comes back empty. So an undetermined
  /// state registers nothing, asks (without blocking, see
  /// `askForNotificationPermission`), and the answer re-runs this whole
  /// resolution.
  private func scheduleNotification(at date: Date) async -> HCCAlarmFallbackDelivery {
    let center = UNUserNotificationCenter.current()
    center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId])

    #if DEBUG
    await Self.grantProvisionalIfRequested(center)
    #endif

    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional, .ephemeral: break
    case .notDetermined: return .awaitingPermission
    default: return .blocked
    }

    let content = UNMutableNotificationContent()
    content.title = "Command Center"
    content.body = "Your wake time."
    content.sound = .default
    content.interruptionLevel = .timeSensitive

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = HCCInstanceZone.current
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    // Carried explicitly: without it the trigger is read against the DEVICE's
    // calendar, which is the one zone this whole file keeps out of the maths.
    components.timeZone = HCCInstanceZone.current

    let request = UNNotificationRequest(
      identifier: Self.notificationId,
      content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    )
    do {
      try await center.add(request)
    } catch {
      lastError = error.localizedDescription
      return .failed
    }

    #if DEBUG
    let pending = await center.pendingNotificationRequests()
      .first { $0.identifier == Self.notificationId }
    let next = (pending?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
    print("[HCCAlarmScheduler] fallback registered=\(pending != nil) nextTrigger=\(next.map(ISO8601DateFormatter().string(from:)) ?? "nil")")
    #endif

    return .willAlert
  }

  #if DEBUG
  /// Verification hook, DEBUG only. `HCC_DEBUG_NOTIF_PROVISIONAL=1` takes
  /// PROVISIONAL notification authorization, which iOS grants silently with no
  /// prompt.
  ///
  /// It exists because the iOS Simulator cannot grant AlarmKit at all — its
  /// `mobiletimerd` has no permission UI and answers
  /// `AuthorizationManagerError 1` — so the notification fallback is the only
  /// path a simulator run can exercise, and that path is otherwise gated behind
  /// a modal prompt no scripted run can tap. Compiled out of Release, and inert
  /// without the variable; provisional is NEVER requested by the shipping app,
  /// because a quiet Notification-Centre entry is not an alarm.
  private static func grantProvisionalIfRequested(_ center: UNUserNotificationCenter) async {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_NOTIF_PROVISIONAL"] == "1",
          await center.notificationSettings().authorizationStatus == .notDetermined
    else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound, .provisional])
  }
  #endif

  private func cancelNotification() {
    UNUserNotificationCenter.current()
      .removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
  }

  // ── Copy ───────────────────────────────────────────────────────────────────

  /// "Scheduled for Thu 6:30 a.m." — what this phone will actually do.
  ///
  /// The mockup has no such line; it is here because the sheet used to say the
  /// phone would not ring at all, and a screen that has stopped being true is
  /// worse than one that never claimed anything.
  var statusLine: String {
    if let scheduledFor {
      return "Scheduled for \(Self.stamp(scheduledFor))"
    }
    if fallbackDelivery == .awaitingPermission {
      return "Waiting for notification permission"
    }
    if let lastError { return lastError }
    if lastApplied?.isOn == false { return "Off" }
    return "Not scheduled on this iPhone yet"
  }

  /// The second, muted line — present only when something is worth knowing
  /// beyond the time itself.
  var statusNote: String? {
    switch engine {
    case .notification:
      "Notification fallback — enable alarms in Settings"
    case .alarmKit:
      lastApplied?.usedSleepPlan == true
        ? "Moved inside your smart wake window by tonight's sleep plan."
        : nil
    case .none:
      nil
    }
  }

  private static func stamp(_ date: Date) -> String {
    let zone = HCCInstanceZone.current
    let weekday = DateFormatter()
    weekday.locale = Locale(identifier: "en_US_POSIX")
    weekday.timeZone = zone
    weekday.dateFormat = "EEE"
    return "\(weekday.string(from: date)) \(HCCWallClock.clock(date, timezone: zone.identifier))"
  }
}

/// AlarmKit requires a metadata type on every alarm. This app has exactly one
/// alarm and nothing to carry on it, so the type is empty rather than a bag of
/// values a Live Activity would then be free to render inconsistently with the
/// app.
struct HCCAlarmMetadata: AlarmMetadata {}
