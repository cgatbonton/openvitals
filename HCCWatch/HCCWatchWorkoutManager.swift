import Foundation
import HealthKit
import WatchKit

// HCC: the watch half of the mirrored workout (plan §4.7a).
//
// The phone cannot start an `HKWorkoutSession`; only the watch can. So the
// division of labour is fixed by the OS, not by taste: this file owns the
// session and the sensor, and the phone owns every screen. When the session
// starts it calls `startMirroringToCompanionDevice`, which launches the iPhone
// app in the background and hands it the same session through
// `HKHealthStore.workoutSessionMirroringStartHandler` — the seam
// `HCCWatchMirrorSource` on the phone already installs at launch.
//
// The wire format is stated by `OpenVitals/HCC/Live/HCCWatchMirrorSource.swift`
// and met here. Three flat, `t`-discriminated JSON objects:
//
//   {"t":"hr","bpm":142,"at":1756900000.5}   a reading and its unix time
//   {"t":"kcal","value":213.4}               cumulative active kcal
//   {"t":"batt","level":0.62}                watch battery, 0–1
//
// There is deliberately no shared framework between the two targets: one struct
// in two files is cheaper than a third target, and the phone's decoder ignores
// anything it does not recognise, so the two halves can be shipped apart.
//
// This target is thin on purpose. It draws a heart rate, a clock and two
// buttons. It never talks to the HCC server, holds no token, and stores no
// health value of its own — everything it measures leaves over the mirrored
// session and is written by the phone.

/// The watch's workout session, its live builder, and the send side of the
/// mirror link.
///
/// Not `@MainActor`: HealthKit calls both delegates on an anonymous background
/// queue, so the delegate methods are `nonisolated` and hop to the main actor
/// to publish. `@unchecked Sendable` for the same reason and on the same terms
/// as `HCCWatchMirrorSource` on the phone — every mutable field is touched only
/// from the main actor or from inside one of those hops.
final class HCCWatchWorkoutManager: NSObject, ObservableObject, @unchecked Sendable {
  static let shared = HCCWatchWorkoutManager()

  /// True between "Start" and the session actually ending.
  @Published private(set) var isActive = false
  /// The most recent heart rate the sensor reported, or nil when none has
  /// arrived yet. Never a held-over value from a previous session.
  @Published private(set) var bpm: Int?
  @Published private(set) var elapsed: TimeInterval = 0
  /// What the session is doing, in words. Never a number.
  @Published private(set) var status: String = "Ready."

  private let healthStore = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private var startedAt: Date?
  private var ticker: Timer?
  /// Cumulative active kcal, sent only when it changes.
  private var lastSentKcal: Double?

  // ── Start / stop ───────────────────────────────────────────────────────────

  @MainActor
  func start() async {
    guard !isActive else { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      status = "Health data is not available on this watch."
      return
    }

    status = "Starting…"
    do {
      try await requestAuthorization()

      let configuration = HKWorkoutConfiguration()
      configuration.activityType = .other
      configuration.locationType = .indoor

      let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
      let builder = session.associatedWorkoutBuilder()
      builder.dataSource = HKLiveWorkoutDataSource(
        healthStore: healthStore,
        workoutConfiguration: configuration
      )
      session.delegate = self
      builder.delegate = self
      self.session = session
      self.builder = builder

      let begin = Date()
      session.startActivity(with: begin)
      try await builder.beginCollection(at: begin)

      startedAt = begin
      elapsed = 0
      bpm = nil
      lastSentKcal = nil
      isActive = true
      startTicking()

      // Mirroring is started AFTER collection begins: the phone is launched by
      // this call, and a phone that attaches before the sensor is running would
      // sit on an empty session with nothing to say.
      try await session.startMirroringToCompanionDevice()
      status = "Mirroring to iPhone."
      sendBattery()
    } catch {
      status = "Could not start the workout."
      await tearDown()
    }
  }

  @MainActor
  func stop() async {
    guard let session else { return }
    status = "Ending…"
    session.end()
    // `end()` is asynchronous; the delegate finishes the builder when the
    // session actually reaches `.ended`, so a session that fails to end does
    // not leave a half-written workout behind.
  }

  // ── Authorization ──────────────────────────────────────────────────────────

  private func requestAuthorization() async throws {
    let share: Set<HKSampleType> = [HKObjectType.workoutType()]
    let read: Set<HKObjectType> = [
      HKObjectType.workoutType(),
      HKQuantityType(.heartRate),
      HKQuantityType(.activeEnergyBurned),
    ]
    try await healthStore.requestAuthorization(toShare: share, read: read)
  }

  // ── The clock ──────────────────────────────────────────────────────────────

  @MainActor
  private func startTicking() {
    ticker?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  @MainActor
  private func tick() {
    guard let startedAt else { return }
    elapsed = max(0, Date().timeIntervalSince(startedAt))
  }

  @MainActor
  private func tearDown() async {
    ticker?.invalidate()
    ticker = nil
    session?.delegate = nil
    builder?.delegate = nil
    session = nil
    builder = nil
    startedAt = nil
    isActive = false
    bpm = nil
    elapsed = 0
    lastSentKcal = nil
  }

  // ── The send side ──────────────────────────────────────────────────────────

  /// One message on the wire. The keys are the phone's decoder, verbatim.
  private struct WireMessage: Encodable {
    let t: String
    var bpm: Int?
    var at: Double?
    var value: Double?
    var level: Double?
  }

  private func send(_ message: WireMessage) {
    guard let session, let payload = try? JSONEncoder().encode(message) else { return }
    // Failures are swallowed on purpose: the phone treats a gap as a gap and
    // shows "--", which is the honest reading of a dropped link. Retrying a
    // stale heart rate a second later would be worse than not sending it.
    session.sendToRemoteWorkoutSession(data: payload) { _, _ in }
  }

  /// The watch's own battery, sent over the mirror link while a workout runs.
  /// Outside a workout the same number goes over `WCSession` instead — see
  /// `HCCWatchBattery`.
  func sendBattery() {
    guard let level = HCCWatchBattery.shared.level else { return }
    send(WireMessage(t: "batt", level: level))
  }
}

// ── Session delegate ─────────────────────────────────────────────────────────

extension HCCWatchWorkoutManager: HKWorkoutSessionDelegate {
  nonisolated func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState,
    from fromState: HKWorkoutSessionState,
    date: Date
  ) {
    Task { @MainActor in
      switch toState {
      case .running:
        self.status = "Mirroring to iPhone."
      case .paused:
        self.status = "Paused."
      case .ended, .stopped:
        await self.finishBuilder(at: date)
      default:
        break
      }
    }
  }

  nonisolated func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didFailWithError error: Error
  ) {
    Task { @MainActor in
      self.status = "The workout stopped unexpectedly."
      await self.tearDown()
    }
  }

  @MainActor
  private func finishBuilder(at date: Date) async {
    if let builder {
      try? await builder.endCollection(at: date)
      _ = try? await builder.finishWorkout()
    }
    await tearDown()
    status = "Saved to Health."
  }
}

// ── Live builder delegate ────────────────────────────────────────────────────

extension HCCWatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

  nonisolated func workoutBuilder(
    _ workoutBuilder: HKLiveWorkoutBuilder,
    didCollectDataOf collectedTypes: Set<HKSampleType>
  ) {
    let heartRateType = HKQuantityType(.heartRate)
    let energyType = HKQuantityType(.activeEnergyBurned)

    for type in collectedTypes {
      guard let quantityType = type as? HKQuantityType,
            let statistics = workoutBuilder.statistics(for: quantityType) else { continue }

      if quantityType == heartRateType {
        guard let quantity = statistics.mostRecentQuantity() else { continue }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let reading = Int(quantity.doubleValue(for: unit).rounded())
        guard reading > 0 else { continue }
        let at = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        send(WireMessage(t: "hr", bpm: reading, at: at.timeIntervalSince1970))
        Task { @MainActor in self.bpm = reading }
      } else if quantityType == energyType {
        guard let quantity = statistics.sumQuantity() else { continue }
        let kcal = quantity.doubleValue(for: .kilocalorie())
        // Energy is cumulative and the builder re-reports it often; only a
        // changed total is worth a message against the 100 KB / 10 s budget.
        if let lastSentKcal, abs(kcal - lastSentKcal) < 0.5 { continue }
        lastSentKcal = kcal
        send(WireMessage(t: "kcal", value: kcal))
      }
    }
  }
}
