import Foundation

// HCC: what a live heart-rate source is, and the synthetic one that stands in
// for a real strap in the simulator.
//
// Three sources implement this: the Apple Watch companion mirrored through
// HealthKit (`HCCWatchMirrorSource`), a Bluetooth heart-rate device
// (`HCCBLEHeartRateSource`), and — DEBUG only — a generated ramp, which is the
// only one that can run on a simulator with no radio and no watch.
//
// The protocol is deliberately thin: a label, a stream, start, stop. Everything
// a source could differ about — how it finds a device, whether it reports
// energy, what its battery is doing — is either in the stream or is the source's
// own business. The live screen reads the stream and nothing else, which is why
// swapping the fake source in for a screenshot exercises the real code path.

/// One reading from a live source.
struct HCCHeartRateSample: Equatable {
  let at: Date
  let bpm: Int
  /// Cumulative active kilocalories the SOURCE reports for this session, when
  /// it reports any. Nil is the normal case — a chest strap does not know the
  /// wearer's mass and a plain BLE device may not send the energy field at all —
  /// and it renders as "--", never as a number the phone made up.
  var activeKcal: Double?
}

/// A thing that streams heart rate for the duration of a workout.
protocol HCCLiveHeartRateSource: AnyObject {
  /// What the screen calls it. Device-neutral copy — no manufacturer names
  /// (AGENTS.md); a strap is "Bluetooth heart-rate device", not its brand.
  var label: String { get }
  /// The readings. Finishes when the source stops.
  var samples: AsyncStream<HCCHeartRateSample> { get }
  func start() async throws
  func stop()
}

/// Which source a session is using. The setup sheet picks one of these; the
/// state box keeps it so the header can say where the number came from.
enum HCCLiveSourceKind: String, CaseIterable, Identifiable, Hashable {
  case watch
  case bluetooth
  #if DEBUG
  case debug
  #endif

  var id: String { rawValue }

  /// The header's middle term ("Assault bike · Apple Watch · zone 2 goal").
  var label: String {
    switch self {
    case .watch: "Apple Watch"
    case .bluetooth: "Bluetooth device"
    #if DEBUG
    case .debug: "Simulated source"
    #endif
    }
  }

  /// What the setup sheet says under the option, so a pick is never a guess.
  var detail: String {
    switch self {
    case .watch: "Streams from the companion Watch app while it records the workout."
    case .bluetooth: "A chest strap or any device broadcasting standard heart rate."
    #if DEBUG
    case .debug: "Generated readings. Debug builds only."
    #endif
    }
  }

  /// The kinds offered on this build. The synthetic source is never offered in
  /// a Release build, and never becomes a default.
  static var offered: [HCCLiveSourceKind] {
    #if DEBUG
    HCCDebugHeartRateSource.isRequested ? [.debug, .watch, .bluetooth] : [.watch, .bluetooth]
    #else
    [.watch, .bluetooth]
    #endif
  }
}

// ── The synthetic source ─────────────────────────────────────────────────────

#if DEBUG
/// A generated 60 → 165 bpm ramp at 1 Hz, with noise and accruing kilocalories.
///
/// Opt-in through `HCC_DEBUG_FAKE_HR=1` and compiled out of Release entirely.
/// It exists because the live screen cannot otherwise be seen: the simulator has
/// no Bluetooth radio and no paired watch, so without this the running state,
/// the filling zone bars and the end-of-session upload have no way to be looked
/// at before a device is in hand. Nothing it produces is ever presented as a
/// measurement — a session recorded from it is a session the tester started
/// knowingly, on a debug build, against a local backend.
final class HCCDebugHeartRateSource: HCCLiveHeartRateSource, @unchecked Sendable {
  static var isRequested: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_FAKE_HR"] == "1"
  }

  let label = "Simulated source"

  private var continuation: AsyncStream<HCCHeartRateSample>.Continuation?
  private var task: Task<Void, Never>?
  private let stream: AsyncStream<HCCHeartRateSample>

  init() {
    var captured: AsyncStream<HCCHeartRateSample>.Continuation?
    stream = AsyncStream { captured = $0 }
    continuation = captured
  }

  var samples: AsyncStream<HCCHeartRateSample> { stream }

  func start() async throws {
    guard task == nil else { return }
    let continuation = self.continuation
    task = Task.detached { [weak self] in
      // The ramp: 60 bpm at rest climbing to about 165 over five minutes, then
      // holding with a slow wander. Noise is deterministic (a sine beat, not a
      // random draw) so two runs of a screenshot look the same.
      var tick = 0
      var kcal: Double = 0
      while !Task.isCancelled {
        let seconds = Double(tick)
        let ramp = min(1, seconds / 300)
        let base = 60 + ramp * 105
        let wander = sin(seconds / 11) * 4 + cos(seconds / 3.7) * 2
        let bpm = Int(max(45, min(200, base + wander)).rounded())
        // Roughly 8–14 kcal a minute as the heart rate climbs — an accrual, not
        // a physiological claim; the source is synthetic and says so.
        kcal += (6 + ramp * 8) / 60
        continuation?.yield(HCCHeartRateSample(at: Date(), bpm: bpm, activeKcal: kcal))
        tick += 1
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      _ = self
    }
  }

  func stop() {
    task?.cancel()
    task = nil
    continuation?.finish()
    continuation = nil
  }
}
#endif
