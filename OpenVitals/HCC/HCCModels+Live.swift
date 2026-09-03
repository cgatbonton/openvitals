import Foundation

// HCC: the body a finished live session posts.
//
// `HCCActivityCreate` in `HCCModels.swift` predates the heart-rate fields the
// route now accepts, and it is the shape the manual Add-activity sheet sends —
// type, window, effort, notes and nothing else. A live session has measured
// numbers to attach, so it needs the fuller body rather than a widened version
// of the manual one: an omitted `zoneMs` and a present-but-empty one mean
// different things to the server (`resolveManualActivityMetrics`), and the
// manual sheet must keep sending neither.
//
// Field names are the route's zod schema verbatim
// (`src/app/api/mobile/v1/activities/route.ts` + `src/lib/activities/schema.ts`):
// `avgHr`/`maxHr` are integers 30–250, `kcal`/`distanceM` are non-negative,
// `zoneMs` is exactly six non-negative integers, and `hrSamples` is at most
// 20 000 `{t, bpm}` pairs whose `t` carries a UTC offset.

/// `POST /api/mobile/v1/activities` with heart-rate evidence attached.
struct HCCLiveActivityCreate: Encodable {
  let type: String
  let startAt: String
  let endAt: String
  /// The route requires an effort even when heart rate is present. A live
  /// session did not ask the wearer for one mid-workout, so it sends the
  /// nominal 5 — which the server then ignores, because `zoneMs` outranks the
  /// type × effort estimate in `resolveManualActivityMetrics`.
  let effort: Int
  var notes: String?
  var trainingSessionId: String?
  var avgHr: Int?
  var maxHr: Int?
  var kcal: Double?
  var zoneMs: [Int]?
  var hrSamples: [HCCLiveHrSample]?
  /// `zoneMs` above was cut against the SERVER's placeholder max HR (the phone
  /// has no measured ceiling), so the server must keep `strainEstimated` true.
  var hrCeiling: String? = "placeholder"
}

/// One point of the uploaded series.
struct HCCLiveHrSample: Encodable {
  /// ISO 8601 with an offset — `HCCTime.isoInstant` produces exactly that.
  let t: String
  let bpm: Int
}
