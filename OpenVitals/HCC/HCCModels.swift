import Foundation

// Wire types for the Health Command Center read API. Every field name here is
// the server's field name — these structs are the contract, mirrored from
// src/lib/mobile/{envelope,read,shape,devices,dashboard,sleepPlan-core}.ts,
// src/lib/queries.ts, src/lib/wearables{,-narrative}.ts and
// src/lib/activities/index.ts in the health-command-center repo.
//
// Two rules hold throughout:
//
//  * Timestamps stay `String`. An ISO instant and a civil `YYYY-MM-DD` day key
//    look alike but are not: the day key is the server's bucket, and re-reading
//    it through the device calendar would shift a whole timeline by a day for
//    anyone east of UTC. Instants get parsed on demand (`HCCTime.instant`);
//    day keys are never parsed at all.
//  * Optional means the server sends null. A missing number is rendered as
//    unavailable, never as zero and never invented.

// ── Envelope ─────────────────────────────────────────────────────────────────

/// Wrapper around every `/api/mobile/v1/*` payload.
struct HCCEnvelope<T: Decodable>: Decodable {
  let data: T
  let generatedAt: String
  let instance: HCCInstanceStamp
}

/// Which deployment answered. Two people run this app against two isolated
/// instances; a client pointed at the wrong base URL should fail loudly rather
/// than quietly show the wrong person's numbers.
struct HCCInstanceStamp: Decodable, Equatable {
  let id: String
  let timezone: String
}

/// Error body shape shared by every route (`{ "error": "…" }`).
struct HCCErrorBody: Decodable {
  let error: String
}

// ── Auth ─────────────────────────────────────────────────────────────────────

/// `POST /api/auth/mobile/login` — a BARE object, not the data envelope.
struct HCCLoginResponse: Decodable {
  /// Bearer credential for the app itself (`hccm_…`). Shown once.
  let token: String
  /// Narrow HealthKit upload credential (`hcc_…`) for the ingest endpoint.
  let ingestToken: String
  let user: HCCLoginUser
  let instance: HCCLoginInstance
}

struct HCCLoginUser: Decodable {
  let id: String
  let email: String
  let name: String?
}

struct HCCLoginInstance: Decodable {
  let id: String
  let displayName: String
  let timezone: String
  /// The server's own idea of its public URL. Advisory only — the app keeps
  /// talking to the base URL the user typed.
  let baseUrl: String?
}

// ── Provenance copy ──────────────────────────────────────────────────────────

/// Which instrument produced a number.
///
/// `computed` is the server's own scoring engine running over whatever stream
/// it has, so it names the server, not a wrist. The device behind it is
/// answered by `HCCInstance.sources`, not by the origin.
enum HCCOrigin: String {
  case computed
  case whoop
  case unknown

  init(_ raw: String?) {
    self = raw.flatMap(HCCOrigin.init(rawValue:)) ?? .unknown
  }

  var deviceLabel: String { HCCCopy.originLabel(rawValue) }
}

/// User-facing labels for server-side identifiers.
///
/// Central on purpose: the fork's copy rule (AGENTS.md) is that no
/// manufacturer name reaches the interface, and one mapping function is the
/// only way to keep that true as screens are added.
enum HCCCopy {
  /// `HomeScore.origin` / `MergedScore.origin` → a label.
  static func originLabel(_ origin: String?) -> String {
    switch origin {
    case "computed": "Command Center"
    case "whoop": "band"
    default: "device"
    }
  }

  /// A `Source` enum value from the server → a label.
  static func sourceLabel(_ source: String?) -> String {
    switch source {
    case "WHOOP": "band"
    case "FITBIT": "Fitbit"
    case "APPLE_HEALTH": "Apple Health"
    case "WITHINGS": "Withings"
    case "EIGHT_SLEEP": "Eight Sleep"
    case "MANUAL": "Manual entry"
    case "LAB": "Lab"
    case .some(let other) where !other.isEmpty: other.capitalized
    default: "Unknown source"
    }
  }
}

// ── Free-form JSON ───────────────────────────────────────────────────────────

/// A JSON column the server does not type (`AiOutput.citations`,
/// `WeeklyInsight.stats`). Kept rather than dropped: it is the evidence behind
/// a card, and a client that discards it cannot show its work.
indirect enum HCCJSONValue: Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: HCCJSONValue])
  case array([HCCJSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([HCCJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: HCCJSONValue].self) {
      self = .object(value)
    } else {
      self = .null
    }
  }

  var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }

  var doubleValue: Double? {
    if case let .number(value) = self { return value }
    return nil
  }

  subscript(key: String) -> HCCJSONValue? {
    if case let .object(fields) = self { return fields[key] }
    return nil
  }
}

// ── /home ────────────────────────────────────────────────────────────────────

/// One of the three headline scores.
struct HCCHomeScore: Decodable, Identifiable {
  /// `recovery` | `sleep` | `strain`.
  let key: String
  let label: String
  /// Null when neither the computed nor the device slug has ever been written.
  let value: Double?
  /// Null where the number carries no unit (strain is a 0–21 scale).
  let unit: String?
  /// UTC `YYYY-MM-DD` the reading is for.
  let day: String?
  /// `computed` | `whoop` | null.
  let origin: String?
  /// Older than the server's staleness window — render muted, never hide.
  let stale: Bool
  /// `nominal` | `watch` | `alert`; absent where the score has no direction.
  let status: String?
  /// True when the number is not one to act on yet.
  let calibrating: Bool
  /// The server's sentence saying why it is calibrating. Show it verbatim.
  let reason: String?

  var id: String { key }
}

/// A biomarker row as the web app models it (`MetricView`).
struct HCCMetricView: Decodable, Identifiable {
  let slug: String
  let displayName: String
  let category: String
  let unit: String?
  let value: Double?
  let optimalDir: String
  /// Graded against the app's OPTIMAL target, never a lab reference range.
  let status: String
  let n: Int
  let lastTestedISO: String
  let ageText: String
  /// The catalog blurb. Named `summary` locally so it does not shadow
  /// `CustomStringConvertible.description` at every call site.
  let summary: String
  let optimalLow: Double?
  let optimalHigh: Double?
  let comparison: String
  let trend: String?
  let aiInsight: String?
  let insightStale: Bool

  var id: String { slug }

  private enum CodingKeys: String, CodingKey {
    case slug, displayName, category, unit, value, optimalDir, status, n
    case lastTestedISO, ageText, optimalLow, optimalHigh, comparison, trend
    case aiInsight, insightStale
    case summary = "description"
  }
}

/// `GET /api/mobile/v1/home[?date=YYYY-MM-DD]`.
struct HCCHome: Decodable {
  /// The civil day this snapshot describes.
  let date: String
  let recovery: Double?
  let scores: [HCCHomeScore]
  /// The strain worth aiming for today, from today's recovery.
  let strainTarget: Double?
  let hrv: Double?
  let rhr: Double?
  let vitals: [HCCMetricView]
  let flags: [HCCInsightCard]
  let dailyRead: HCCInsightCard?
  let metricCount: Int
  /// Which wrist the rings prefer; null = the automatic computed-first rule.
  let preferredSource: String?

  func score(_ key: String) -> HCCHomeScore? {
    scores.first { $0.key == key }
  }
}

// ── /scores ──────────────────────────────────────────────────────────────────

struct HCCScoresResponse: Decodable {
  let days: [HCCScoreDay]
}

/// One calendar day of ring history. A day neither source reported is null —
/// a missing recovery and a recovery of zero are opposite claims.
struct HCCScoreDay: Decodable, Identifiable {
  let date: String
  let recovery: HCCMergedScore?
  let sleepPerformance: HCCMergedScore?
  let strain: HCCMergedScore?
  let strainTarget: Double?

  var id: String { date }
}

struct HCCMergedScore: Decodable {
  let value: Double
  /// `computed` | `whoop`.
  let origin: String
}

// ── /sleep ───────────────────────────────────────────────────────────────────

/// `GET /api/mobile/v1/sleep/{latest,YYYY-MM-DD}`. 404 when nothing is on record.
struct HCCSleepNight: Decodable {
  /// Wake day, `YYYY-MM-DD`.
  let date: String
  /// Which device recorded the night; null when nothing was recorded.
  let source: String?
  let stages: HCCSleepStages
  let disturbances: Double?
  /// Hours the sleep-need model says the body needed.
  let needH: Double?
  /// Sleep debt, in hours, carried into that day.
  let debtH: Double?
  /// THE sleep score for this night — the same resolved per-day value `/home`
  /// and `/scores` show, not a second opinion. Null when neither instrument
  /// scored the night. One night has one score: render this, never
  /// `modelPerformance`, wherever a sleep score appears.
  let performance: Double?
  /// Which instrument the resolved score came from (`computed` | `whoop`);
  /// null when there is no score. Label it through `HCCCopy.originLabel`, the
  /// same as `HCCHomeScore.origin`.
  let performanceOrigin: String?
  /// The engine's own ratio implied by `needH`/`debtH`. Explanatory only: it
  /// belongs beside the need/debt decomposition, and it can differ from
  /// `performance` whenever the resolved score came from the band rather than
  /// the engine. Showing it as the score is what once put two different
  /// numbers for one night on two screens.
  let modelPerformance: Double?
  /// A real stage timeline when the stored payload has one; never inferred.
  let segments: [HCCSleepSegment]?
  let respiratoryRate: Double?
}

struct HCCSleepStages: Decodable {
  let deepH: Double?
  let remH: Double?
  let lightH: Double?
  let awakeH: Double?
  let totalH: Double?
}

struct HCCSleepSegment: Decodable {
  /// ISO instants.
  let start: String
  let end: String
  /// `deep` | `rem` | `light` | `awake`.
  let stage: String
}

// ── /vitals ──────────────────────────────────────────────────────────────────

struct HCCVitalsResponse: Decodable {
  let vitals: [HCCVitalSeries]
}

struct HCCVitalSeries: Decodable, Identifiable {
  let slug: String
  let label: String
  let unit: String?
  /// Set on `hrv_sdnn` only, and it reads `RMSSD`. The slug is historical; the
  /// rows hold RMSSD, so the client must not label these milliseconds "SDNN".
  let hrvKind: String?
  let series: [HCCVitalPoint]
  let baseline: HCCBaselineBand?
  /// The instance profile's optimal band; null means no honest band exists.
  let optimal: HCCOptimalRange?
  let latest: HCCVitalLatest?
  /// Set on `wrist_temp` only, where the deviation IS the reading.
  let deltaVsBaseline: Double?

  var id: String { slug }
}

struct HCCVitalPoint: Decodable {
  let t: String
  let value: Double
  let min: Double
  let max: Double
}

/// Trailing mean ± SD, plus the window it was taken over — "±1 SD" means
/// nothing without knowing how many days went into it.
struct HCCBaselineBand: Decodable {
  let mean: Double
  let sd: Double
  let n: Int
  let from: String
  let to: String
}

struct HCCVitalLatest: Decodable {
  let t: String
  let value: Double
  let deltaVsBaseline: Double?
}

/// A literature-derived optimal band. One-sided when `low` or `high` is null.
struct HCCOptimalRange: Decodable {
  let low: Double?
  let high: Double?
  /// Where the numbers come from — show it wherever the band is shown.
  let basis: String
  let note: String?
}

// ── /deck ────────────────────────────────────────────────────────────────────

struct HCCDeckResponse: Decodable {
  let deck: [HCCDeckSignal]
  let provenance: [HCCDeckProvenance]
  /// Source enum values, e.g. `WHOOP`, `FITBIT` — label with `HCCCopy`.
  let sources: [String]
  let coverage: [String: HCCCoverage]
}

/// One stream on the unified wearables deck (`UnifiedSignal`).
struct HCCDeckSignal: Decodable, Identifiable {
  let slug: String
  let displayName: String
  let unit: String?
  /// `signal` | `confounder`. Confounders move the signals on their own.
  let role: String
  let current: Double?
  let currentNights: Int
  let baselineMean: Double?
  let baselineSd: Double?
  let baselineNights: Int
  /// Current mean in baseline SDs. Positive = higher than baseline.
  let deviationSd: Double?
  /// True when the deviation runs in the direction that would concern us.
  let adverse: Bool
  let daysOutsideBand: Int
  /// `steady` | `watch` | `flag` | `calibrating` | `no-data`.
  let verdict: String
  let series: [HCCSeriesPoint]
  /// The most recent usable stretch of wear, however long ago it was.
  let reference: HCCDeckReference?
  let lastSeen: String?
  /// What this stream can actually resolve; null when the noise floor is
  /// unknown.
  let detection: HCCDetection?
  let source: String
  /// `autonomic` | `thermo` | `body`.
  let system: String

  var id: String { "\(source)/\(slug)" }
}

struct HCCSeriesPoint: Decodable {
  let t: String
  let value: Double
}

struct HCCDeckReference: Decodable {
  let mean: Double
  let sd: Double?
  let nights: Int
  let from: String
  let to: String
}

struct HCCDetection: Decodable {
  /// Smallest shift resolvable at 80% power, in metric units.
  let minDetectable: Double
  let targetShift: Double?
  let targetLabel: String?
  let resolvable: Bool?
  let baselineNights: Int
  let currentNights: Int
  /// True when this is what the stream WILL resolve once nights accumulate.
  let projected: Bool
}

struct HCCDeckProvenance: Decodable, Identifiable {
  let source: String
  let lastSeenAt: String?
  let streams: Int

  var id: String { source }
}

struct HCCCoverage: Decodable {
  let quarters: [HCCCoverageQuarter]
  let eras: [HCCCoverageEra]
  let totalNights: Int
  let spanDays: Int
  let wearPct: Double
  let firstDay: String?
  let lastDay: String?
  /// Date the 4.0-only fields first appear, if ever.
  let deviceChange: String?
}

struct HCCCoverageQuarter: Decodable, Identifiable {
  let label: String
  let nights: Int
  let start: String

  var id: String { label }
}

struct HCCCoverageEra: Decodable, Identifiable {
  /// `worn` | `gap`.
  let kind: String
  let from: String
  let to: String
  let days: Int
  let label: String

  var id: String { "\(kind)/\(from)" }
}

// ── /insights ────────────────────────────────────────────────────────────────

struct HCCInsightsResponse: Decodable {
  let insights: [HCCInsightCard]
  let openCount: Int
}

/// An `AiOutput` row: the cards under the rings, the home flags, and the daily
/// read all share this shape.
struct HCCInsightCard: Decodable, Identifiable {
  let id: String
  let kind: String
  let title: String
  let summary: String
  /// Markdown, when the card has a long form.
  let body: String?
  /// `INFO` | `LOW` | `MEDIUM` | `HIGH` | `CRITICAL`.
  let severity: String
  /// `ACTIVE` | `ACKNOWLEDGED` | `DISMISSED`.
  let status: String
  let evidenceGrade: String?
  let relatedMetricSlugs: [String]
  let citations: HCCJSONValue?
  let createdAt: String
}

// ── /insights/weekly ─────────────────────────────────────────────────────────

struct HCCWeeklyInsightsResponse: Decodable {
  let rows: [HCCWeeklyInsight]
  let latest: HCCWeeklyInsight?
}

struct HCCWeeklyInsight: Decodable, Identifiable {
  let id: String
  /// Inclusive civil days: Sunday the window opens, Saturday it closes.
  let weekStart: String
  let weekEnd: String
  /// One plain-English sentence for the collapsed row.
  let headline: String
  /// The week in review, markdown.
  let summary: String
  /// The deterministic numbers the summary was written from.
  let stats: HCCJSONValue?
  /// 0 means an empty week, recorded as such.
  let metricsCount: Int
  let createdAt: String
}

// ── /metrics ─────────────────────────────────────────────────────────────────

/// The metric catalog. `basis` is `"optimal"` and says so in the payload: these
/// bounds are the app's optimal targets, NOT lab reference ranges, and a value
/// outside them is "below/above target", never "abnormal".
struct HCCMetricsResponse: Decodable {
  let basis: String
  let metrics: [HCCMetric]
}

struct HCCMetric: Decodable, Identifiable {
  let slug: String
  let displayName: String
  let category: String
  let unit: String?
  /// Optimal target floor / ceiling. Null where the target is one-sided.
  let refLow: Double?
  let refHigh: Double?
  /// `higher` | `lower` | `range` | `neutral`.
  let optimalDir: String
  let isHighFreq: Bool

  var id: String { slug }
}

// ── /instance ────────────────────────────────────────────────────────────────

/// Who this deployment serves and how to read its numbers. Fetched once at
/// launch so the client never hardcodes a band or a timezone.
struct HCCInstance: Decodable {
  let id: String
  let displayName: String
  let timezone: String
  /// Which devices have ever written to this instance.
  let sources: [String]
  let scoreBands: HCCScoreBands
  let wearableOptimalRanges: [String: HCCOptimalRange]
}

struct HCCScoreBands: Decodable {
  let recovery: HCCScoreBand
  let sleep: HCCScoreBand
  let strain: HCCStrainBand
}

struct HCCScoreBand: Decodable {
  let nominal: Double
  let watch: Double
}

struct HCCStrainBand: Decodable {
  let max: Double
}

// ── /activities ──────────────────────────────────────────────────────────────

struct HCCActivitiesResponse: Decodable {
  let date: String
  let activities: [HCCActivity]
}

struct HCCActivityResponse: Decodable {
  let activity: HCCActivityDetail
}

struct HCCActivity: Decodable, Identifiable {
  let id: String
  /// `WORKOUT` | `SLEEP` | …
  let kind: String
  let type: String
  /// ISO instants.
  let startAt: String
  let endAt: String
  let durationMin: Double
  let source: String
  let strain: Double?
  /// True when the strain is the app's estimate rather than the device's.
  let strainEstimated: Bool
  let avgHr: Double?
  let maxHr: Double?
  let kcal: Double?
  let distanceM: Double?
  /// Present only on the derived sleep row a night produces when no session
  /// was recorded.
  let synthetic: Bool?
}

struct HCCActivityDetail: Decodable, Identifiable {
  let id: String
  let kind: String
  let type: String
  let startAt: String
  let endAt: String
  let durationMin: Double
  let source: String
  let strain: Double?
  let strainEstimated: Bool
  let avgHr: Double?
  let maxHr: Double?
  let kcal: Double?
  let distanceM: Double?
  let synthetic: Bool?
  let zoneMs: [Double]
  let zoneMin: [Double]
  let effort: Double?
  let notes: String?
  let trainingSessionId: String?
}

// ── /devices ─────────────────────────────────────────────────────────────────

struct HCCDeviceList: Decodable {
  let devices: [HCCDevice]
  let preferredSource: String?
}

struct HCCDevice: Decodable, Identifiable {
  let source: String
  /// `OAuthConnection.provider`, or null for a source that pushes to us.
  let provider: String?
  let label: String
  /// `ACTIVE` | `NEEDS_REAUTH` | `REVOKED` | `n/a`.
  let status: String
  /// When the pull last ran. Null for push-only sources.
  let lastSyncAt: String?
  let lastDataAt: String?
  /// Null wherever no battery is knowable — several sources expose none at all.
  let battery: HCCDeviceBattery?
  /// True for the ONE wrist source currently believed for display.
  let drives: Bool

  var id: String { source }
}

struct HCCDeviceBattery: Decodable {
  let level: Double?
  let status: String?
}

// ── /dashboard ───────────────────────────────────────────────────────────────

/// The home screen's tile order. Stored on the USER, so a layout saved on the
/// phone is the layout the browser opens with.
struct HCCDashboardPrefs: Decodable {
  let tiles: [String]
  /// True when nothing usable was stored and the built-in order is served.
  let isDefault: Bool
  let catalog: [HCCDashboardTile]
}

struct HCCDashboardTile: Decodable, Identifiable {
  let slug: String
  let label: String
  /// The catalog metric this tile reads, where it reads one.
  let metricSlug: String?
  /// `graph` | `metric` | `derived` | `list`.
  let kind: String
  /// Whether this instance can actually fill the tile right now. Optional
  /// because it was added to `/dashboard` after this client shipped: `nil`
  /// means "this server does not say", and the customize sheet falls back to
  /// deriving it from the payloads it already has. `var` so the synthesized
  /// memberwise initializer defaults it to nil and existing call sites that
  /// build a tile by hand keep compiling. (D-C.)
  var available: Bool?

  var id: String { slug }
}

// ── /alarm and /sleep/plan ───────────────────────────────────────────────────

struct HCCAlarmResponse: Decodable {
  let alarm: HCCAlarm
  let isDefault: Bool
}

/// `mode: exact` wakes at `time`; `goal` may fire anywhere inside a
/// `smartWindowMin` window ending at `time`.
struct HCCAlarm: Codable, Equatable {
  /// 24h wall clock in the instance timezone, `HH:MM`.
  let time: String
  /// `exact` | `goal`.
  let mode: String
  let on: Bool
  let smartWindowMin: Int
  let watchHaptic: Bool
}

struct HCCSleepPlan: Decodable {
  /// The evening the plan is for.
  let date: String
  /// Hours tonight should deliver. Null when there is no history.
  let needH: Double?
  let decomposition: HCCSleepNeedDecomposition?
  let currentDebtH: Double?
  let lastNightH: Double?
  /// ISO instants. Null when there is no history to size the night with.
  let recommendedBedtime: String?
  let recommendedWake: String?
  let alarm: HCCAlarm
  /// Provenance of the strain term; null when a default was assumed.
  let source: String?
}

struct HCCSleepNeedDecomposition: Decodable {
  let baseNeedH: Double
  /// Hours added by accumulated debt.
  let debtH: Double
  /// Hours added by today's strain.
  let strainH: Double
  /// Structurally present and always 0 — no stream here reports naps.
  let napsH: Double
}

// ── Instants ─────────────────────────────────────────────────────────────────

/// ISO instant parsing, kept in one place.
///
/// Only for values documented as instants. Civil day keys (`YYYY-MM-DD`) are
/// the server's bucket and must never go through a formatter: re-deriving them
/// from the device calendar is how a timeline slips a day.
enum HCCTime {
  private static let withFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let plain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static func instant(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    return withFractional.date(from: iso) ?? plain.date(from: iso)
  }

  /// A `Date` back onto the wire. Always carries an offset, because the
  /// activity routes require one (`z.string().datetime({ offset: true })`).
  static func isoInstant(_ date: Date) -> String {
    plain.string(from: date)
  }
}

// ── Writes ───────────────────────────────────────────────────────────────────
//
// Request bodies and the small acknowledgements the mutating routes answer
// with. Each mirrors the route's zod schema exactly; a field the schema marks
// required is non-optional here, and one it marks nullable encodes an explicit
// `null` rather than being omitted.

/// `PATCH /api/insights/{id}` body. Only `status` is sent from the phone — the
/// narrative-rewrite fields on that route belong to the agent flow, not here.
struct HCCInsightStatusBody: Encodable {
  /// `ACTIVE` | `ACKNOWLEDGED` | `DISMISSED` | `RESOLVED`.
  let status: String
}

/// `PATCH /api/insights/{id}` answer — a BARE object (`ok()`), not the envelope.
struct HCCInsightStatusUpdate: Decodable {
  let id: String
  let status: String
}

/// `PUT /api/mobile/v1/devices/preferred` body.
///
/// Hand-encoded because `source` is nullable-but-required: the synthesized
/// encoder omits a nil optional, and an omitted key fails the server's schema,
/// which is exactly how "clear the override" would have silently 400'd.
struct HCCPreferredSourceBody: Encodable {
  let source: String?

  private enum CodingKeys: String, CodingKey { case source }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source, forKey: .source)
  }
}

struct HCCPreferredSourceResponse: Decodable {
  let preferredSource: String?
}

/// `PUT /api/mobile/v1/dashboard` body.
struct HCCDashboardTilesBody: Encodable {
  let tiles: [String]
}

/// `POST /api/mobile/v1/activities` body.
///
/// `startAt`/`endAt` are ISO instants WITH an offset (the route's zod requires
/// one) — `HCCTime.isoInstant` produces them.
struct HCCActivityCreate: Encodable {
  let type: String
  let startAt: String
  let endAt: String
  /// 1–10 perceived effort.
  let effort: Int
  var notes: String?
  var trainingSessionId: String?
}

/// `PATCH /api/mobile/v1/activities/{id}` body — every field optional, and an
/// omitted field means "leave it alone".
///
/// `notes` therefore cannot be CLEARED from the phone: the server accepts an
/// explicit null for it, but sending one would require distinguishing "absent"
/// from "null" per field, and no screen in this phase offers that. Editing the
/// text to something else works; emptying it does not.
struct HCCActivityPatch: Encodable {
  var type: String?
  var startAt: String?
  var endAt: String?
  var effort: Int?
  var notes: String?

  var isEmpty: Bool {
    type == nil && startAt == nil && endAt == nil && effort == nil && notes == nil
  }
}

/// `DELETE /api/mobile/v1/activities/{id}` answer.
struct HCCActivityDeleted: Decodable {
  let deleted: String
}

// ── /api/protocols ───────────────────────────────────────────────────────────

/// `GET /api/protocols` — a BARE object (`ok()`), not the mobile envelope.
struct HCCProtocolsResponse: Decodable {
  let protocols: [HCCProtocol]
}

/// One documented regimen. The DB row IS the authority for dose, status and
/// dates; this is a read of it and nothing here recomputes or restates them.
struct HCCProtocol: Decodable, Identifiable {
  let id: String
  let title: String
  /// `PEPTIDE` | `SUPPLEMENT` | `TRAINING` | `NUTRITION` | `LIFESTYLE` | `OTHER`.
  let category: String
  /// `PLANNED` | `ACTIVE` | `PAUSED` | `COMPLETED` | `ARCHIVED`.
  let status: String
  let summary: String?
  /// Markdown: what it is for and why.
  let rationale: String
  /// Markdown: the regimen itself.
  let details: String?
  let dose: String?
  let frequency: String?
  /// Administration route ("subcutaneous"), not a screen route.
  let route: String?
  let duration: String?
  /// Date-only, stored at UTC midnight; null when unscheduled.
  let startDate: String?
  let relatedMetricSlugs: [String]
  /// `HUMAN` | `AI` — who drafted it.
  let source: String
  let products: [HCCProtocolProduct]?
  let createdAt: String
  let updatedAt: String
}

struct HCCProtocolProduct: Decodable, Identifiable {
  let id: String
  let productId: String
  let amountPerDose: Double
  let dosesPerDay: Double
  let notes: String?
  let product: HCCProduct?
}

struct HCCProduct: Decodable, Identifiable {
  let id: String
  let name: String
  let unit: String?
  let category: String?
}

// ── /biomarkers ──────────────────────────────────────────────────────────────

/// `GET /api/mobile/v1/biomarkers` — the lab panels grouped by category.
///
/// Every row is graded against the app's OPTIMAL target (`optimalLow` /
/// `optimalHigh` on `HCCMetricView`), never a lab reference range. A value
/// outside them is "below target" or "above target".
struct HCCBiomarkerPanels: Decodable {
  let panels: [HCCBiomarkerPanel]
  /// How many rows carry an AI insight.
  let insightCount: Int
  /// How many of those insights are older than their metric's newest value.
  let staleCount: Int
}

struct HCCBiomarkerPanel: Decodable, Identifiable {
  /// `CARDIOVASCULAR`, `METABOLIC`, `HORMONAL`, …
  let category: String
  let metrics: [HCCMetricView]

  var id: String { category }
}

// ── /genetics ────────────────────────────────────────────────────────────────

/// `GET /api/mobile/v1/genetics` — the curated actionable variants for this
/// instance's owner. Static reference data; an empty array means no genome is
/// loaded for this instance, not "nothing found".
struct HCCGenetics: Decodable {
  let markers: [HCCGenomicMarker]
  let count: Int
}

struct HCCGenomicMarker: Decodable, Identifiable {
  let id: String
  let gene: String
  let rsid: String?
  let genotype: String
  /// False when the genotype was inferred rather than directly called.
  let called: Bool
  let tier: String
  let thread: String
  let headline: String
  /// Plain-language explanation.
  let interpretation: String
  /// What acting is worth and what not acting costs.
  let stakes: String
  let implication: String
  /// 0–1, how much acting on this variant is worth.
  let actionability: Double
  /// 0–1, how well supported the claim is.
  let evidence: Double
  let caveat: String?
}
