import Foundation

// HCC: heart-rate zones and the strain they add up to — the phone's copy of the
// server's own arithmetic.
//
// PURE. No state, no clock, no network: every function here takes numbers and
// returns numbers, which is what makes it checkable against the TypeScript it
// mirrors (`src/lib/activities/zones.ts` and `strainFromZoneMinutes` in
// `src/lib/scores/engine.ts`). `HCCZonesSelfCheck` at the bottom prints the same
// fixtures the node run prints, so the two implementations can be compared
// number for number rather than by reading them side by side.
//
// The zone CUTS are not a constant here. They arrive from
// `GET /api/mobile/v1/instance` as `zones: {maxHr, floors, method}`, because the
// server owns them: a boundary that moves there must move here in the same
// deploy, and a hardcoded 0.6 on the phone would silently disagree. The fallback
// below is only what to draw before that read lands, and it is the server's
// current published value rather than an invention.

/// The zone constants the instance publishes. Optional everywhere it is used:
/// the phone must be able to draw a heart rate before `/instance` has answered.
struct HCCZoneConfig: Decodable, Equatable {
  /// The ceiling the fractions are taken against. Today the server publishes a
  /// PLACEHOLDER (190) — see `PLACEHOLDER_MAX_HR` in `zones.ts`. Nothing on the
  /// phone can improve on it, so every zone number this app shows is only as
  /// good as that ceiling, and the live screen says so.
  let maxHr: Double
  /// Six inclusive floors, as fractions of the intensity scale.
  let floors: [Double]
  /// How the fraction is taken when a resting HR is known. Informational; the
  /// phone applies %HRR whenever it has a resting HR, which is what this says.
  let method: String

  /// What to use before `/instance` has been read. The server's current values,
  /// copied so a cold launch draws the same zones the next refresh will.
  static let fallback = HCCZoneConfig(
    maxHr: 190,
    floors: [0, 0.5, 0.6, 0.7, 0.8, 0.9],
    method: "hrr_when_resting_known"
  )

  /// A config whose floors are unusable is not one to bin against.
  var isUsable: Bool { maxHr > 0 && floors.count == HCCZones.zoneCount }

  var resolved: HCCZoneConfig { isUsable ? self : .fallback }
}

enum HCCZones {
  /// Six zones — the length of every `zoneMs` array in this app, server included.
  static let zoneCount = 6

  /// A gap longer than this between two readings means the source stopped
  /// reporting, not that one heart rate was held for the whole stretch. The
  /// server credits at most this much of such a gap (`MAX_SAMPLE_GAP_MS`); so
  /// does the accumulator below, so a dropout cannot manufacture zone time.
  static let maxSampleGap: TimeInterval = 120

  /// Where a heart rate sits on the intensity scale.
  ///
  /// %HRR (Karvonen) when today's resting HR is known — it removes the floor
  /// everyone carries at rest — and plain %HRmax otherwise. Same rule as
  /// `binHrSamplesToZoneMs`, including its guard that a resting HR at or above
  /// the ceiling is not a resting HR.
  static func fraction(bpm: Double, config: HCCZoneConfig, restingHr: Double?) -> Double {
    let maxHr = config.maxHr
    guard maxHr > 0 else { return 0 }
    let rest = (restingHr ?? 0) > 0 && (restingHr ?? 0) < maxHr ? (restingHr ?? 0) : 0
    let span = maxHr - rest
    guard span > 0 else { return 0 }
    return (bpm - rest) / span
  }

  /// Which zone (0…5) a fraction falls in: the last floor at or below it.
  /// Floors are inclusive — exactly 50% of max is the bottom of zone 1, the
  /// convention every zone chart uses and the one `zoneForFraction` applies.
  static func zoneIndex(fraction: Double, floors: [Double]) -> Int {
    guard fraction.isFinite else { return 0 }
    var zone = 0
    for index in 1..<floors.count where fraction >= floors[index] {
      zone = index
    }
    return zone
  }

  /// The zone a heart rate is in, straight through both steps above.
  static func zoneIndex(bpm: Double, config: HCCZoneConfig, restingHr: Double?) -> Int {
    zoneIndex(fraction: fraction(bpm: bpm, config: config, restingHr: restingHr), floors: config.floors)
  }

  /// The bpm window a zone covers, for the chip that names it.
  /// `nil` when the config has no floor for that zone.
  static func range(zone: Int, config: HCCZoneConfig, restingHr: Double?) -> ClosedRange<Int>? {
    guard zone >= 0, zone < config.floors.count else { return nil }
    let maxHr = config.maxHr
    let rest = (restingHr ?? 0) > 0 && (restingHr ?? 0) < maxHr ? (restingHr ?? 0) : 0
    let span = maxHr - rest
    guard span > 0 else { return nil }
    let low = rest + span * config.floors[zone]
    let high = zone + 1 < config.floors.count ? rest + span * config.floors[zone + 1] : maxHr
    let lowInt = Int(low.rounded())
    let highInt = Int(high.rounded())
    guard highInt >= lowInt else { return nil }
    return lowInt...highInt
  }

  /// The percentage-of-scale label the mockup's zone chip shows ("50–60%").
  static func percentLabel(zone: Int, config: HCCZoneConfig) -> String? {
    guard zone >= 0, zone < config.floors.count else { return nil }
    let low = Int((config.floors[zone] * 100).rounded())
    let high = zone + 1 < config.floors.count ? Int((config.floors[zone + 1] * 100).rounded()) : 100
    return "\(low)–\(high)%"
  }

  // ── Strain ─────────────────────────────────────────────────────────────────

  /// Which of the engine's three buckets each zone lands in.
  ///
  /// A 1:1 copy of `ZONE_BUCKET` in `zones.ts`: zone 0 is not elevated heart
  /// rate at all and is dropped, 1–2 are fat-burn, 3–4 cardio, 5 peak. The
  /// approximation (zone 4 straddles Fitbit's 85% cardio/peak line and is
  /// credited wholly to cardio) is the server's, deliberately reproduced —
  /// a "better" mapping here would make the phone's number disagree with the
  /// one that ends up stored.
  private static let bucket: [Int?] = [nil, 0, 0, 1, 1, 2]

  /// The Edwards ladder the engine weights the three buckets by.
  private static let bucketWeight: [Double] = [1, 3, 5]

  /// The normalizer that maps 24 h at peak (1440 × 5 = 7200 TRIMP) onto 21.
  private static let trimpNormalizer: Double = 7201

  /// Strain (0–21) from six zone durations in milliseconds.
  ///
  /// `zoneMsToBuckets` → `strainFromZoneMinutes`, collapsed into one pass. Same
  /// curve the day score, the provider adapters and the manual-log path use, so
  /// the number on the live screen is on the scale the stored row will be on.
  static func strain(zoneMs: [Double]) -> Double {
    var trimp: Double = 0
    for index in 0..<min(zoneMs.count, zoneCount) {
      guard let target = bucket[index] else { continue }
      let milliseconds = zoneMs[index]
      guard milliseconds.isFinite, milliseconds > 0 else { continue }
      trimp += bucketWeight[target] * (milliseconds / 60_000)
    }
    let strain = (21 * log(trimp + 1)) / log(trimpNormalizer)
    return min(21, max(0, strain))
  }

  /// Per-zone minutes, which is what `HCCZoneBars` draws.
  static func minutes(zoneMs: [Double]) -> [Double] {
    (0..<zoneCount).map { index in
      guard index < zoneMs.count else { return 0 }
      let milliseconds = zoneMs[index]
      return milliseconds.isFinite && milliseconds > 0 ? milliseconds / 60_000 : 0
    }
  }

  /// The six integers the POST body carries (`zoneMs` is `z.number().int()`).
  static func uploadZoneMs(_ zoneMs: [Double]) -> [Int] {
    (0..<zoneCount).map { index in
      guard index < zoneMs.count else { return 0 }
      let milliseconds = zoneMs[index]
      return milliseconds.isFinite && milliseconds > 0 ? Int(milliseconds.rounded()) : 0
    }
  }
}

// ── The running total ────────────────────────────────────────────────────────

/// Accumulates zone time across a live session.
///
/// Each reading owns the stretch that FOLLOWS it — the server's rule, because
/// the reading is the best estimate of heart rate over the interval it opens.
/// Two departures from the server's batch version, both deliberate:
///
///   * a paused stretch is credited to nothing. The server, handed the same
///     samples, would see a gap and credit up to two minutes of it; the phone
///     knows the gap was a pause and drops it outright.
///   * the last reading is credited nothing until the next one arrives, so the
///     running total lags one sampling interval. The server's median-gap tail
///     is a closing adjustment on a finished series and has no meaning while
///     the series is still growing.
struct HCCZoneAccumulator {
  private(set) var zoneMs: [Double] = Array(repeating: 0, count: HCCZones.zoneCount)
  private var lastAt: Date?
  private var lastZone: Int?

  /// Credit the interval this sample closes, then remember it as the open one.
  mutating func add(at: Date, zone: Int, isPaused: Bool) {
    defer {
      lastAt = at
      lastZone = isPaused ? nil : zone
    }
    guard !isPaused, let lastAt, let lastZone, lastZone < zoneMs.count else { return }
    let gap = at.timeIntervalSince(lastAt)
    guard gap > 0 else { return }
    zoneMs[lastZone] += min(gap, HCCZones.maxSampleGap) * 1000
  }

  /// A pause closes the open interval without crediting anything after it.
  mutating func pause() {
    lastZone = nil
  }

  var strain: Double { HCCZones.strain(zoneMs: zoneMs) }
  var minutes: [Double] { HCCZones.minutes(zoneMs: zoneMs) }
}

#if DEBUG
/// `HCC_DEBUG_ZONES_CHECK=1` prints the fixtures the node run prints, so the two
/// implementations of the same formula can be compared number for number.
///
/// There is no test target in this project (see the fork's AGENTS.md), and the
/// only thing that makes a ported formula trustworthy is running the same inputs
/// through both. The fixtures are printed, not asserted, because the comparison
/// is done against output from `src/lib/activities/zones.ts`, not against a
/// number retyped here.
enum HCCZonesSelfCheck {
  static var isRequested: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_ZONES_CHECK"] == "1"
  }

  /// Two fixtures: a mixed session and a flat zone-3 hour.
  static let fixtures: [[Double]] = [
    [180_000, 300_000, 600_000, 900_000, 420_000, 120_000],
    [0, 0, 0, 3_600_000, 0, 0],
  ]

  static func runIfRequested() {
    guard isRequested else { return }
    print("[HCCZones] strain fixtures (compare with node src/lib/activities/zones.ts)")
    for zoneMs in fixtures {
      let minutes = HCCZones.minutes(zoneMs: zoneMs).map { String(format: "%.6f", $0) }
      print("[HCCZones] zoneMs=\(zoneMs.map { Int($0) }) minutes=[\(minutes.joined(separator: ","))] strain=\(String(format: "%.9f", HCCZones.strain(zoneMs: zoneMs)))")
    }
    let config = HCCZoneConfig.fallback
    for bpm in [55.0, 95.0, 120.0, 140.0, 158.0, 176.0] {
      let withRest = HCCZones.zoneIndex(bpm: bpm, config: config, restingHr: 50)
      let noRest = HCCZones.zoneIndex(bpm: bpm, config: config, restingHr: nil)
      print("[HCCZones] bpm=\(Int(bpm)) zoneHRR(rest50)=\(withRest) zoneHRmax=\(noRest)")
    }
  }
}
#endif
