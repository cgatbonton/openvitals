import Foundation

// The wire shape of one Apple Watch → Command Center upload, and the pure
// arithmetic around it.
//
// Deliberately free of `import HealthKit`: everything here is value types, so
// the payload the server will actually receive can be built, encoded and
// checked without a health store — which is what the DEBUG self-check at the
// bottom does, and what let the encoded fixture be run through the server's own
// TypeScript adapter during verification.
//
// The shape mirrors `src/lib/adapters/appleHealth.ts` in the backend repo:
//
//   { samples: [{ name, value, unit, date }],
//     workouts: [{ uuid, start, end, type?, avgHr?, maxHr?, kcal?, distanceM?,
//                  hrSamples?: [{ t, bpm }] }],
//     sleep: [{ start, end, stage }],
//     anchor?, deviceModel? }
//
// `name` strings are the adapter's `APPLE_MAP` keys, not HealthKit identifiers,
// and `unit` is the unit the value is actually measured in — the server runs
// `toCatalogUnit` over the pair, so sending °C and letting it convert to the
// catalog's °F is correct where relabelling it here would not be.

// ── Wire types ───────────────────────────────────────────────────────────────

/// One scalar reading. `date` is an ISO-8601 instant with an offset.
struct HCCHealthKitSample: Codable, Equatable {
  let name: String
  let value: Double
  let unit: String
  let date: String
}

/// One heart-rate sample inside a workout window. The server bins these into
/// zones itself (and flags the resulting strain `strainEstimated`, because it
/// bins against a placeholder max HR).
struct HCCHealthKitHRSample: Codable, Equatable {
  let t: String
  let bpm: Double
}

/// One workout. `uuid` is HealthKit's own sample UUID and is the identity the
/// server upserts on, so re-uploading a workout updates its row rather than
/// duplicating it.
struct HCCHealthKitWorkout: Codable, Equatable {
  let uuid: String
  let start: String
  let end: String
  let type: String?
  let avgHr: Double?
  let maxHr: Double?
  let kcal: Double?
  let distanceM: Double?
  let hrSamples: [HCCHealthKitHRSample]?
}

/// One sleep-stage segment. `stage` is the adapter's vocabulary
/// (`core`/`light`/`deep`/`rem`/`awake`); anything else still bounds the night
/// but is not counted as a stage.
struct HCCHealthKitSleepSegment: Codable, Equatable {
  let start: String
  let end: String
  let stage: String
}

/// One POST body for `/api/ingest/apple-health`.
struct HCCHealthKitBatch: Codable, Equatable {
  var samples: [HCCHealthKitSample] = []
  var workouts: [HCCHealthKitWorkout] = []
  var sleep: [HCCHealthKitSleepSegment] = []
  /// An opaque id for this batch. The current server does not read it (only
  /// `samples`, `workouts`, `sleep` and `deviceModel` are consumed); it is sent
  /// so a retried upload can be recognised as the same batch in a request log.
  var anchor: String?
  /// What produced the readings. The server turns a model containing "watch"
  /// into `sourceDetail: "Apple Watch"`, which is the whole point of this path —
  /// so it is derived from the samples' own `HKDevice`, never assumed.
  var deviceModel: String?

  var isEmpty: Bool { samples.isEmpty && workouts.isEmpty && sleep.isEmpty }

  var sampleCount: Int { samples.count }
  var itemCount: Int { samples.count + workouts.count + sleep.count }
}

/// What the endpoint answers with (`ok()` — a bare object, not the read API's
/// `{data,…}` envelope).
struct HCCHealthKitIngestResult: Decodable, Equatable {
  struct Activities: Decodable, Equatable {
    let written: Int?
    let updated: Int?
  }

  let written: Int?
  let skipped: Int?
  let activities: Activities?
  /// Present when the payload carried nothing the server recognised.
  let note: String?

  var writtenCount: Int { written ?? 0 }
  var skippedCount: Int { skipped ?? 0 }
  var activityCount: Int { (activities?.written ?? 0) + (activities?.updated ?? 0) }
}

// ── Metric mapping ───────────────────────────────────────────────────────────

/// The quantity streams this path uploads, each pinned to the exact `APPLE_MAP`
/// key the server maps and the unit it is sent in.
///
/// `hkUnit` is the string `HKUnit(from:)` parses; `scale` converts HealthKit's
/// own scale to the one `wireUnit` names (only SpO2 needs it — HealthKit's
/// percent unit is a fraction where 1.0 means 100%).
enum HCCHealthKitMetric: String, CaseIterable {
  case hrv
  case restingHeartRate
  case respiratoryRate
  case oxygenSaturation
  case wristTemperature
  case vo2Max
  case activeEnergy
  case steps

  /// `HKQuantityTypeIdentifier` raw value.
  var typeIdentifier: String {
    switch self {
    case .hrv: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    case .restingHeartRate: "HKQuantityTypeIdentifierRestingHeartRate"
    case .respiratoryRate: "HKQuantityTypeIdentifierRespiratoryRate"
    case .oxygenSaturation: "HKQuantityTypeIdentifierOxygenSaturation"
    case .wristTemperature: "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
    case .vo2Max: "HKQuantityTypeIdentifierVO2Max"
    case .activeEnergy: "HKQuantityTypeIdentifierActiveEnergyBurned"
    case .steps: "HKQuantityTypeIdentifierStepCount"
    }
  }

  /// The adapter's `APPLE_MAP` key.
  var wireName: String {
    switch self {
    case .hrv: "heart_rate_variability"
    case .restingHeartRate: "resting_heart_rate"
    case .respiratoryRate: "respiratory_rate"
    case .oxygenSaturation: "oxygen_saturation"
    case .wristTemperature: "apple_sleeping_wrist_temperature"
    case .vo2Max: "vo2_max"
    case .activeEnergy: "active_energy"
    case .steps: "step_count"
    }
  }

  var hkUnit: String {
    switch self {
    case .hrv: "ms"
    case .restingHeartRate, .respiratoryRate: "count/min"
    case .oxygenSaturation: "%"
    case .wristTemperature: "degC"
    case .vo2Max: "ml/kg*min"
    case .activeEnergy: "kcal"
    case .steps: "count"
    }
  }

  var wireUnit: String {
    switch self {
    case .hrv: "ms"
    case .restingHeartRate: "bpm"
    case .respiratoryRate: "br/min"
    case .oxygenSaturation: "%"
    // Sent in Celsius on purpose: the catalog stores wrist temperature in °F and
    // the server's `toCatalogUnit` knows °C→°F. Converting here would mean two
    // places doing the same conversion.
    case .wristTemperature: "°C"
    case .vo2Max: "mL/kg/min"
    case .activeEnergy: "kcal"
    case .steps: "count"
    }
  }

  var scale: Double {
    switch self {
    case .oxygenSaturation: 100
    default: 1
    }
  }

  /// Cumulative streams are uploaded as one total per CLOSED civil day rather
  /// than as their thousands of constituent samples: the catalog's `steps` and
  /// `active_energy` are daily figures, and the ingest endpoint skips a
  /// duplicate (metric, time, source) rather than updating it, so a partial
  /// total uploaded mid-day would be frozen at that value for good.
  var isDailyTotal: Bool {
    switch self {
    case .activeEnergy, .steps: true
    default: false
    }
  }

  static var anchored: [HCCHealthKitMetric] { allCases.filter { !$0.isDailyTotal } }
  static var dailyTotals: [HCCHealthKitMetric] { allCases.filter { $0.isDailyTotal } }
}

// ── Sleep stages ─────────────────────────────────────────────────────────────

/// `HKCategoryValueSleepAnalysis` → the adapter's stage vocabulary.
///
/// `asleepUnspecified` maps to `asleep`, a word the server does NOT recognise as
/// a stage. That is deliberate: "asleep, stage unknown" is what an unstaged
/// source reports, and calling it light sleep would invent a breakdown nobody
/// measured. The cost is that a night with no staged segments produces no sleep
/// row at all — correct, since this path only uploads Watch-recorded sleep,
/// which is always staged.
enum HCCHealthKitSleepStage {
  static func wireName(forCategoryValue value: Int) -> String? {
    switch value {
    case 0: "inBed"       // .inBed — bounds the night, not a stage
    case 1: "asleep"      // .asleepUnspecified — see the note above
    case 2: "awake"       // .awake
    case 3: "core"        // .asleepCore ("light" in the app's vocabulary)
    case 4: "deep"        // .asleepDeep
    case 5: "rem"         // .asleepREM
    default: nil
    }
  }
}

// ── Workout types ────────────────────────────────────────────────────────────

/// `HKWorkoutActivityType` → a human name the server's `slugifySport` turns into
/// an activity type. Unknown activities are sent as "workout" rather than as a
/// numeric code, which would slugify into something meaningless.
enum HCCHealthKitWorkoutType {
  /// `HKWorkoutActivityType` raw values, transcribed from the framework header.
  private static let names: [UInt: String] = [
    6: "basketball", 8: "boxing", 9: "climbing", 11: "cross training",
    13: "cycling", 16: "elliptical", 20: "functional strength training",
    24: "hiking", 28: "martial arts", 29: "mind and body", 35: "rowing",
    37: "running", 41: "soccer", 43: "squash", 44: "stair climbing",
    46: "swimming", 48: "tennis", 49: "track and field",
    50: "traditional strength training", 52: "walking", 57: "yoga",
    58: "barre", 59: "core training", 62: "flexibility",
    63: "high intensity interval training", 64: "jump rope", 65: "kickboxing",
    66: "pilates", 68: "stairs", 69: "step training", 72: "tai chi",
    73: "mixed cardio", 79: "pickleball", 80: "cooldown", 3000: "other",
  ]

  static func name(forActivityTypeRawValue raw: UInt) -> String {
    names[raw] ?? "workout"
  }
}

// ── Batch building ───────────────────────────────────────────────────────────

enum HCCHealthKitBatchBuilder {
  /// The server's own guidance and this project's: keep one POST bounded.
  static let maxSamplesPerBatch = 2000

  /// Split one sweep into wire batches.
  ///
  /// Samples are chunked; the (always small) workout and sleep lists ride the
  /// first chunk, so nothing is ever sent twice inside one sweep. An `id` is
  /// threaded through as the batch `anchor` so the on-disk retry file and the
  /// request can be matched up in a log.
  static func batches(
    samples: [HCCHealthKitSample],
    workouts: [HCCHealthKitWorkout],
    sleep: [HCCHealthKitSleepSegment],
    deviceModel: String?,
    id: String
  ) -> [HCCHealthKitBatch] {
    var out: [HCCHealthKitBatch] = []
    var index = 0
    var cursor = 0
    repeat {
      let end = min(cursor + maxSamplesPerBatch, samples.count)
      var batch = HCCHealthKitBatch()
      batch.samples = cursor < end ? Array(samples[cursor..<end]) : []
      if index == 0 {
        batch.workouts = workouts
        batch.sleep = sleep
      }
      batch.anchor = out.isEmpty ? id : "\(id)-\(index)"
      batch.deviceModel = deviceModel
      if !batch.isEmpty { out.append(batch) }
      cursor = end
      index += 1
    } while cursor < samples.count
    return out
  }

  static func encode(_ batch: HCCHealthKitBatch) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(batch)
  }
}

// ── DEBUG self-check ─────────────────────────────────────────────────────────

#if DEBUG
enum HCCHealthKitBatchSelfCheck {
  /// A fixture with one of everything, printed as the exact JSON the phone
  /// would POST. Run with `HCC_DEBUG_HK_FIXTURE=1`; the printed body was fed
  /// through the server's own adapter during verification so both sides could
  /// be compared on the same input rather than by reading.
  static func fixture() -> HCCHealthKitBatch {
    let base = Date(timeIntervalSince1970: 1_756_800_000) // 2025-09-02T08:00:00Z
    let iso = HCCTime.isoInstant
    var batch = HCCHealthKitBatch()
    batch.deviceModel = "Apple Watch"
    batch.anchor = "fixture"
    batch.samples = [
      HCCHealthKitSample(name: HCCHealthKitMetric.hrv.wireName, value: 62.5,
                         unit: HCCHealthKitMetric.hrv.wireUnit, date: iso(base)),
      HCCHealthKitSample(name: HCCHealthKitMetric.restingHeartRate.wireName, value: 51,
                         unit: HCCHealthKitMetric.restingHeartRate.wireUnit, date: iso(base)),
      HCCHealthKitSample(name: HCCHealthKitMetric.oxygenSaturation.wireName, value: 97,
                         unit: HCCHealthKitMetric.oxygenSaturation.wireUnit, date: iso(base)),
      HCCHealthKitSample(name: HCCHealthKitMetric.wristTemperature.wireName, value: 34.2,
                         unit: HCCHealthKitMetric.wristTemperature.wireUnit, date: iso(base)),
      HCCHealthKitSample(name: HCCHealthKitMetric.steps.wireName, value: 8421,
                         unit: HCCHealthKitMetric.steps.wireUnit, date: iso(base)),
    ]
    batch.workouts = [
      HCCHealthKitWorkout(
        uuid: "00000000-0000-0000-0000-0000000000FF",
        start: iso(base.addingTimeInterval(-3600)),
        end: iso(base),
        type: "running",
        avgHr: 148,
        maxHr: 171,
        kcal: 512,
        distanceM: nil,
        hrSamples: (0..<10).map {
          HCCHealthKitHRSample(
            t: iso(base.addingTimeInterval(-3600 + Double($0) * 360)),
            bpm: 120 + Double($0) * 6
          )
        }
      )
    ]
    let night = base.addingTimeInterval(-12 * 3600)
    batch.sleep = [
      HCCHealthKitSleepSegment(start: iso(night), end: iso(night.addingTimeInterval(3600)), stage: "core"),
      HCCHealthKitSleepSegment(start: iso(night.addingTimeInterval(3600)),
                               end: iso(night.addingTimeInterval(3600 + 2700)), stage: "deep"),
      HCCHealthKitSleepSegment(start: iso(night.addingTimeInterval(6300)),
                               end: iso(night.addingTimeInterval(6300 + 3600)), stage: "rem"),
      HCCHealthKitSleepSegment(start: iso(night.addingTimeInterval(9900)),
                               end: iso(night.addingTimeInterval(9900 + 600)), stage: "awake"),
    ]
    return batch
  }

  static func runIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_HK_FIXTURE"] == "1" else { return }
    let batch = fixture()
    guard let data = try? HCCHealthKitBatchBuilder.encode(batch),
          let text = String(data: data, encoding: .utf8)
    else {
      print("[HCC][hk] fixture encode failed")
      return
    }
    print("[HCC][hk] fixture batch (\(batch.itemCount) items):")
    print(text)
  }
}
#endif
