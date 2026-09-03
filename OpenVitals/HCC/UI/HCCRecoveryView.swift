import SwiftUI

/// `S.recovery` — the recovery detail screen.
///
/// Everything on it is the server's: the score and its band, the day's HRV /
/// resting HR / respiratory rate, the baselines those are compared against, and
/// the fourteen days of history. The only arithmetic done on the phone is the
/// z-score — `(value − baseline mean) / baseline SD` — and it is drawn only when
/// BOTH halves of that division came from the server for the day being shown.
/// A day with no reading gets no bar, never a bar at zero.
struct HCCRecoveryView: View {
  @ObservedObject var store: HealthDataStore
  /// The server day key to show. `nil` follows whatever day the store last read,
  /// which is what a tap through from Home means.
  var dayKey: String?

  @State private var isEnsuringDay = false

  init(store: HealthDataStore, dayKey: String? = nil) {
    self.store = store
    self.dayKey = dayKey
  }

  init(store: HealthDataStore, date: Date) {
    self.init(store: store, dayKey: HealthDataStore.hccDayKey(date))
  }

  private var day: String { dayKey ?? store.hcc.lastRequestedDay ?? HealthDataStore.hccDayKey(Date()) }
  private var home: HCCHome? { store.hcc.homeByDate[day] }
  private var score: HCCHomeScore? { home?.score("recovery") }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Recovery", subtitle: subtitle)
      hero
      whatMovedIt
      history
    }
    .task(id: day) { await ensureDayLoaded() }
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  /// "Aug 25 · Fitbit · computed" in the mockup: the day, the wrist the server
  /// is believing, and which engine produced the number. Every part is dropped
  /// rather than guessed when the server did not say.
  private var subtitle: String {
    var parts = [HealthDataStore.hccDayLabel(day)]
    // The server's device label names a manufacturer; the fork's copy rule does
    // not (AGENTS.md), so it goes through the same neutral map as everything
    // else that comes off the wire.
    if let device = store.hccDrivingDevice().map({ HCCCopy.sourceLabel($0.source) }), !device.isEmpty {
      parts.append(device)
    }
    switch score?.origin {
    case "computed": parts.append("computed")
    case "whoop": parts.append("band")
    default: break
    }
    if score?.stale == true { parts.append("stale") }
    // The neutral device label and the origin word can both come out as "band";
    // "Aug 25 · band · band" is noise, not two facts.
    var seen = Set<String>()
    return parts.filter { seen.insert($0.lowercased()).inserted }.joined(separator: " · ")
  }

  // ── Hero ───────────────────────────────────────────────────────────────────

  private var band: HCCRecoveryBand? {
    guard let value = scoreValue else { return nil }
    return HCCRecoveryBand.band(for: value, bands: store.hcc.instance?.scoreBands.recovery)
  }

  /// The number, or nil when the server is calibrating or has none. There is no
  /// third case: a calibrating score is not a small score.
  private var scoreValue: Double? {
    guard let score, !score.calibrating else { return nil }
    return score.value
  }

  @ViewBuilder
  private var hero: some View {
    VStack(spacing: 6) {
      HCCRing(
        progress: (scoreValue ?? 0) / 100,
        kind: .rec,
        size: 176,
        stroke: 11,
        ticks: true,
        value: scoreValue.map { HCCFormat.decimal($0, 0) },
        unit: "%",
        sub: band?.word.uppercased(),
        // The recovery orb's colour IS part of the reading (D-A1): the band
        // chooses the gradient, and no band draws the muted pair rather than a
        // green ring around a score nobody produced.
        band: band
      )
      if let band {
        HCCPill(band.word, color: band.color)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 6)
    .padding(.bottom, 2)

    if scoreValue == nil {
      HCCErrorNote(unavailableReason, title: "No score")
    }
  }

  private var unavailableReason: String {
    if let reason = HealthDataStore.hccNeutralCopy(score?.reason) { return reason }
    if score?.calibrating == true { return "Your Command Center is still calibrating this score." }
    if store.hcc.homeByDate[day] == nil {
      return store.hcc.lastError ?? "This day has not been read yet."
    }
    return "Your Command Center has no recovery score for this day."
  }

  // ── What moved it ──────────────────────────────────────────────────────────

  private var whatMovedIt: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("What moved it", size: 11)
      ForEach(factRows) { row in
        FactRow(row: row)
      }
      if factRows.isEmpty {
        HCCEmptyNote("No vitals on record for this day.")
      } else {
        HCCFootnote(baselineFootnote)
          .padding(.top, 4)
      }
    }
    .hccCard()
  }

  /// The mockup's sentence, with the baseline's real length substituted where
  /// the server published one — "30-day" is the default window, not a promise.
  private var baselineFootnote: String {
    let nights = store.hcc.vitals.compactMap { $0.baseline?.n }.max()
    guard let nights else {
      return "Bars are z-scores against the baseline, computed on the server."
    }
    return "Bars are z-scores against the \(nights)-day baseline, computed on the server."
  }

  /// HRV, resting HR, respiratory rate and sleep performance, in the mockup's
  /// order. A stream with no reading for THIS day is left out entirely.
  private var factRows: [FactRowModel] {
    var rows: [FactRowModel] = []

    if let hrv = vitalRow(slug: HCCVitalSlug.hrv, label: "HRV", higherIsBetter: true) {
      rows.append(hrv)
    }
    if let rhr = vitalRow(slug: HCCVitalSlug.restingHR, label: "Resting HR", higherIsBetter: false) {
      rows.append(rhr)
    }
    if let resp = vitalRow(slug: HCCVitalSlug.respiratoryRate, label: "Resp rate", higherIsBetter: false) {
      rows.append(resp)
    }
    if let sleep = sleepPerformanceRow() {
      rows.append(sleep)
    }
    return rows
  }

  /// One vital: the value the server bucketed on THIS day, and its z against the
  /// server's own baseline mean and SD.
  ///
  /// The day match is exact. Falling back to `latest` would print today's HRV
  /// under a date three days ago, which is the single most misleading thing this
  /// screen could do.
  private func vitalRow(slug: String, label: String, higherIsBetter: Bool) -> FactRowModel? {
    guard let series = store.hcc.vitals.first(where: { $0.slug == slug }),
          let point = series.series.last(where: { $0.t == day })
    else {
      return nil
    }
    let digits = HCCVitalSlug.fractionDigits(slug)
    var z: Double?
    if let baseline = series.baseline, baseline.sd > 0 {
      let raw = (point.value - baseline.mean) / baseline.sd
      z = higherIsBetter ? raw : -raw
    }
    return FactRowModel(
      key: label,
      value: HCCFormat.measurement(point.value, unit: series.unit, fractionDigits: digits),
      z: z
    )
  }

  /// Sleep performance against the mean and SD of the window `/scores` returned.
  private func sleepPerformanceRow() -> FactRowModel? {
    let history = store.hcc.scoreDays.compactMap { $0.sleepPerformance?.value }
    let dayValue = store.hcc.scoreDays.first { $0.date == day }?.sleepPerformance?.value
      ?? (day == home?.date ? home?.score("sleep").flatMap { $0.calibrating ? nil : $0.value } : nil)
    guard let dayValue else { return nil }

    var z: Double?
    if history.count >= 2 {
      let mean = history.reduce(0, +) / Double(history.count)
      let variance = history.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(history.count - 1)
      let sd = variance.squareRoot()
      if sd > 0 { z = (dayValue - mean) / sd }
    }
    return FactRowModel(key: "Sleep perf", value: "\(HCCFormat.decimal(dayValue, 0))%", z: z)
  }

  // ── History ────────────────────────────────────────────────────────────────

  private var recoveryHistory: [(date: String, value: Double)] {
    store.hcc.scoreDays.compactMap { scoreDay in
      guard let recovery = scoreDay.recovery else { return nil }
      return (scoreDay.date, recovery.value)
    }
    .suffix(14)
    .map { $0 }
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Last \(max(recoveryHistory.count, 1)) days", size: 11)
      if recoveryHistory.isEmpty {
        HCCEmptyNote("No scored days on record yet.")
      } else {
        HCCBars(
          values: recoveryHistory.map(\.value),
          max: 100,
          color: { value in
            HCCRecoveryBand.band(for: value, bands: store.hcc.instance?.scoreBands.recovery).color
          }
        )
        HCCAxis(
          leading: HCCFormat.shortDay(recoveryHistory.first?.date),
          trailing: trailingAxisLabel
        )
      }
    }
    .hccCard()
  }

  private var trailingAxisLabel: String {
    guard let last = recoveryHistory.last?.date else { return "" }
    return last == HealthDataStore.hccDayKey(Date()) ? "today" : HCCFormat.shortDay(last)
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  /// A deep link can land here before Home has read this day. Only asks when the
  /// day really is missing, so the usual tap-through costs nothing.
  private func ensureDayLoaded() async {
    guard store.hcc.homeByDate[day] == nil, !isEnsuringDay else { return }
    isEnsuringDay = true
    defer { isEnsuringDay = false }
    await store.refreshFromHCC(date: HealthDataStore.hccLocalDate(fromDayKey: day))
  }
}

// ── Fact row ─────────────────────────────────────────────────────────────────

private struct FactRowModel: Identifiable {
  let key: String
  let value: String
  /// nil when the server published no baseline to compare against — the row
  /// still shows its value, but no bar is drawn for a comparison nobody made.
  let z: Double?

  var id: String { key }
}

/// `.fact` — label, deviation bar, value.
private struct FactRow: View {
  let row: FactRowModel

  var body: some View {
    HStack(spacing: 10) {
      Text(row.key)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .frame(width: 70, alignment: .leading)

      if let z = row.z {
        HCCZScoreBar(z: z)
          .frame(maxWidth: .infinity)
      } else {
        Text("no baseline yet")
          .font(HCCTheme.Font.data(size: 10))
          .foregroundStyle(HCCTheme.Color.muted)
          .frame(maxWidth: .infinity, alignment: .center)
      }

      Text(row.value)
        .font(HCCTheme.Font.data(size: 12.5))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 92, alignment: .trailing)
    }
    .padding(.vertical, 2)
  }
}
