import BackgroundTasks
import Foundation
import WidgetKit

// The two ways the app updates itself without anyone opening it: a silent push
// from the instance, and a `BGAppRefreshTask` iOS schedules on its own budget.
//
// Both do the SAME thing — one full read, then republish the widget summary and
// the Live Activity — so there is exactly one code path to reason about, and a
// silent push that arrives while the app is foregrounded is not special-cased.
//
// Nothing here decides WHAT to fetch: `refreshFromHCC(force:)` owns that, and
// this file owns only "when" and "who is told afterwards".

@MainActor
final class HCCBackgroundRefresh {
  static let shared = HCCBackgroundRefresh()

  /// Declared in `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`.
  nonisolated static let taskIdentifier = "com.gatbontontech.openvitals.hcc.refresh"

  /// Roughly hourly. iOS treats this as the earliest time, not a promise.
  private static let interval: TimeInterval = 60 * 60

  private var didRegister = false
  private var isRunning = false
  /// Set when `BGTaskScheduler` refuses the submission, so the Widgets sheet
  /// can say the phone is only refreshing while the app is open.
  private(set) var scheduleNote: String?

  private init() {}

  // ── Registration ───────────────────────────────────────────────────────────

  /// Called once at launch, before the app finishes launching — iOS requires
  /// every task identifier to be registered by then or it throws.
  func registerTask() {
    guard !didRegister else { return }
    didRegister = true
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
      Task { @MainActor in
        // Re-submit first: a task that is not rescheduled from inside its own
        // handler never runs a second time.
        HCCBackgroundRefresh.shared.schedule()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        let didUpdate = await HCCBackgroundRefresh.shared.run(store: HCCAppServices.shared.store())
        task.setTaskCompleted(success: didUpdate)
      }
    }
  }

  /// Ask for the next window. Safe to call repeatedly; the scheduler replaces
  /// a pending request with the same identifier.
  func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: Self.interval)
    do {
      try BGTaskScheduler.shared.submit(request)
      scheduleNote = nil
    } catch {
      // Unavailable in the simulator, and whenever the app has no background
      // budget. Recorded rather than swallowed — see the Widgets sheet.
      scheduleNote = "Background refresh unavailable (\(error.localizedDescription))."
    }
  }

  // ── The refresh itself ─────────────────────────────────────────────────────

  /// One full read plus the two republishes. Returns whether anything new
  /// arrived, which is what a silent push reports back to iOS as
  /// `.newData` / `.noData`.
  @discardableResult
  func run(store: HealthDataStore) async -> Bool {
    guard HCCProviderSettings.isCloud, HCCSession.currentToken() != nil else { return false }
    guard !isRunning else { return false }
    isRunning = true
    defer { isRunning = false }

    let before = HCCWidgetBridge.summary(from: store)
    await store.refreshFromHCC(force: true)
    let after = HCCWidgetBridge.publish(from: store)
    HCCStrainLiveActivityController.shared.sync(from: store)

    #if DEBUG
    // A background refresh leaves no visible trace, so a Debug build says it ran
    // and where the file it wrote landed. Values only, never a credential.
    print(
      "[HCC] background refresh day=\(after.day)"
        + " recovery=\(after.recovery.map(String.init) ?? "--")"
        + " sleep=\(after.sleep.map(String.init) ?? "--")"
        + " strain=\(after.strain.map { String(format: "%.1f", $0) } ?? "--")"
        + " summary=\(HCCWidgetStore.fileURL?.path ?? "<no container>")"
    )
    #endif

    // `updatedAt` is stamped on every write, so compare everything else.
    return !isSameReading(before, after)
  }

  private func isSameReading(_ lhs: HCCWidgetSummary, _ rhs: HCCWidgetSummary) -> Bool {
    lhs.day == rhs.day
      && lhs.recovery == rhs.recovery
      && lhs.sleep == rhs.sleep
      && lhs.strain == rhs.strain
      && lhs.strainTarget == rhs.strainTarget
      && lhs.hrv == rhs.hrv
      && lhs.rhr == rhs.rhr
  }
}
