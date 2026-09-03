import Foundation

// HCC: Wendler 5/3/1 — the program math, ported 1:1 from the server's
// `src/lib/fiveThreeOne.ts`.
//
// Why a port and not a payload: the server writes the prescribed `LiftSet` rows
// for a day the moment a session is created, and `GET /api/training` hands those
// back — so a STARTED day is always the server's numbers. A day that has NOT
// been started has no rows anywhere, and the web page renders its preview from
// exactly these functions. The phone shows the same previews, so it runs the
// same math rather than inventing a second definition of "what am I lifting".
//
// Rule for anyone editing this file: it is a mirror, not a source. If a number
// here disagrees with `fiveThreeOne.ts`, this file is wrong. The DEBUG
// self-check at the bottom exists to catch exactly that drift.

// ── Lifts ────────────────────────────────────────────────────────────────────

enum HCCLiftKey: String, Codable, CaseIterable, Hashable {
  case press = "PRESS"
  case squat = "SQUAT"
  case bench = "BENCH"
  case deadlift = "DEADLIFT"

  /// `LIFT_LABEL` — the one place a lift key becomes user copy.
  var label: String {
    switch self {
    case .press: "Military press"
    case .squat: "Squat"
    case .bench: "Bench"
    case .deadlift: "Deadlift"
    }
  }

  /// `TM_INCREMENT_KG` — upper body climbs half as fast as lower body.
  var tmIncrementKg: Double {
    switch self {
    case .press, .bench: 2.5
    case .squat, .deadlift: 5
    }
  }
}

enum HCCFiveThreeOne {
  // ── Constants ──────────────────────────────────────────────────────────────

  /// The bar itself. Everything below assumes a standard 20 kg Olympic bar.
  static let barKg: Double = 20

  /// Plate denominations available, largest first. The owner's gym has NO 25 kg
  /// plates AND no 1.25 kg plates, so both are deliberately absent.
  static let platesKg: [Double] = [20, 15, 10, 5, 2.5]

  /// `WEEK_LABEL`.
  static func weekLabel(_ week: Int) -> String {
    switch week {
    case 1: "3×5"
    case 2: "3×3"
    case 3: "5/3/1"
    default: "Deload"
    }
  }

  /// The program week is an `Int` column on the server; clamp on the way in so a
  /// bad row can never produce an undefined wave (mirrors the routes' own
  /// `clampWeek`).
  static func clampWeek(_ week: Int) -> Int {
    min(4, max(1, week))
  }

  // ── Weights ────────────────────────────────────────────────────────────────

  /// Round a computed percentage to the NEAREST 5 kg. Exact ties round DOWN
  /// (5/3/1 convention); the 1e-6 nudge is what makes round-half-up send ties
  /// down, small enough not to disturb non-ties.
  ///
  /// `Foundation.rounded()` is round-half-AWAY-from-zero, which matches JS
  /// `Math.round` for the non-negative weights this program produces.
  static func roundToPlate(_ kg: Double) -> Double {
    (kg / 5 - 1e-6).rounded() * 5
  }

  /// The three working sets for a given week, as percentages of the training
  /// max. Weeks 1–3 finish on an AMRAP; week 4 is three flat 60% sets, floored
  /// to 5 kg, and explicitly NOT an AMRAP.
  static func waveSets(tmKg: Double, week: Int) -> [HCCPrescribedSet] {
    if clampWeek(week) == 4 {
      let weight = (tmKg * 0.6 / 5).rounded(.down) * 5
      return (1...3).map { HCCPrescribedSet(setIndex: $0, weightKg: weight, reps: 5, isAmrap: false) }
    }
    let rows: [(pct: Double, reps: Int)]
    switch clampWeek(week) {
    case 1: rows = [(0.65, 5), (0.75, 5), (0.85, 5)]
    case 2: rows = [(0.7, 3), (0.8, 3), (0.9, 3)]
    default: rows = [(0.75, 5), (0.85, 3), (0.95, 1)]
    }
    return rows.enumerated().map { index, row in
      HCCPrescribedSet(
        setIndex: index + 1,
        weightKg: roundToPlate(tmKg * row.pct),
        reps: row.reps,
        isAmrap: index == rows.count - 1
      )
    }
  }

  /// Plates for ONE side of the bar, largest first. `nil` when the weight cannot
  /// be built (below the bar, or an unloadable remainder).
  static func platesPerSide(_ totalKg: Double) -> [Double]? {
    if totalKg < barKg - 1e-6 { return nil }
    var remaining = (totalKg - barKg) / 2
    var out: [Double] = []
    for plate in platesKg {
      while remaining >= plate - 1e-6 {
        out.append(plate)
        remaining -= plate
      }
    }
    return abs(remaining) < 1e-6 ? out : nil
  }

  /// Human-readable plate list: "—" when unloadable, "bar" when it's an empty bar.
  static func formatPlates(_ plates: [Double]?) -> String {
    guard let plates else { return "—" }
    if plates.isEmpty { return "bar" }
    return plates.map(formatKg).joined(separator: " · ")
  }

  /// Weights land on 2.5 kg boundaries; print them without trailing zeros
  /// (the server's `fmtKg`).
  static func formatKg(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded.rounded())) }
    return String(rounded)
  }

  /// Epley estimated 1RM — how an AMRAP becomes comparable across weeks running
  /// at different percentages.
  static func epleyE1rm(weightKg: Double, reps: Int) -> Double {
    if reps <= 0 { return weightKg }
    return (weightKg * (1 + Double(reps) / 30) * 10).rounded() / 10
  }

  /// The training max for the next cycle.
  static func nextTm(_ lift: HCCLiftKey, currentKg: Double) -> Double {
    currentKg + lift.tmIncrementKg
  }

  /// The program week and training maxes `weekOffset` calendar weeks from the
  /// one the cycle currently sits on. The wave runs 1→2→3→4 and rolls into a
  /// fresh cycle at week 1 with bumped maxes; maxes never rewind below the
  /// current cycle for past weeks.
  static func projectWave(
    anchorWeek: Int,
    tms: [HCCLiftKey: Double],
    weekOffset: Int
  ) -> (week: Int, tms: [HCCLiftKey: Double], cyclesAhead: Int) {
    let absIndex = clampWeek(anchorWeek) - 1 + weekOffset
    // JS `Math.floor` on a negative index floors toward −∞; Swift's integer
    // division truncates toward zero, so the floor is spelled out.
    let cyclesAhead = Int((Double(absIndex) / 4).rounded(.down))
    let week = ((absIndex % 4) + 4) % 4 + 1
    let bump = max(0, cyclesAhead)
    var projected = tms
    if bump > 0 {
      for (lift, value) in tms {
        projected[lift] = value + Double(bump) * lift.tmIncrementKg
      }
    }
    return (week, projected, cyclesAhead)
  }

  /// How a strength day is named, everywhere: the lifts in the order they run.
  static func strengthTitle(_ lifts: [HCCLiftKey]) -> String {
    lifts.map(\.label).joined(separator: " + ")
  }

  // ── The standing week ──────────────────────────────────────────────────────

  /// `WEEK_TEMPLATE` — two strength days, the rest conditioning. `dow` is
  /// Monday-first (0 = Monday).
  static let weekTemplate: [HCCDayTemplate] = [
    HCCDayTemplate(dow: 0, kind: .strength, title: "Squat + Bench", lifts: [.squat, .bench]),
    HCCDayTemplate(
      dow: 1,
      kind: .conditioning,
      title: "Norwegian 4×4",
      subtitle: "4 × 4 min @ 90–95% HRmax · 3 min recovery",
      options: [
        HCCDayOption(title: "Norwegian 4×4", subtitle: "4 × 4 min @ 90–95% HRmax · 3 min recovery"),
        HCCDayOption(title: "CrossFit", subtitle: "WOD"),
      ]
    ),
    HCCDayTemplate(dow: 2, kind: .conditioning, title: "Light cardio", subtitle: "Zone 2 · 45 min", optional: true),
    HCCDayTemplate(dow: 3, kind: .strength, title: "Deadlift + Press", lifts: [.deadlift, .press]),
    HCCDayTemplate(
      dow: 4,
      kind: .conditioning,
      title: "CrossFit",
      subtitle: "WOD",
      optional: true,
      options: [HCCDayOption(title: "CrossFit", subtitle: "WOD"), HCCDayOption(title: "Running")]
    ),
    HCCDayTemplate(dow: 5, kind: .conditioning, title: "Bouldering", subtitle: "Session"),
    HCCDayTemplate(dow: 6, kind: .conditioning, title: "Run club", subtitle: "Morning"),
  ]

  /// `dayOptionCatalog()` — everything a day can be set to, derived from the
  /// template so the picker can never offer something the rest of the screen
  /// cannot render, and never something the server's PUT would reject.
  static func dayOptionCatalog() -> [HCCDayChoice] {
    var pairings: [HCCDayChoice] = []
    var singles: [HCCLiftKey] = []
    var conditioning: [HCCDayChoice] = []
    var seen = Set<String>()

    func addConditioning(_ title: String, _ subtitle: String?) {
      if seen.contains(title) { return }
      seen.insert(title)
      conditioning.append(
        HCCDayChoice(key: "CONDITIONING:\(title)", option: .conditioning, title: title, subtitle: subtitle)
      )
    }

    for template in weekTemplate {
      if template.kind == .strength {
        let lifts = template.lifts
        let key = "STRENGTH:\(lifts.map(\.rawValue).joined(separator: "+"))"
        if lifts.count > 1, !pairings.contains(where: { $0.key == key }) {
          pairings.append(
            HCCDayChoice(key: key, option: .strength, title: strengthTitle(lifts), lifts: lifts)
          )
        }
        for lift in lifts where !singles.contains(lift) { singles.append(lift) }
      } else {
        addConditioning(template.title, template.subtitle)
        for option in template.options { addConditioning(option.title, option.subtitle) }
      }
    }

    return pairings
      + singles.map {
        HCCDayChoice(key: "STRENGTH:\($0.rawValue)", option: .strength, title: $0.label, lifts: [$0])
      }
      + conditioning
      + [HCCDayChoice(key: "REST", option: .rest, title: "Rest")]
  }

  // ── Day-key arithmetic ─────────────────────────────────────────────────────
  //
  // Every function here takes and returns the server's civil `YYYY-MM-DD` day
  // key and never touches a `Date` bucketed in the device zone — the same rule
  // the TypeScript keeps by doing its arithmetic on `Date.UTC` values. A day key
  // is a label the server assigned; these functions only walk the calendar
  // between labels, they never decide which label "now" carries (that is
  // `HealthDataStore.hccDayKey`, which goes through the instance zone).

  private static let dayKeyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }()

  static func date(fromDayKey key: String) -> Date? {
    let parts = key.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
      return nil
    }
    return dayKeyCalendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  static func dayKey(from date: Date) -> String {
    let parts = dayKeyCalendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func addDays(_ key: String, _ days: Int) -> String {
    guard let base = date(fromDayKey: key),
          let moved = dayKeyCalendar.date(byAdding: .day, value: days, to: base)
    else { return key }
    return dayKey(from: moved)
  }

  /// Monday = 0, matching `HCCDayTemplate.dow`.
  static func dow(_ key: String) -> Int {
    guard let day = date(fromDayKey: key) else { return 0 }
    // `Calendar.component(.weekday)` is 1 = Sunday.
    return (dayKeyCalendar.component(.weekday, from: day) + 5) % 7
  }

  /// Monday of the Mon–Sun week containing `key`.
  static func mondayOf(_ key: String) -> String {
    addDays(key, -dow(key))
  }

  /// The seven Monday-first day keys of the week starting `weekStart`.
  static func weekDates(_ weekStart: String) -> [String] {
    (0..<7).map { addDays(weekStart, $0) }
  }

  /// Whole weeks between two Monday keys (b − a).
  static func weeksBetween(_ a: String, _ b: String) -> Int {
    guard let start = date(fromDayKey: a), let end = date(fromDayKey: b) else { return 0 }
    return Int((end.timeIntervalSince(start) / (7 * 86_400)).rounded())
  }
}

// ── Value types ──────────────────────────────────────────────────────────────

struct HCCPrescribedSet: Hashable {
  let setIndex: Int
  let weightKg: Double
  let reps: Int
  let isAmrap: Bool
}

enum HCCDayOptionKind: String, Codable, Hashable {
  case strength = "STRENGTH"
  case conditioning = "CONDITIONING"
  case rest = "REST"
}

/// One selectable workout on a day that is a choice rather than a fixed session.
struct HCCDayOption: Hashable {
  let title: String
  var subtitle: String?

  init(title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }
}

struct HCCDayTemplate: Hashable {
  let dow: Int
  let kind: HCCDayOptionKind
  let title: String
  var lifts: [HCCLiftKey] = []
  var subtitle: String?
  var optional: Bool = false
  var options: [HCCDayOption] = []

  init(
    dow: Int,
    kind: HCCDayOptionKind,
    title: String,
    lifts: [HCCLiftKey] = [],
    subtitle: String? = nil,
    optional: Bool = false,
    options: [HCCDayOption] = []
  ) {
    self.dow = dow
    self.kind = kind
    self.title = title
    self.lifts = lifts
    self.subtitle = subtitle
    self.optional = optional
    self.options = options
  }
}

/// One entry in the day picker: what a day can be set to.
struct HCCDayChoice: Identifiable, Hashable {
  /// Stable identity for the picker and for `TrainingDayPlan` round-trips.
  let key: String
  let option: HCCDayOptionKind
  let title: String
  var subtitle: String?
  /// STRENGTH only — the lifts of the day, in the order they run.
  var lifts: [HCCLiftKey] = []

  var id: String { key }

  init(key: String, option: HCCDayOptionKind, title: String, subtitle: String? = nil, lifts: [HCCLiftKey] = []) {
    self.key = key
    self.option = option
    self.title = title
    self.subtitle = subtitle
    self.lifts = lifts
  }
}

// ── Drift check ──────────────────────────────────────────────────────────────

#if DEBUG
/// Prints the ported math for the inputs the workstream spec names, so the same
/// inputs can be run through `src/lib/fiveThreeOne.ts` in node and the two
/// outputs diffed line for line.
///
/// There is no XCTest target in this project, so this is the verification: run
/// the app with `HCC_DEBUG_531_CHECK=1` and compare the block it prints with the
/// node run. It computes nothing the app does not, and writes nothing anywhere.
enum HCCFiveThreeOneSelfCheck {
  static var isRequested: Bool {
    ProcessInfo.processInfo.environment["HCC_DEBUG_531_CHECK"] == "1"
  }

  static func runIfRequested() {
    guard isRequested else { return }
    for line in lines() { print(line) }
  }

  static func lines() -> [String] {
    var out: [String] = ["531CHECK BEGIN"]

    for week in 1...4 {
      let sets = HCCFiveThreeOne.waveSets(tmKg: 120, week: week)
      let rendered = sets
        .map { "\($0.setIndex):\(HCCFiveThreeOne.formatKg($0.weightKg))x\($0.reps)\($0.isAmrap ? "+" : "")" }
        .joined(separator: " ")
      out.append("waveSets(120,\(week)) \(rendered)")
    }

    for weight in [97.5, 100.0, 20.0, 17.5] {
      let plates = HCCFiveThreeOne.platesPerSide(weight)
      let raw = plates.map { $0.map(HCCFiveThreeOne.formatKg).joined(separator: ",") } ?? "nil"
      out.append("platesPerSide(\(HCCFiveThreeOne.formatKg(weight))) \(raw) | \(HCCFiveThreeOne.formatPlates(plates))")
    }

    out.append("epleyE1rm(85,7) \(HCCFiveThreeOne.epleyE1rm(weightKg: 85, reps: 7))")

    for lift in [HCCLiftKey.press, .squat, .bench, .deadlift] {
      let base: Double = [HCCLiftKey.press: 60, .squat: 120, .bench: 80, .deadlift: 150][lift] ?? 0
      out.append(
        "nextTm(\(lift.rawValue),\(HCCFiveThreeOne.formatKg(base))) "
          + HCCFiveThreeOne.formatKg(HCCFiveThreeOne.nextTm(lift, currentKg: base))
      )
    }

    let tms: [HCCLiftKey: Double] = [.press: 60, .squat: 120, .bench: 80, .deadlift: 150]
    for anchor in 1...4 {
      let projected = HCCFiveThreeOne.projectWave(anchorWeek: anchor, tms: tms, weekOffset: 2)
      let rendered = [HCCLiftKey.press, .squat, .bench, .deadlift]
        .map { "\($0.rawValue)=\(HCCFiveThreeOne.formatKg(projected.tms[$0] ?? 0))" }
        .joined(separator: ",")
      out.append("projectWave(\(anchor),+2) week=\(projected.week) cycles=\(projected.cyclesAhead) \(rendered)")
    }
    // The negative offset the strip never reaches but the formula must still
    // floor correctly (JS Math.floor vs Swift's truncating division).
    let back = HCCFiveThreeOne.projectWave(anchorWeek: 1, tms: tms, weekOffset: -2)
    out.append("projectWave(1,-2) week=\(back.week) cycles=\(back.cyclesAhead)")

    let catalog = HCCFiveThreeOne.dayOptionCatalog()
    out.append("dayOptionCatalog n=\(catalog.count)")
    for choice in catalog {
      out.append("  \(choice.key) | \(choice.title) | \(choice.subtitle ?? "-")")
    }

    out.append("mondayOf(2026-09-03) \(HCCFiveThreeOne.mondayOf("2026-09-03"))")
    out.append("addDays(2026-08-31,7) \(HCCFiveThreeOne.addDays("2026-08-31", 7))")
    out.append("dow(2026-09-03) \(HCCFiveThreeOne.dow("2026-09-03"))")
    out.append("weeksBetween(2026-08-31,2026-09-14) \(HCCFiveThreeOne.weeksBetween("2026-08-31", "2026-09-14"))")

    out.append("531CHECK END")
    return out
  }
}
#endif
