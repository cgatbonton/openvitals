import BackgroundTasks
import Foundation
import HealthKit
import UIKit

// Apple Watch → Health Command Center upload (plan §4.6).
//
// What this does, in one line: reads the wearable streams the Watch records
// into HealthKit, keeps only what the WATCH itself produced, and POSTs them to
// the instance's `/api/ingest/apple-health` with the INGEST token, so they land
// as `APPLE_HEALTH` rows tagged `sourceDetail: "Apple Watch"`.
//
// The source filter is the load-bearing part. Apple Health is a merged store:
// Google Health writes Fitbit's readings into it, third-party apps write their
// own, and a person can type a value in by hand. Uploading all of that would
// land another device's numbers under the Watch's name and quietly corrupt the
// co-wear comparison the instance exists to make. So a sample is kept only when
// Apple's own health daemon wrote it AND the sample carries an Apple Watch
// device — see `isWatchSourced`.
//
// Anchors advance only after the server acknowledges a batch (2xx). A batch that
// could not be delivered is written to disk first and retried later; nothing is
// marked as uploaded because the app *tried* to upload it.
//
// DEBUG hooks (all compiled out of Release, documented in docs/hcc-provider.md):
//   HCC_DEBUG_HK_ANY_SOURCE=1   disable the Watch source filter
//   HCC_DEBUG_HK_SEED=1         write a small fixture into HealthKit first
//   HCC_DEBUG_HK_SYNC=1         run one sweep at launch
//   HCC_DEBUG_HK_FIXTURE=1      print the encoded wire batch and stop
//   HCC_DEBUG_INGEST_TOKEN=…    use this ingest bearer instead of the Keychain's

// ── State ────────────────────────────────────────────────────────────────────

/// Whether Health will still show a prompt if asked.
///
/// HealthKit never reveals whether a READ was granted — a denied type simply
/// returns no samples — so this says what was asked, never what was allowed.
/// The screen's copy has to keep that distinction.
enum HCCHealthKitAuthorization: Equatable {
  case unavailable
  case notRequested
  case requested
  case unknown

  var label: String {
    switch self {
    case .unavailable: "Health data unavailable on this device"
    case .notRequested: "Not authorized yet"
    case .requested: "Requested in Health"
    case .unknown: "Unknown"
    }
  }
}

/// One upload's outcome, as the server counted it.
struct HCCHealthKitUploadOutcome: Equatable {
  let at: Date
  let batches: Int
  let written: Int
  let skipped: Int
  let activities: Int
}

/// One stream and whether this device has ever read past its first page.
struct HCCHealthKitStreamStatus: Equatable, Identifiable {
  let label: String
  let hasAnchor: Bool

  var id: String { label }
}

/// Everything the sheet renders. A value struct so a view redraws on one
/// `@Published` change rather than on seven.
struct HCCHealthKitUploadState: Equatable {
  var enabled = false
  var authorization: HCCHealthKitAuthorization = .unknown
  var isWorking = false
  var lastUploadAt: Date?
  var lastResult: HCCHealthKitUploadOutcome?
  var pendingBatches = 0
  var lastError: String?
  var streams: [HCCHealthKitStreamStatus] = []
  /// Set when background delivery could not be turned on (it is unsupported in
  /// the simulator, for one). Stated rather than hidden — without it the phone
  /// only uploads while the app is open.
  var backgroundNote: String?

  /// The one line the More row shows.
  var rowStatus: String {
    if !enabled { return "Off" }
    switch authorization {
    case .unavailable: return "Unavailable"
    case .notRequested: return "Waiting for authorization"
    case .requested, .unknown: break
    }
    guard let lastUploadAt else { return "On · no upload yet" }
    return "On · last upload \(Self.clock.string(from: lastUploadAt))"
  }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = HCCInstanceZone.current
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
}

// ── Persistence ──────────────────────────────────────────────────────────────

/// Anchors, the enabled flag, the daily-total watermark and the retry queue.
///
/// Everything lives in the App Group so a later Watch or widget target can read
/// the same cursors. When the group container is not available (an unsigned
/// simulator build, for instance) both fall back to the app's own storage rather
/// than dropping writes silently — the fallback is reported on the sheet.
enum HCCHealthKitStore {
  static let appGroup = "group.com.gatbontontech.openvitals-hcc"

  private static let enabledKey = "open_vitals.hcc.hk.enabled"
  private static let dailyWatermarkKey = "open_vitals.hcc.hk.dailyTotalsThrough"
  private static let anchorKeyPrefix = "open_vitals.hcc.hk.anchor."

  static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

  static var usesAppGroup: Bool { UserDefaults(suiteName: appGroup) != nil }

  static var isEnabled: Bool {
    get { defaults.bool(forKey: enabledKey) }
    set { defaults.set(newValue, forKey: enabledKey) }
  }

  /// The last CLOSED civil day whose cumulative totals were uploaded.
  static var dailyTotalsThrough: String? {
    get { defaults.string(forKey: dailyWatermarkKey) }
    set { defaults.set(newValue, forKey: dailyWatermarkKey) }
  }

  static func anchor(for typeIdentifier: String) -> HKQueryAnchor? {
    guard let data = defaults.data(forKey: anchorKeyPrefix + typeIdentifier) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
  }

  static func hasAnchor(for typeIdentifier: String) -> Bool {
    defaults.data(forKey: anchorKeyPrefix + typeIdentifier) != nil
  }

  static func setAnchor(_ anchor: HKQueryAnchor, for typeIdentifier: String) {
    guard let data = try? NSKeyedArchiver.archivedData(
      withRootObject: anchor, requiringSecureCoding: true
    ) else { return }
    defaults.set(data, forKey: anchorKeyPrefix + typeIdentifier)
  }

  /// Where undelivered batches wait. Oldest first, dropped after a week.
  static var pendingDirectory: URL? {
    let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    guard let base else { return nil }
    let dir = base.appendingPathComponent("hcc-healthkit-pending", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static let maximumPendingAge: TimeInterval = 7 * 24 * 3600
}

/// One batch waiting to be delivered, with the anchors it would advance.
///
/// The anchors travel WITH the payload rather than being written when the sweep
/// ran: that is what makes "acknowledged, then advance" true even if the app is
/// killed between building a batch and delivering it.
struct HCCHealthKitPendingBatch: Codable {
  let id: String
  let createdAt: Date
  /// `typeIdentifier` → archived `HKQueryAnchor`, committed only on a 2xx.
  var anchors: [String: Data]
  /// The civil day the cumulative totals in this batch run through.
  var dailyTotalsThrough: String?
  let batch: HCCHealthKitBatch
}

// ── Uploader ─────────────────────────────────────────────────────────────────

@MainActor
final class HCCHealthKitUploader: ObservableObject {
  static let shared = HCCHealthKitUploader()

  nonisolated static let backgroundTaskIdentifier = "com.gatbontontech.openvitals-hcc.hcc.healthkit-upload"
  nonisolated static let backgroundSessionIdentifier = "com.gatbontontech.openvitals-hcc.hcc.upload"

  @Published private(set) var state = HCCHealthKitUploadState()

  private let healthStore = HKHealthStore()
  private var observerQueries: [HKObserverQuery] = []
  private var didRegisterBackgroundTask = false
  private var isSweeping = false

  private init() {
    state.enabled = HCCHealthKitStore.isEnabled
    refreshDerivedState()
  }

  // ── Types ──────────────────────────────────────────────────────────────────

  /// The read set.
  ///
  /// `.heartRate` is here for one reason: a workout is uploaded with the heart-
  /// rate samples inside its window so the server can bin zones. Without it the
  /// workout arrives with no strain at all.
  static var readTypes: Set<HKObjectType> {
    var types = Set<HKObjectType>()
    for metric in HCCHealthKitMetric.allCases {
      if let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: metric.typeIdentifier)) {
        types.insert(type)
      }
    }
    if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
    types.insert(HKObjectType.workoutType())
    return types
  }

  /// The types an observer watches. Cumulative totals are swept on a schedule
  /// instead — every step would otherwise wake the app.
  private static var observedTypes: [HKSampleType] {
    var types: [HKSampleType] = []
    for metric in HCCHealthKitMetric.anchored {
      if let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: metric.typeIdentifier)) {
        types.append(type)
      }
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
    types.append(HKObjectType.workoutType())
    return types
  }

  // ── Entry points ───────────────────────────────────────────────────────────

  /// Called once from app launch. Does nothing unless the user turned this on.
  func startIfEnabled() {
    registerBackgroundTaskIfNeeded()
    refreshDerivedState()
    Task { await refreshAuthorizationStatus() }
    guard state.enabled, HKHealthStore.isHealthDataAvailable() else { return }
    startObservers()
    scheduleBackgroundSweep()
    Task { await syncNow() }
  }

  /// The toggle on the sheet.
  func setEnabled(_ enabled: Bool) async {
    HCCHealthKitStore.isEnabled = enabled
    state.enabled = enabled
    state.lastError = nil
    guard enabled else {
      stopObservers()
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
      refreshDerivedState()
      return
    }
    await requestAuthorization()
    startObservers()
    scheduleBackgroundSweep()
    await syncNow()
  }

  /// "Sync now" — read everything new and deliver it, reporting the outcome.
  func syncNow() async {
    guard !isSweeping else { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      state.authorization = .unavailable
      return
    }
    isSweeping = true
    state.isWorking = true
    state.lastError = nil
    defer {
      isSweeping = false
      state.isWorking = false
      refreshDerivedState()
    }

    await flushPending()

    do {
      let sweep = try await collect()
      guard !sweep.batches.isEmpty else {
        state.lastResult = HCCHealthKitUploadOutcome(
          at: Date(), batches: 0, written: 0, skipped: 0, activities: 0
        )
        state.lastUploadAt = Date()
        return
      }
      var written = 0
      var skipped = 0
      var activities = 0
      var delivered = 0
      loop: for pending in sweep.batches {
        write(pending)
        switch await deliver(pending) {
        case let .delivered(result):
          written += result.writtenCount
          skipped += result.skippedCount
          activities += result.activityCount
          delivered += 1
        case .queued, .failed:
          break loop
        }
      }
      if delivered > 0 {
        state.lastUploadAt = Date()
        state.lastResult = HCCHealthKitUploadOutcome(
          at: Date(), batches: delivered, written: written, skipped: skipped, activities: activities
        )
      }
    } catch {
      state.lastError = error.localizedDescription
    }
  }

  // ── Authorization ──────────────────────────────────────────────────────────

  /// Re-read what Health reports, without prompting. The sheet calls this when
  /// it appears, so a permission changed in Settings shows up on the next visit.
  func refreshAuthorization() async {
    refreshDerivedState()
    await refreshAuthorizationStatus()
  }

  func requestAuthorization() async {
    guard HKHealthStore.isHealthDataAvailable() else {
      state.authorization = .unavailable
      return
    }
    do {
      var share = Set<HKSampleType>()
      #if DEBUG
      // DEBUG only: the simulator has no Watch, so verification needs to be able
      // to write the fixture it then reads back. Never requested in Release.
      if Self.debugSeedRequested { share = Self.debugSeedTypes }
      #endif
      try await healthStore.requestAuthorization(toShare: share, read: Self.readTypes)
    } catch {
      state.lastError = error.localizedDescription
    }
    refreshDerivedState()
    await refreshAuthorizationStatus()
  }

  /// Asked of HealthKit, never blocked on: the completion arrives on HealthKit's
  /// own queue and an earlier semaphore here deadlocked the main actor, which
  /// showed on the sheet as a permanent "Unknown".
  private func refreshAuthorizationStatus() async {
    guard HKHealthStore.isHealthDataAvailable() else {
      state.authorization = .unavailable
      return
    }
    let status: HKAuthorizationRequestStatus = await withCheckedContinuation { continuation in
      healthStore.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { status, _ in
        continuation.resume(returning: status)
      }
    }
    switch status {
    case .shouldRequest: state.authorization = .notRequested
    case .unnecessary: state.authorization = .requested
    default: state.authorization = .unknown
    }
  }

  // ── Observers and background sweeps ────────────────────────────────────────

  private func startObservers() {
    guard observerQueries.isEmpty else { return }
    var notes: [String] = []
    for type in Self.observedTypes {
      let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
        Task { @MainActor in
          await self?.syncNow()
          completion()
        }
      }
      healthStore.execute(query)
      observerQueries.append(query)

      healthStore.enableBackgroundDelivery(for: type, frequency: .hourly) { success, error in
        guard !success, let error else { return }
        Task { @MainActor [weak self] in
          guard let self, self.state.backgroundNote == nil else { return }
          self.state.backgroundNote =
            "Background delivery is off (\(error.localizedDescription)). Uploads run while the app is open."
        }
      }
    }
    if !HCCHealthKitStore.usesAppGroup {
      notes.append("App Group unavailable; cursors are stored in the app's own container.")
    }
    if let note = notes.first, state.backgroundNote == nil { state.backgroundNote = note }
  }

  private func stopObservers() {
    for query in observerQueries { healthStore.stop(query) }
    observerQueries.removeAll()
    healthStore.disableAllBackgroundDelivery { _, _ in }
  }

  private func registerBackgroundTaskIfNeeded() {
    guard !didRegisterBackgroundTask else { return }
    didRegisterBackgroundTask = true
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil
    ) { task in
      Task { @MainActor in
        let uploader = HCCHealthKitUploader.shared
        uploader.scheduleBackgroundSweep()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        await uploader.syncNow()
        task.setTaskCompleted(success: uploader.state.lastError == nil)
      }
    }
  }

  private func scheduleBackgroundSweep() {
    let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Unavailable in the simulator and whenever the app has no background
      // budget. Said out loud rather than swallowed.
      if state.backgroundNote == nil {
        state.backgroundNote =
          "Daily background sweep unavailable (\(error.localizedDescription)). Uploads run while the app is open."
      }
    }
  }

  // ── Collection ─────────────────────────────────────────────────────────────

  private struct Sweep {
    var batches: [HCCHealthKitPendingBatch]
  }

  private func collect() async throws -> Sweep {
    var samples: [HCCHealthKitSample] = []
    var anchors: [String: Data] = [:]
    var deviceModel: String?

    for metric in HCCHealthKitMetric.anchored {
      guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: metric.typeIdentifier))
      else { continue }
      let page = try await anchoredQuantitySamples(type: type)
      for sample in page.samples where isWatchSourced(sample) {
        deviceModel = deviceModel ?? Self.deviceModel(for: sample)
        let unit = HKUnit(from: metric.hkUnit)
        samples.append(
          HCCHealthKitSample(
            name: metric.wireName,
            value: sample.quantity.doubleValue(for: unit) * metric.scale,
            unit: metric.wireUnit,
            date: HCCTime.isoInstant(sample.endDate)
          )
        )
      }
      if let anchor = page.anchor, let data = Self.archive(anchor) {
        anchors[metric.typeIdentifier] = data
      }
    }

    // Cumulative streams: one total per closed civil day (see `isDailyTotal`).
    let dailyTotals = try await dailyTotalSamples()
    samples.append(contentsOf: dailyTotals.samples)

    // Sleep.
    var sleepSegments: [HCCHealthKitSleepSegment] = []
    if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      let page = try await anchoredCategorySamples(type: sleepType)
      for sample in page.samples where isWatchSourced(sample) {
        guard let stage = HCCHealthKitSleepStage.wireName(forCategoryValue: sample.value) else { continue }
        deviceModel = deviceModel ?? Self.deviceModel(for: sample)
        sleepSegments.append(
          HCCHealthKitSleepSegment(
            start: HCCTime.isoInstant(sample.startDate),
            end: HCCTime.isoInstant(sample.endDate),
            stage: stage
          )
        )
      }
      if let anchor = page.anchor, let data = Self.archive(anchor) {
        anchors[sleepType.identifier] = data
      }
    }

    // Workouts, each with the heart-rate samples inside its window.
    var workouts: [HCCHealthKitWorkout] = []
    let workoutPage = try await anchoredWorkouts()
    for workout in workoutPage.samples where isWatchSourced(workout) {
      deviceModel = deviceModel ?? Self.deviceModel(for: workout)
      workouts.append(try await wireWorkout(workout))
    }
    if let anchor = workoutPage.anchor, let data = Self.archive(anchor) {
      anchors[HKObjectType.workoutType().identifier] = data
    }

    let id = UUID().uuidString
    let built = HCCHealthKitBatchBuilder.batches(
      samples: samples, workouts: workouts, sleep: sleepSegments,
      deviceModel: deviceModel, id: id
    )
    guard !built.isEmpty else {
      // Nothing new — but the anchors still moved past what was read, and the
      // watermark still advanced, so commit them now rather than re-reading the
      // same empty page forever.
      commit(anchors: anchors, dailyTotalsThrough: dailyTotals.through)
      return Sweep(batches: [])
    }

    // Only the LAST batch of a sweep carries the anchors: the earlier ones are
    // slices of the same read, and advancing on the first would strand the rest.
    var pending: [HCCHealthKitPendingBatch] = []
    for (index, batch) in built.enumerated() {
      let isLast = index == built.count - 1
      pending.append(
        HCCHealthKitPendingBatch(
          id: batch.anchor ?? id,
          createdAt: Date(),
          anchors: isLast ? anchors : [:],
          dailyTotalsThrough: isLast ? dailyTotals.through : nil,
          batch: batch
        )
      )
    }
    return Sweep(batches: pending)
  }

  // ── HealthKit queries ──────────────────────────────────────────────────────

  private struct Page<Sample> {
    let samples: [Sample]
    let anchor: HKQueryAnchor?
  }

  /// A type read for the first time is bounded to the last 30 days, so the first
  /// batch after switching this on is a bounded one rather than years of history.
  private func firstRunPredicate(for typeIdentifier: String) -> NSPredicate? {
    guard !HCCHealthKitStore.hasAnchor(for: typeIdentifier) else { return nil }
    return HKQuery.predicateForSamples(
      withStart: Date(timeIntervalSinceNow: -30 * 24 * 3600), end: nil, options: []
    )
  }

  private func anchoredQuantitySamples(type: HKQuantityType) async throws -> Page<HKQuantitySample> {
    let page = try await anchoredSamples(type: type)
    return Page(samples: page.samples.compactMap { $0 as? HKQuantitySample }, anchor: page.anchor)
  }

  private func anchoredCategorySamples(type: HKCategoryType) async throws -> Page<HKCategorySample> {
    let page = try await anchoredSamples(type: type)
    return Page(samples: page.samples.compactMap { $0 as? HKCategorySample }, anchor: page.anchor)
  }

  private func anchoredWorkouts() async throws -> Page<HKWorkout> {
    let page = try await anchoredSamples(type: HKObjectType.workoutType())
    return Page(samples: page.samples.compactMap { $0 as? HKWorkout }, anchor: page.anchor)
  }

  private func anchoredSamples(type: HKSampleType) async throws -> Page<HKSample> {
    let identifier = type.identifier
    let anchor = HCCHealthKitStore.anchor(for: identifier)
    let predicate = firstRunPredicate(for: identifier)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKAnchoredObjectQuery(
        type: type,
        predicate: predicate,
        anchor: anchor,
        limit: HKObjectQueryNoLimit
      ) { _, samples, _, newAnchor, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: Page(samples: samples ?? [], anchor: newAnchor))
        }
      }
      healthStore.execute(query)
    }
  }

  /// Heart-rate samples inside a workout window, Watch-sourced, ascending.
  private func heartRateSamples(for workout: HKWorkout) async throws -> [HCCHealthKitHRSample] {
    guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
    let predicate = HKQuery.predicateForSamples(
      withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate]
    )
    let unit = HKUnit.count().unitDivided(by: .minute())
    let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
      let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
      let query = HKSampleQuery(
        sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
        }
      }
      healthStore.execute(query)
    }
    return samples.filter(isWatchSourced).map {
      HCCHealthKitHRSample(
        t: HCCTime.isoInstant($0.startDate),
        bpm: $0.quantity.doubleValue(for: unit)
      )
    }
  }

  private func wireWorkout(_ workout: HKWorkout) async throws -> HCCHealthKitWorkout {
    let bpm = HKUnit.count().unitDivided(by: .minute())
    let hrType = HKQuantityType(.heartRate)
    let stats = workout.statistics(for: hrType)
    let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
      .sumQuantity()?.doubleValue(for: .kilocalorie())
    let distance = [HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling)]
      .compactMap { workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
      .first
    return HCCHealthKitWorkout(
      uuid: workout.uuid.uuidString,
      start: HCCTime.isoInstant(workout.startDate),
      end: HCCTime.isoInstant(workout.endDate),
      type: HCCHealthKitWorkoutType.name(forActivityTypeRawValue: workout.workoutActivityType.rawValue),
      avgHr: stats?.averageQuantity()?.doubleValue(for: bpm),
      maxHr: stats?.maximumQuantity()?.doubleValue(for: bpm),
      kcal: energy,
      distanceM: distance,
      hrSamples: try await heartRateSamples(for: workout).nilIfEmpty
    )
  }

  /// Cumulative streams as one total per CLOSED civil day in the INSTANCE's
  /// time zone — the same civil day the server buckets by, so a total never
  /// straddles two of its days.
  private func dailyTotalSamples() async throws -> (samples: [HCCHealthKitSample], through: String?) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = HCCInstanceZone.current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"

    let todayStart = calendar.startOfDay(for: Date())
    let floor = calendar.date(byAdding: .day, value: -30, to: todayStart) ?? todayStart
    var start = floor
    if let watermark = HCCHealthKitStore.dailyTotalsThrough,
       let day = formatter.date(from: watermark),
       let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) {
      start = max(floor, next)
    }
    guard start < todayStart else { return ([], HCCHealthKitStore.dailyTotalsThrough) }

    var out: [HCCHealthKitSample] = []
    var through: String?
    for metric in HCCHealthKitMetric.dailyTotals {
      guard let type = HKObjectType.quantityType(forIdentifier: .init(rawValue: metric.typeIdentifier))
      else { continue }
      let totals = try await dailySums(type: type, from: start, to: todayStart, calendar: calendar)
      let unit = HKUnit(from: metric.hkUnit)
      for (dayStart, quantity) in totals {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
        let value = quantity.doubleValue(for: unit) * metric.scale
        guard value > 0 else { continue }
        out.append(
          HCCHealthKitSample(
            name: metric.wireName,
            value: value,
            unit: metric.wireUnit,
            // Stamped at the last instant of its own civil day: a stable key the
            // server can dedupe on, and one that cannot land on the next day.
            date: HCCTime.isoInstant(dayEnd.addingTimeInterval(-1))
          )
        )
      }
    }
    if let lastClosed = calendar.date(byAdding: .day, value: -1, to: todayStart) {
      through = formatter.string(from: lastClosed)
    }
    return (out, through)
  }

  private func dailySums(
    type: HKQuantityType, from start: Date, to end: Date, calendar: Calendar
  ) async throws -> [(Date, HKQuantity)] {
    var predicates: [NSPredicate] = [
      HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
    ]
    // A statistics query cannot filter in code, so the Watch filter is expressed
    // as a device-model predicate. HealthKit records an Apple Watch's model as
    // literally "Watch"; nothing Google Health or a manual entry writes carries
    // that, which is the distinction that matters here.
    if !Self.anySourceAllowed {
      predicates.append(
        HKQuery.predicateForObjects(
          withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: ["Watch"]
        )
      )
    }
    let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKStatisticsCollectionQuery(
        quantityType: type,
        quantitySamplePredicate: predicate,
        options: .cumulativeSum,
        anchorDate: start,
        intervalComponents: DateComponents(day: 1)
      )
      query.initialResultsHandler = { _, collection, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        var out: [(Date, HKQuantity)] = []
        collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
          if let sum = statistics.sumQuantity() {
            out.append((calendar.startOfDay(for: statistics.startDate), sum))
          }
        }
        continuation.resume(returning: out)
      }
      healthStore.execute(query)
    }
  }

  // ── Source filter ──────────────────────────────────────────────────────────

  /// Keep only what an Apple Watch recorded through Apple's own health daemon.
  ///
  /// Both halves matter. The bundle-id prefix drops apps that write into Health
  /// under their own identity (Google Health mirroring a Fitbit, a third-party
  /// tracker). The device check drops the phone's own readings and anything
  /// typed in by hand, which carry no Watch device.
  private func isWatchSourced(_ object: HKObject) -> Bool {
    if Self.anySourceAllowed { return true }
    let revision = object.sourceRevision
    guard revision.source.bundleIdentifier.hasPrefix("com.apple.health") else { return false }
    let model = object.device?.model ?? ""
    let name = object.device?.name ?? ""
    let product = revision.productType ?? ""
    return model.localizedCaseInsensitiveContains("watch")
      || name.localizedCaseInsensitiveContains("watch")
      || product.localizedCaseInsensitiveContains("watch")
  }

  /// What to tell the server produced these readings. Read off the sample's own
  /// device — never assumed, because the server turns a model containing "watch"
  /// into `sourceDetail: "Apple Watch"` and a wrong guess mislabels the row.
  private static func deviceModel(for object: HKObject) -> String? {
    if let name = object.device?.name, name.localizedCaseInsensitiveContains("watch") { return name }
    if let model = object.device?.model, model.localizedCaseInsensitiveContains("watch") {
      return model == "Watch" ? "Apple Watch" : model
    }
    if let product = object.sourceRevision.productType,
       product.localizedCaseInsensitiveContains("watch") {
      return "Apple Watch (\(product))"
    }
    return nil
  }

  private static var anySourceAllowed: Bool {
    #if DEBUG
    return ProcessInfo.processInfo.environment["HCC_DEBUG_HK_ANY_SOURCE"] == "1"
    #else
    return false
    #endif
  }

  // ── Delivery ───────────────────────────────────────────────────────────────

  private var ingestToken: String? {
    #if DEBUG
    if let injected = ProcessInfo.processInfo.environment["HCC_DEBUG_INGEST_TOKEN"], !injected.isEmpty {
      return injected
    }
    #endif
    return HCCSession.ingestToken()
  }

  /// The outcome of one attempted delivery. "Handed to the background session"
  /// is deliberately its own case: it is neither a success to report counts for
  /// nor a failure to show the user an error about.
  private enum Delivery {
    case delivered(HCCHealthKitIngestResult)
    case queued
    case failed
  }

  /// Two files per batch: the wrapper (anchors + metadata, read on retry) and
  /// the request body on its own. A background upload task can only send a
  /// FILE, and the body it sends must be exactly what the server parses — so the
  /// body cannot be a field inside the wrapper.
  private func write(_ pending: HCCHealthKitPendingBatch) {
    guard let dir = HCCHealthKitStore.pendingDirectory else { return }
    let stem = "\(Int(pending.createdAt.timeIntervalSince1970))-\(pending.id)"
    if let data = try? JSONEncoder().encode(pending) {
      try? data.write(to: dir.appendingPathComponent("\(stem).json"), options: .atomic)
    }
    if let body = try? HCCHealthKitBatchBuilder.encode(pending.batch) {
      try? body.write(to: dir.appendingPathComponent("\(stem).body"), options: .atomic)
    }
  }

  fileprivate nonisolated static func bodyURL(for id: String) -> URL? {
    guard let dir = HCCHealthKitStore.pendingDirectory,
          let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return nil }
    return names.first { $0.hasSuffix("\(id).body") }.map { dir.appendingPathComponent($0) }
  }

  fileprivate nonisolated static func remove(id: String) {
    guard let dir = HCCHealthKitStore.pendingDirectory,
          let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    else { return }
    for name in names where name.hasSuffix("\(id).json") || name.hasSuffix("\(id).body") {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
  }

  private func remove(_ pending: HCCHealthKitPendingBatch) { Self.remove(id: pending.id) }

  nonisolated static func ingestURL() -> URL {
    HCCSession.storedBaseURL().appendingPathComponent("api/ingest/apple-health")
  }

  /// POST one batch.
  ///
  /// While the app is in front the request is awaited so the sheet can print the
  /// server's own counts. When the sweep was woken by an observer or the daily
  /// background task, the batch is handed to a background `URLSession` instead,
  /// which keeps uploading after the process is suspended; its delegate advances
  /// the anchors when the server acknowledges it.
  private func deliver(_ pending: HCCHealthKitPendingBatch) async -> Delivery {
    guard let token = ingestToken else {
      state.lastError = "No ingest token for this instance yet. Sign in again to get one."
      return .failed
    }
    guard UIApplication.shared.applicationState == .active else {
      HCCHealthKitBackgroundDelivery.shared.enqueue(id: pending.id, token: token)
      return .queued
    }
    var request = URLRequest(url: Self.ingestURL())
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    do {
      request.httpBody = try HCCHealthKitBatchBuilder.encode(pending.batch)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        state.lastError = "The upload got no response."
        return .failed
      }
      guard (200..<300).contains(http.statusCode) else {
        state.lastError = http.statusCode == 401
          ? "The ingest token was rejected. Sign in again to get a new one."
          : "Upload failed (\(http.statusCode))."
        return .failed
      }
      let result = try JSONDecoder().decode(HCCHealthKitIngestResult.self, from: data)
      commit(anchors: pending.anchors, dailyTotalsThrough: pending.dailyTotalsThrough)
      remove(pending)
      return .delivered(result)
    } catch {
      state.lastError = error.localizedDescription
      return .failed
    }
  }

  /// Retry what is on disk, oldest first, dropping anything past a week old.
  private func flushPending() async {
    for pending in Self.pendingOnDisk() {
      guard Date().timeIntervalSince(pending.createdAt) < HCCHealthKitStore.maximumPendingAge else {
        remove(pending)
        continue
      }
      if case .failed = await deliver(pending) { return }
    }
  }

  fileprivate static func pendingOnDisk() -> [HCCHealthKitPendingBatch] {
    guard let dir = HCCHealthKitStore.pendingDirectory,
          let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
          )
    else { return [] }
    let decoder = JSONDecoder()
    return urls
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(HCCHealthKitPendingBatch.self, from: data)
      }
  }

  fileprivate func commitAcknowledged(id: String) {
    guard let pending = Self.pendingOnDisk().first(where: { $0.id == id }) else { return }
    commit(anchors: pending.anchors, dailyTotalsThrough: pending.dailyTotalsThrough)
    Self.remove(id: id)
    state.lastUploadAt = Date()
    refreshDerivedState()
  }

  private func commit(anchors: [String: Data], dailyTotalsThrough: String?) {
    for (identifier, data) in anchors {
      guard let anchor = try? NSKeyedUnarchiver.unarchivedObject(
        ofClass: HKQueryAnchor.self, from: data
      ) else { continue }
      HCCHealthKitStore.setAnchor(anchor, for: identifier)
    }
    if let dailyTotalsThrough { HCCHealthKitStore.dailyTotalsThrough = dailyTotalsThrough }
  }

  private static func archive(_ anchor: HKQueryAnchor) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
  }

  // ── Derived state ──────────────────────────────────────────────────────────

  private func refreshDerivedState() {
    state.enabled = HCCHealthKitStore.isEnabled
    state.pendingBatches = Self.pendingOnDisk().count
    var streams: [HCCHealthKitStreamStatus] = HCCHealthKitMetric.anchored.map {
      HCCHealthKitStreamStatus(
        label: Self.label(for: $0),
        hasAnchor: HCCHealthKitStore.hasAnchor(for: $0.typeIdentifier)
      )
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      streams.append(
        HCCHealthKitStreamStatus(label: "Sleep", hasAnchor: HCCHealthKitStore.hasAnchor(for: sleep.identifier))
      )
    }
    streams.append(
      HCCHealthKitStreamStatus(
        label: "Workouts",
        hasAnchor: HCCHealthKitStore.hasAnchor(for: HKObjectType.workoutType().identifier)
      )
    )
    for metric in HCCHealthKitMetric.dailyTotals {
      streams.append(
        HCCHealthKitStreamStatus(
          label: Self.label(for: metric),
          hasAnchor: HCCHealthKitStore.dailyTotalsThrough != nil
        )
      )
    }
    state.streams = streams
  }

  private static func label(for metric: HCCHealthKitMetric) -> String {
    switch metric {
    case .hrv: "HRV"
    case .restingHeartRate: "Resting heart rate"
    case .respiratoryRate: "Respiratory rate"
    case .oxygenSaturation: "Blood oxygen"
    case .wristTemperature: "Wrist temperature"
    case .vo2Max: "VO2 max"
    case .activeEnergy: "Active energy"
    case .steps: "Steps"
    }
  }
}

private extension Array {
  var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

// ── Background delivery ──────────────────────────────────────────────────────

/// Uploads a queued batch through a background `URLSession`, so a sweep that
/// started from an observer or the daily background task finishes even after the
/// process is suspended.
///
/// Anchors are still committed only on a 2xx — here, in `didCompleteWithError`,
/// against the wrapper file the sweep left on disk. A batch whose upload failed
/// keeps both its files and is retried by the next sweep.
///
// HCC: P4-P wired the relaunch path. `HCCAppDelegate` now implements
// `application(_:handleEventsForBackgroundURLSession:)` and hands the system's
// completion handler to `setCompletionHandler(_:)` below; it is called once the
// session says it has delivered every event, which is what lets iOS suspend the
// app again instead of holding it awake.
final class HCCHealthKitBackgroundDelivery: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = HCCHealthKitBackgroundDelivery()

  // HCC: set from the app delegate on a background-session relaunch. Guarded by
  // a lock because `urlSessionDidFinishEvents` arrives on the session's own
  // delegate queue, not the main one.
  private let completionLock = NSLock()
  private var backgroundCompletionHandler: (() -> Void)?

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(
      withIdentifier: HCCHealthKitUploader.backgroundSessionIdentifier
    )
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  private override init() { super.init() }

  func enqueue(id: String, token: String) {
    guard let body = HCCHealthKitUploader.bodyURL(for: id) else { return }
    var request = URLRequest(url: HCCHealthKitUploader.ingestURL())
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let task = session.uploadTask(with: request, fromFile: body)
    task.taskDescription = id
    task.resume()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = task.taskDescription else { return }
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    guard error == nil, (200..<300).contains(status) else { return }
    Task { @MainActor in HCCHealthKitUploader.shared.commitAcknowledged(id: id) }
  }

  // HCC: P4-P — the relaunch seam.

  /// Hold the system's completion handler until the session has finished
  /// replaying its events. Touching the session here is deliberate: the lazy
  /// `URLSession` must exist for `urlSessionDidFinishEvents` to ever fire.
  func setCompletionHandler(_ handler: @escaping () -> Void) {
    completionLock.lock()
    backgroundCompletionHandler = handler
    completionLock.unlock()
    _ = session
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    completionLock.lock()
    let handler = backgroundCompletionHandler
    backgroundCompletionHandler = nil
    completionLock.unlock()
    // UIKit requires this on the main thread.
    DispatchQueue.main.async { handler?() }
  }
}

// ── DEBUG seeding ────────────────────────────────────────────────────────────

#if DEBUG
extension HCCHealthKitUploader {
  static var debugSeedRequested: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_HK_SEED"] == "1"
  }

  /// The types the seed writes. Requested for SHARING only under the seed hook.
  static var debugSeedTypes: Set<HKSampleType> {
    var types = Set<HKSampleType>()
    for identifier in [HKQuantityTypeIdentifier.heartRateVariabilitySDNN, .restingHeartRate, .heartRate] {
      if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
    types.insert(HKObjectType.workoutType())
    return types
  }

  /// A simulator has no Apple Watch, so verification needs samples that look
  /// like one wrote them. The device below is the shape HealthKit records for a
  /// real Watch (`model == "Watch"`), so the production source filter is
  /// exercised on its device half; the bundle-id half still needs
  /// `HCC_DEBUG_HK_ANY_SOURCE=1`, because these are written by this app.
  private static var debugDevice: HKDevice {
    HKDevice(
      name: "Apple Watch",
      manufacturer: "Apple Inc.",
      model: "Watch",
      hardwareVersion: "Watch7,1",
      firmwareVersion: nil,
      softwareVersion: "26.0",
      localIdentifier: nil,
      udiDeviceIdentifier: nil
    )
  }

  /// 3 HRV + 2 resting HR + one workout with heart-rate samples + one night.
  func debugSeedIfRequested() async {
    guard Self.debugSeedRequested, HKHealthStore.isHealthDataAvailable() else { return }
    let device = Self.debugDevice
    let now = Date()
    var objects: [HKSample] = []

    if let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
      for (index, ms) in [58.0, 64.0, 71.0].enumerated() {
        let at = now.addingTimeInterval(-Double(index + 1) * 3600)
        objects.append(
          HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: HKUnit(from: "ms"), doubleValue: ms),
            start: at, end: at, device: device, metadata: nil
          )
        )
      }
    }
    let bpm = HKUnit.count().unitDivided(by: .minute())
    if let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) {
      for (index, value) in [52.0, 49.0].enumerated() {
        let at = now.addingTimeInterval(-Double(index + 1) * 7200)
        objects.append(
          HKQuantitySample(
            type: type, quantity: HKQuantity(unit: bpm, doubleValue: value),
            start: at, end: at, device: device, metadata: nil
          )
        )
      }
    }
    if let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      let wake = now.addingTimeInterval(-3 * 3600)
      let stages: [(Int, TimeInterval)] = [(3, 7200), (4, 3600), (5, 5400), (3, 5400)]
      var cursor = wake.addingTimeInterval(-(stages.reduce(0) { $0 + $1.1 }))
      for (value, seconds) in stages {
        let end = cursor.addingTimeInterval(seconds)
        objects.append(
          HKCategorySample(type: type, value: value, start: cursor, end: end, device: device, metadata: nil)
        )
        cursor = end
      }
    }
    do {
      if !objects.isEmpty { try await healthStore.save(objects) }
      try await debugSeedWorkout(device: device, bpm: bpm, now: now)
    } catch {
      state.lastError = "Seed failed: \(error.localizedDescription)"
      return
    }
    print("[HCC][hk] seeded \(objects.count) samples + 1 workout into HealthKit")
  }

  private func debugSeedWorkout(device: HKDevice, bpm: HKUnit, now: Date) async throws {
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = .running
    let start = now.addingTimeInterval(-5400)
    let end = now.addingTimeInterval(-3600)
    let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: device)
    try await builder.beginCollection(at: start)
    if let type = HKObjectType.quantityType(forIdentifier: .heartRate) {
      let samples = (0..<30).map { index -> HKQuantitySample in
        let at = start.addingTimeInterval(Double(index) * 60)
        return HKQuantitySample(
          type: type,
          quantity: HKQuantity(unit: bpm, doubleValue: 118 + Double(index % 12) * 5),
          start: at, end: at.addingTimeInterval(30), device: device, metadata: nil
        )
      }
      try await builder.addSamples(samples)
    }
    try await builder.endCollection(at: end)
    _ = try await builder.finishWorkout()
  }

  /// Push the fixture batch through the REAL delivery path — pending file, the
  /// ingest-token accessor, the POST, the response decode, the state update.
  ///
  /// This exists because the iOS Simulator's Health authorization sheet is a
  /// system alert that cannot be dismissed from `simctl`, so a machine-driven
  /// run cannot get past the read prompt. Everything downstream of HealthKit is
  /// still exercised end to end against a real server; only the HealthKit read
  /// and the Watch source filter are skipped, and the fixture is labelled as a
  /// fixture (`anchor: "fixture"`) so a row it creates is recognisable.
  func debugUploadFixtureIfRequested() async {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_HK_FIXTURE_UPLOAD"] == "1" else { return }
    // The hook stands in for a "Sync now" tap, so wait for the app to actually
    // be in front: at launch the scene is still inactive, and `deliver` would
    // hand the batch to the background session instead of the path a user takes.
    for _ in 0..<25 where UIApplication.shared.applicationState != .active {
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    let pending = HCCHealthKitPendingBatch(
      id: "fixture-\(Int(Date().timeIntervalSince1970))",
      createdAt: Date(),
      anchors: [:],
      dailyTotalsThrough: nil,
      batch: HCCHealthKitBatchSelfCheck.fixture()
    )
    state.isWorking = true
    write(pending)
    refreshDerivedState()
    switch await deliver(pending) {
    case let .delivered(result):
      state.lastUploadAt = Date()
      state.lastResult = HCCHealthKitUploadOutcome(
        at: Date(), batches: 1, written: result.writtenCount,
        skipped: result.skippedCount, activities: result.activityCount
      )
      print("[HCC][hk] fixture upload: written=\(result.writtenCount) skipped=\(result.skippedCount) activities=\(result.activityCount)")
    case .queued:
      print("[HCC][hk] fixture upload handed to the background session")
    case .failed:
      print("[HCC][hk] fixture upload failed: \(state.lastError ?? "unknown")")
    }
    state.isWorking = false
    refreshDerivedState()
  }

  /// `HCC_DEBUG_HK_SEED=1` / `HCC_DEBUG_HK_SYNC=1`, run once at launch.
  func debugRunLaunchHooksIfRequested() async {
    HCCHealthKitBatchSelfCheck.runIfRequested()
    await debugUploadFixtureIfRequested()
    guard Self.debugSeedRequested
      || ProcessInfo.processInfo.environment["HCC_DEBUG_HK_SYNC"] == "1" else { return }
    await requestAuthorization()
    await debugSeedIfRequested()
    await syncNow()
  }
}
#endif
