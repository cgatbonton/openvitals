import Foundation
import HealthKit
import WatchConnectivity

// HCC: live heart rate mirrored from a workout the Apple Watch is recording.
//
// How the mirroring works, and which half is here: the WATCH starts an
// `HKWorkoutSession` and calls `startMirroringToCompanionDeviceWithCompletion`.
// That launches this app in the background and hands it the same session
// through `HKHealthStore.workoutSessionMirroringStartHandler`. The phone then
// becomes that session's delegate and receives whatever the watch sends over
// `sendDataToRemoteWorkoutSession`.
//
// The Watch companion app is a LATER workstream and does not exist yet. So the
// wire format below is a contract this file states and the watch app will meet,
// not one already in use — three JSON messages, `hr`, `kcal` and `batt`, each a
// flat object with a `t` discriminator. Nothing here is exercised on a phone
// with no companion: the handler is installed, no session ever arrives, and the
// setup sheet says the watch source has not connected.
//
// The install call is deliberately NOT made from this file. The handler has to
// be set at launch (a mirrored session can arrive before any screen exists) and
// the app entry point is owned by another workstream this wave; `installHandler()`
// is the seam it calls.

/// The one place the mirrored session is received and routed.
///
/// A singleton because `workoutSessionMirroringStartHandler` is one property on
/// one health store: two owners would mean the second silently replaces the
/// first, and a session that arrives before the live screen opens still has to
/// be caught.
final class HCCWatchMirrorSource: NSObject, HCCLiveHeartRateSource, @unchecked Sendable {
  static let shared = HCCWatchMirrorSource()

  let label = "Apple Watch"

  private let healthStore = HKHealthStore()
  private var session: HKWorkoutSession?
  /// One stream per consumer — see `HCCSampleFanout`.
  private let fanout = HCCSampleFanout()
  private var installed = false

  /// The watch's own battery level (0–1) when it reports one. Read by the state
  /// box; the device pill that would show it belongs to another workstream.
  private(set) var battery: Double?

  var onStatusChanged: (@Sendable (String) -> Void)?
  var onBatteryChanged: (@Sendable (Double) -> Void)?

  var samples: AsyncStream<HCCHeartRateSample> { fanout.stream }

  /// Whether a mirrored session is currently attached.
  var isMirroring: Bool { session != nil }

  // ── Installation ───────────────────────────────────────────────────────────

  /// Set the mirroring handler. Call once, at launch, in cloud mode.
  ///
  /// Idempotent, and a no-op where HealthKit is unavailable. It is separate
  /// from `start()` because a mirrored session can arrive while the app is in
  /// the background with no live screen open — the handler must already be
  /// there to catch it.
  static func installHandler() {
    shared.install()
    // HCC: the watch also reports its battery outside a workout, over WCSession (P4-W).
    HCCWatchConnectivity.activate()
  }

  private func install() {
    guard !installed, HKHealthStore.isHealthDataAvailable() else { return }
    installed = true
    healthStore.workoutSessionMirroringStartHandler = { [weak self] mirrored in
      self?.attach(mirrored)
    }
  }

  private func attach(_ mirrored: HKWorkoutSession) {
    session = mirrored
    mirrored.delegate = self
    // Deliberately NOT calling `associatedWorkoutBuilder` on a mirrored
    // session: the header documents that it throws for a session that was not
    // created with `init(healthStore:configuration:)`, which a mirrored one
    // never is. The watch companion sends the readings explicitly instead, and
    // an untestable exception (there is no watch app yet) is not worth taking
    // for a second path to the same number.
    onStatusChanged?("Following the workout on the watch.")
  }

  // ── The source contract ────────────────────────────────────────────────────

  func start() async throws {
    install()
    guard HKHealthStore.isHealthDataAvailable() else {
      throw HCCLiveSourceError.watchUnavailable
    }
    // Nothing to start: the WATCH starts the session and the handler above
    // catches it. Saying so is the honest state — a spinner here would look
    // like the phone was doing something.
    if session == nil {
      onStatusChanged?(Self.idleReason())
    }
  }

  /// Why no readings are coming, when none are.
  ///
  /// "Waiting for a workout to start on the watch" is only true once the
  /// companion app is actually on the watch. Said unconditionally it sends the
  /// owner off to start a workout that can never reach this phone, so each
  /// step that has to be true is checked and named instead.
  static func idleReason() -> String {
    guard WCSession.isSupported() else {
      return "This iPhone cannot pair with an Apple Watch."
    }
    HCCWatchConnectivity.activate()
    let session = WCSession.default
    guard session.activationState == .activated else {
      return "Connecting to the watch..."
    }
    guard session.isPaired else {
      return "No Apple Watch is paired with this iPhone."
    }
    guard session.isWatchAppInstalled else {
      return "The Command Center watch app is not on your Apple Watch yet, so it cannot send heart rate."
    }
    return "Waiting for a workout to start on the watch."
  }

  func stop() {
    session?.delegate = nil
    session = nil
    battery = nil
  }

  // ── The wire format ────────────────────────────────────────────────────────

  /// One message from the watch. Flat, `t`-discriminated, all values numbers —
  /// the smallest thing that survives `HKWorkoutSession.sendData` without a
  /// shared framework between the two targets.
  ///
  ///   `{"t":"hr","bpm":142,"at":1756900000.5}` — a reading and its unix time
  ///   `{"t":"kcal","value":213.4}`             — cumulative active kcal
  ///   `{"t":"batt","level":0.62}`              — watch battery, 0–1
  struct Message: Decodable {
    let t: String
    let bpm: Int?
    let at: Double?
    let value: Double?
    let level: Double?
  }

  /// Decode and route one payload. Internal rather than private so the message
  /// contract can be exercised without a watch (see `HCCWatchMirrorSelfCheck`).
  func handle(payload: Data) {
    guard let message = try? JSONDecoder().decode(Message.self, from: payload) else { return }
    switch message.t {
    case "hr":
      guard let bpm = message.bpm, bpm > 0 else { return }
      let at = message.at.map { Date(timeIntervalSince1970: $0) } ?? Date()
      fanout.yield(HCCHeartRateSample(at: at, bpm: bpm, activeKcal: pendingKcal))
    case "kcal":
      guard let value = message.value, value >= 0 else { return }
      // Energy arrives on its own cadence, so it is attached to the next
      // reading rather than inventing one: a kcal message is not a heart rate.
      pendingKcal = value
    case "batt":
      guard let level = message.level, level >= 0, level <= 1 else { return }
      battery = level
      onBatteryChanged?(level)
    default:
      return
    }
  }

  /// The most recent cumulative kcal the watch reported, ridden along on the
  /// next heart-rate sample.
  private var pendingKcal: Double?
}

// ── Session delegate ─────────────────────────────────────────────────────────

extension HCCWatchMirrorSource: HKWorkoutSessionDelegate {
  func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didChangeTo toState: HKWorkoutSessionState,
    from fromState: HKWorkoutSessionState,
    date: Date
  ) {
    switch toState {
    case .running:
      onStatusChanged?("Following the workout on the watch.")
    case .paused:
      onStatusChanged?("The watch paused the workout.")
    case .ended, .stopped:
      onStatusChanged?("The workout ended on the watch.")
      session = nil
    default:
      break
    }
  }

  func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    onStatusChanged?("Lost the workout on the watch.")
    session = nil
  }

  func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didReceiveDataFromRemoteWorkoutSession data: [Data]
  ) {
    for payload in data { handle(payload: payload) }
  }

  func workoutSession(
    _ workoutSession: HKWorkoutSession,
    didDisconnectFromRemoteDeviceWithError error: Error?
  ) {
    onStatusChanged?("The watch disconnected.")
    session = nil
  }
}

#if DEBUG
/// `HCC_DEBUG_WATCH_WIRE=1` decodes one of each message and prints what it
/// routed to, so the contract this file states can be checked without a watch.
enum HCCWatchMirrorSelfCheck {
  static func runIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_WATCH_WIRE"] == "1" else { return }
    let fixtures = [
      #"{"t":"hr","bpm":142,"at":1756900000.5}"#,
      #"{"t":"kcal","value":213.4}"#,
      #"{"t":"batt","level":0.62}"#,
      #"{"t":"nonsense"}"#,
    ]
    for fixture in fixtures {
      let decoded = try? JSONDecoder().decode(
        HCCWatchMirrorSource.Message.self,
        from: Data(fixture.utf8)
      )
      let kind: String = decoded?.t ?? "nil"
      let bpm: String = decoded?.bpm.map { String($0) } ?? "nil"
      let value: String = decoded?.value.map { String($0) } ?? "nil"
      let level: String = decoded?.level.map { String($0) } ?? "nil"
      print("[HCCWatchMirror] \(fixture) -> t=\(kind) bpm=\(bpm) value=\(value) level=\(level)")
    }
  }
}
#endif
