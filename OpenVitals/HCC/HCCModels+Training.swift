import Foundation

// HCC: DTOs for the Training tab.
//
// `GET /api/training` is the serialised `TrainingData` the web page hands
// `TrainingClient` — same field names, every `Date` already flattened to a civil
// `YYYY-MM-DD` day key by the server. Nothing here re-buckets a date: a day key
// arrives as a string and stays one.
//
// The write routes are the app's own web routes, so they answer with a bare
// `ok()` object rather than the `/api/mobile/v1` envelope.

// ── Read ─────────────────────────────────────────────────────────────────────

struct HCCTrainingSet: Codable, Identifiable, Hashable {
  let id: String
  let lift: HCCLiftKey
  let setIndex: Int
  let targetWeightKg: Double
  let targetReps: Int
  let isAmrap: Bool
  let actualReps: Int?

  /// The prescription this row carries, for the renderers that draw a stored set
  /// and a generated one the same way.
  var prescribed: HCCPrescribedSet {
    HCCPrescribedSet(setIndex: setIndex, weightKg: targetWeightKg, reps: targetReps, isAmrap: isAmrap)
  }
}

struct HCCTrainingSession: Codable, Identifiable, Hashable {
  let id: String
  let dateYmd: String
  let kind: HCCTrainingSessionKind
  let title: String
  let status: HCCTrainingSessionStatus
  /// The program week this session was prescribed for — which, for a day started
  /// from a future week, is ahead of where the cycle sits.
  let week: Int?
  let notes: String?
  let sets: [HCCTrainingSet]
}

enum HCCTrainingSessionKind: String, Codable, Hashable {
  case strength = "STRENGTH"
  case conditioning = "CONDITIONING"
}

enum HCCTrainingSessionStatus: String, Codable, Hashable {
  case planned = "PLANNED"
  case done = "DONE"
  case skipped = "SKIPPED"
}

struct HCCTrainingCycle: Codable, Hashable {
  let id: String
  let number: Int
  let week: Int
  let tms: [String: Double]

  func tm(_ lift: HCCLiftKey) -> Double? { tms[lift.rawValue] }

  var tmsByLift: [HCCLiftKey: Double] {
    var out: [HCCLiftKey: Double] = [:]
    for lift in HCCLiftKey.allCases { out[lift] = tms[lift.rawValue] }
    return out.compactMapValues { $0 }
  }
}

struct HCCLiftAmrap: Codable, Hashable {
  let weightKg: Double
  let reps: Int
  let dateYmd: String
}

struct HCCLiftE1rmPoint: Codable, Hashable {
  let dateYmd: String
  let e1rmKg: Double
}

/// The strength trajectory of one lift, derived entirely from AMRAP sets — the
/// only sets in 5/3/1 that measure capacity rather than prescribe it.
struct HCCLiftHistory: Codable, Hashable {
    let bestE1rmKg: Double?
    let lastAmrap: HCCLiftAmrap?
    let points: [HCCLiftE1rmPoint]
}

/// A day of the resolved week: the owner's pick, else the shape of the last week
/// he trained, else the built-in template, else rest. Resolution happens on the
/// server — it is the only side that sees the stored plan rows — so the phone
/// renders `source` rather than deriving it.
struct HCCResolvedDay: Codable, Identifiable, Hashable {
  let date: String
  let option: HCCDayOptionKind
  let lifts: [HCCLiftKey]
  let title: String
  let subtitle: String?
  let source: HCCPlanSource
  /// Template days that may be skipped without it counting as a missed day.
  let optional: Bool

  var id: String { date }
}

enum HCCPlanSource: String, Codable, Hashable {
  case user = "USER"
  case inherited = "INHERITED"
  case template = "TEMPLATE"
  case restDefault = "REST_DEFAULT"
}

struct HCCTrainingData: Codable {
  let cycle: HCCTrainingCycle?
  let todayYmd: String
  let weekStartYmd: String
  /// A window of sessions spanning many weeks; the strip slices it per week.
  let sessions: [HCCTrainingSession]
  let cycleSessions: [HCCTrainingSession]
  let liftHistory: [String: HCCLiftHistory]
  let weekPlan: [HCCResolvedDay]
  let nextWeekPlan: [HCCResolvedDay]

  func history(_ lift: HCCLiftKey) -> HCCLiftHistory? { liftHistory[lift.rawValue] }

  func sessions(on dayKey: String) -> [HCCTrainingSession] {
    sessions.filter { $0.dateYmd == dayKey }
  }
}

// ── Writes ───────────────────────────────────────────────────────────────────

/// `PUT /api/training/plan`. `lifts` is sent for STRENGTH only and `title` for
/// CONDITIONING only — the route rejects a title it does not find in its own
/// catalog, so the picker never sends free text.
struct HCCTrainingPlanBody: Encodable {
  let date: String
  let option: String
  let lifts: [String]?
  let title: String?
}

/// The whole re-resolved week comes back, because one pick also re-shapes every
/// later week that was inheriting from this one.
struct HCCTrainingPlanResponse: Decodable {
  let weekStart: String
  let weekPlan: [HCCResolvedDay]
}

/// `POST /api/training/sessions`. `week` is the week the phone previewed, which
/// for a future calendar week is ahead of where the cycle sits.
struct HCCTrainingSessionCreate: Encodable {
  let date: String
  let kind: String
  var title: String?
  var lifts: [String]?
  var week: Int?
  var status: String?
}

/// `PATCH /api/training/sessions/{id}`. Every field is optional; `notes` is
/// nullable-and-optional, so it is encoded by hand — an absent note and a
/// cleared one are different requests and `nil` must not silently drop the key.
struct HCCTrainingSessionPatch: Encodable {
  var status: String?
  var title: String?
  var notes: String??

  private enum CodingKeys: String, CodingKey {
    case status, title, notes
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(status, forKey: .status)
    try container.encodeIfPresent(title, forKey: .title)
    if let notes {
      // `.some(nil)` means "clear the note" and must reach the server as null.
      try container.encode(notes, forKey: .notes)
    }
  }
}

struct HCCTrainingSessionAck: Decodable {
  let session: HCCTrainingSession
}

/// `PATCH /api/training/sets/{id}`. `null` clears the set back to un-performed.
struct HCCTrainingSetPatch: Encodable {
  let actualReps: Int?
}

struct HCCTrainingSetAck: Decodable {
  let set: HCCTrainingSet
}

/// `POST /api/training/cycle` — the discriminated control surface. Only the
/// actions this screen offers are modelled; `updateTms` is a web-page action
/// (the phone never edits a training max by hand) and is deliberately absent.
struct HCCTrainingCycleBody: Encodable {
  let action: String
  var week: Int?
}

/// The route answers with the whole Prisma row; only the fields the screen would
/// need are declared, and the screen re-reads `/api/training` anyway because a
/// cycle change moves the week, the maxes and every preview at once.
struct HCCTrainingCycleAck: Decodable {
  struct Row: Decodable {
    let id: String
    let number: Int
    let week: Int
  }

  let cycle: Row
}
