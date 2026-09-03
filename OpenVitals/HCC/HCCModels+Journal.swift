import Foundation

// HCC: the Journal tab's DTOs. Shapes come from the web routes under
// `/api/journal/*`, which answer with `ok()` — a bare object, not the read
// API's `{data, generatedAt, instance}` envelope — so every call in
// `HCCAPIClient+Journal.swift` uses the bare path.
//
// Server sources of truth for these shapes: `src/lib/journal/day.ts`
// (`JournalBehaviorDTO`, `JournalEntryDTO`, `DoseLogDTO`, `JournalDayDTO`,
// `LogDoseResult`, `ImpactsDTO`), `src/lib/journal/doses.ts` (`DueDose`) and
// `src/lib/journal/impacts.ts` (`BehaviorImpact`, `MetricImpact`).

// ── The day form ─────────────────────────────────────────────────────────────

/// One thing the owner answers about a day.
///
/// `kind` decides the control: a BOOLEAN behavior is a yes/no switch, a NUMBER
/// behavior a stepper in `unit`. An unrecognised kind decodes as BOOLEAN rather
/// than failing the whole day — a server that adds a third kind should cost the
/// phone one mis-drawn row, not the entire screen.
struct HCCJournalBehavior: Decodable, Identifiable, Equatable {
  enum Kind: String, Decodable {
    case boolean = "BOOLEAN"
    case number = "NUMBER"
  }

  let id: String
  let slug: String
  let label: String
  let category: String
  let kind: Kind
  let unit: String?
  let sortOrder: Int
  let archived: Bool

  private enum CodingKeys: String, CodingKey {
    case id, slug, label, category, kind, unit, sortOrder, archived
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    slug = try container.decode(String.self, forKey: .slug)
    label = try container.decode(String.self, forKey: .label)
    category = try container.decode(String.self, forKey: .category)
    kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .boolean
    unit = try container.decodeIfPresent(String.self, forKey: .unit)
    sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    archived = try container.decode(Bool.self, forKey: .archived)
  }
}

/// One answer on one day.
///
/// A behavior with NO entry is unanswered, which is not the same as a "no" —
/// the server deletes the row when both values are cleared for exactly that
/// reason (`upsertJournalDay`), and the impact maths only counts logged days.
struct HCCJournalEntry: Decodable, Equatable {
  let behaviorId: String
  let slug: String
  let valueBool: Bool?
  let valueNum: Double?
  let notes: String?
}

/// A dose the day owes, derived by the server from the ACTIVE protocols.
///
/// `doseText` is the protocol's free-text regimen and is shown verbatim; it is
/// never parsed into a number. `amount`/`unit` are the structured draw a
/// product supplies. Exactly one of the two carries the dose.
struct HCCDueDose: Decodable, Equatable, Identifiable {
  let protocolId: String
  let protocolTitle: String
  let productId: String?
  let productName: String?
  let unit: String?
  let amount: Double?
  let doseText: String?
  let dueCount: Int
  let takenCount: Int
  let expectedPerDay: Double
  /// `daily` or `cycling`. A cycling product skips days by design, so a blank
  /// day on one must not read as a missed dose.
  let cadence: String

  /// The (protocol, product) pair a dose belongs to. The server keys taken
  /// counts on the same pair, so this is the one identity the UI needs.
  var id: String { "\(protocolId)|\(productId ?? "")" }

  var isCycling: Bool { cadence == "cycling" }
}

/// A dose that was actually taken.
struct HCCDoseLog: Decodable, Equatable, Identifiable {
  let id: String
  let protocolId: String
  let protocolTitle: String
  let productId: String?
  let productName: String?
  let amount: Double
  let unit: String
  let takenAt: String
  let notes: String?
  let inventoryDepleted: Bool

  /// Same pairing as `HCCDueDose.id`, so a log can be matched to its due line.
  var dueKey: String { "\(protocolId)|\(productId ?? "")" }
}

/// `GET /api/journal/day/{date}` and `PUT` of the same path both answer with
/// the whole day, so one type covers the read and the reconcile after a write.
struct HCCJournalDay: Decodable, Equatable {
  let date: String
  let behaviors: [HCCJournalBehavior]
  let entries: [HCCJournalEntry]
  let due: [HCCDueDose]
  let logs: [HCCDoseLog]

  /// The behaviors the screen draws: archived ones stay in the payload (the
  /// server sends the whole catalog) and are hidden here, in `sortOrder`.
  var visibleBehaviors: [HCCJournalBehavior] {
    behaviors.filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
  }

  func entry(behaviorId: String) -> HCCJournalEntry? {
    entries.first { $0.behaviorId == behaviorId }
  }

  /// The logs for one due line, oldest first — `logs` arrives ordered by
  /// `takenAt`, so the newest to undo is the last one.
  func logs(forDueKey key: String) -> [HCCDoseLog] {
    logs.filter { $0.dueKey == key }
  }
}

struct HCCJournalDayResponse: Decodable {
  let day: HCCJournalDay
}

// ── Writes ───────────────────────────────────────────────────────────────────

/// One entry in the `PUT /api/journal/day/{date}` body.
///
/// Both values `nil` means "clear this answer": the server treats an absent key
/// and an explicit null identically (`input.valueBool ?? null`) and deletes the
/// row, which is what turns a "no" back into "unanswered".
struct HCCJournalEntryInput: Encodable {
  let behaviorId: String
  var valueBool: Bool?
  var valueNum: Double?
  var notes: String?
}

struct HCCJournalDayBody: Encodable {
  let entries: [HCCJournalEntryInput]
}

/// `POST /api/journal/doses`. Amount and unit are sent from the due line so the
/// server draws the same stock the protocol declares; omitting them would make
/// the server re-derive them, which is the same answer by a longer road.
struct HCCDoseLogBody: Encodable {
  let protocolId: String
  var productId: String?
  var amount: Double?
  var unit: String?
}

/// `POST /api/journal/doses` → the created log, whether stock was drawn down,
/// and a sentence when the dose was recorded but stock deliberately was not
/// touched (a unit mismatch, an empty container).
struct HCCDoseLogResult: Decodable {
  let log: HCCDoseLog
  let inventoryDepleted: Bool
  let warning: String?
}

struct HCCDoseDeleted: Decodable {
  let id: String
}

// ── Impacts ──────────────────────────────────────────────────────────────────

/// One behavior's effect on one next-day metric.
///
/// `delta` is `yes − no`, raw: for resting heart rate a positive delta is the
/// unwanted direction. The screen only reads the recovery entry, where up is
/// the good direction.
struct HCCImpactMetric: Decodable, Equatable {
  let yes: Double?
  let no: Double?
  let delta: Double?
  let nYes: Int
  let nNo: Int
}

/// One row of `GET /api/journal/impacts`.
///
/// `metrics` is the server's `Record<ImpactMetric, MetricImpact>` — the keys
/// are `recovery`, `hrv`, `rhr` and `sleepPerf`, and the recovery entry is
/// already resolved from `hcc_recovery` then `whoop_recovery` server-side, so
/// the phone never picks a slug itself.
struct HCCImpactRow: Decodable, Equatable, Identifiable {
  let slug: String
  let label: String
  let category: String
  let nYes: Int
  let nNo: Int
  let eligible: Bool
  let moreYesNeeded: Int
  let moreNoNeeded: Int
  let metrics: [String: HCCImpactMetric]

  var id: String { slug }

  /// The metric this card is about. Named once here so the key string is not
  /// spelled out at each use site.
  static let recoveryKey = "recovery"

  var recovery: HCCImpactMetric? { metrics[Self.recoveryKey] }

  /// How many more logged days the row still needs before it says anything.
  var moreNeeded: Int { moreYesNeeded + moreNoNeeded }
}

struct HCCJournalImpacts: Decodable, Equatable {
  let from: String
  let to: String
  let days: Int
  /// The server's gate — 5 yes and 5 no days. Read rather than hardcoded so
  /// the footnote cannot drift from the rule the numbers were computed under.
  let minDays: Int
  let impacts: [HCCImpactRow]

  /// Eligible rows first, each side ordered by how big the recovery difference
  /// is; a row with no recovery delta sorts last within its group.
  var sortedRows: [HCCImpactRow] {
    let magnitude: (HCCImpactRow) -> Double = { abs($0.recovery?.delta ?? 0) }
    return impacts.sorted { lhs, rhs in
      if lhs.eligible != rhs.eligible { return lhs.eligible }
      if magnitude(lhs) != magnitude(rhs) { return magnitude(lhs) > magnitude(rhs) }
      return lhs.label < rhs.label
    }
  }
}
