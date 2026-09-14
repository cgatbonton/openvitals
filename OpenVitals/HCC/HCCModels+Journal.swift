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
  /// The row's identity, decided SERVER-side. `protocolId|productId` for an
  /// ordinary row — byte-for-byte the string this app used to build for itself,
  /// so no existing row's identity moved when the field landed — and
  /// `protocolId|productId|slot` for one of the lines a pair SPLITS into.
  ///
  /// The split is why this exists (server `splitBySlots`, 2026-09-12): a dose
  /// line whose note names as many times of day as the day owes doses is now
  /// emitted as one row per time — Floratil and nitazoxanide, "Breakfast and
  /// dinner", arrive as a Morning row and a Dinner row off the same pair. The
  /// pair therefore stopped being unique, and two rows sharing an identity in a
  /// `ForEach` is one row on screen.
  ///
  /// Optional only because an older instance sends no key; see `id`.
  let key: String?
  let protocolId: String
  let protocolTitle: String
  /// What the row is called, decided SERVER-side: the product, or for a
  /// product-less regimen the headword of its title ("Fexofenadine (Allegra)",
  /// not the whole "… — daily H1 antihistamine, eczema itch"). Optional only
  /// because an older instance does not send it; see `doseTitle`.
  let label: String?
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
  /// Which section it belongs to: `peptide` | `prebreakfast` | `morning` |
  /// `lunch` | `dinner` | `prebed` | `anytime`. Mostly a time of day; `peptide`
  /// is a class of dose and leads the card. These are WIRE values and are not the
  /// headings: `morning` has rendered as "Breakfast" since 2026-09-13, and the
  /// raw value stays put so an older build never decodes an unknown slot.
  /// Derived SERVER-side from the dose link's note and the protocol's category, so this app and
  /// the web page bucket the schedule identically rather than each parsing the
  /// same prose. Decoded leniently — an older instance sends no slot at all.
  let slot: String?

  /// What the card identifies this row by: the server's `key`, with the old
  /// local formula standing in only for an instance too old to send one.
  ///
  /// `dosesCard`'s `ForEach` is keyed on this, so it is the thing that keeps the
  /// two halves of a split pair rendering as two rows. It is NOT how a log is
  /// matched to a row: a `DoseLog` carries no slot and belongs to the PAIR, so
  /// that lookup goes through `HCCJournalDay.logs(forProtocolId:productId:)`.
  var id: String { key ?? "\(protocolId)|\(productId ?? "")" }

  var isCycling: Bool { cadence == "cycling" }
}

/// The dose card's time-of-day sections, in the order they are taken.
///
/// A slot the server does not send, or one this build does not know, falls to
/// `anytime` — an unrecognised value must surface as unscheduled, never be
/// dropped from the card or filed under a meal it was not assigned to.
enum HCCDoseSlot: String, CaseIterable {
  // `peptide` is a CLASS, not a time of day, and it leads the card (Chris,
  // 2026-09-14). `allCases` order IS the section order — see `hccGroupDosesBySlot`.
  case peptide, prebreakfast, morning, lunch, dinner, prebed, anytime

  init(server: String?) {
    self = server.flatMap(HCCDoseSlot.init(rawValue:)) ?? .anytime
  }

  var label: String {
    switch self {
    // The injections, in one section of their own at the top (Chris, 2026-09-14).
    // Routed here SERVER-side by protocol category. A peptide dose with a
    // genuinely later time — the GH pre-bed pulse from 2026-09-23 — keeps its own
    // row in the evening rather than collapsing into this one.
    case .peptide: "Peptides"
    // The glass of water taken BEFORE food, ahead of the with-breakfast pills
    // (Chris, 2026-09-12). [SUPERSEDED 2026-09-14: it briefly held the morning
    // injections too, for one day, before they got their own section.]
    case .prebreakfast: "Pre-breakfast"
    // "Breakfast" since 2026-09-13. [SUPERSEDED: this read "Morning" while the
    // slot still held the morning-FASTED injections alongside the with-breakfast
    // supplements — "Breakfast" would have contradicted the instruction on half
    // its rows. The peptides moving to Pre-breakfast is what made it true.]
    case .morning: "Breakfast"
    case .lunch: "Lunch"
    case .dinner: "Dinner"
    case .prebed: "Pre-bed"
    case .anytime: "Anytime"
    }
  }
}

/// The due lines bucketed by slot, chronologically, with empty slots dropped —
/// an empty "Lunch" heading is furniture, and worse, reads as a missed dose.
func hccGroupDosesBySlot(_ due: [HCCDueDose]) -> [(slot: HCCDoseSlot, lines: [HCCDueDose])] {
  HCCDoseSlot.allCases.compactMap { slot in
    let lines = due.filter { HCCDoseSlot(server: $0.slot) == slot }
    return lines.isEmpty ? nil : (slot, lines)
  }
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

  /// The logs for one (protocol, product) PAIR, oldest first — `logs` arrives
  /// ordered by `takenAt`, so the newest to undo is the last one.
  ///
  /// The pair, not the row's `id`, and the distinction is load-bearing since the
  /// slot split: a log has no slot, so nothing on it could ever equal a split
  /// row's `protocolId|productId|dinner`. Matching on that key found no log and
  /// undo did nothing at all on the second half of every twice-daily line. The
  /// pair is read off the row's own fields rather than sliced back out of the
  /// key string, because the key's spelling is the server's to change.
  func logs(forProtocolId protocolId: String, productId: String?) -> [HCCDoseLog] {
    logs.filter { $0.protocolId == protocolId && $0.productId == productId }
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
///
/// `takenAt` is the instant of the TAP, not of the request. Without it the
/// server stamps the dose `now()` — the moment the POST is *received* — and a
/// request that leaves late files the dose on the wrong day. That is not
/// hypothetical: the session waits for connectivity rather than failing fast
/// (`HCCAPIClient`), so a dose ticked at bedtime on a dying connection, with the
/// phone then locked, was delivered when the app next came to the foreground the
/// following MORNING and recorded against that day. The owner opened the journal
/// to find the previous evening's Dinner and Pre-bed rows already checked, and
/// unchecking them deleted the real dose from the record (Chris, 2026-09-12).
/// ISO-8601 with a zone, which is what the route's `z.string().datetime()`
/// accepts and what the server parses straight into the timestamp.
struct HCCDoseLogBody: Encodable {
  let protocolId: String
  var productId: String?
  var amount: Double?
  var unit: String?
  var takenAt: String?
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
