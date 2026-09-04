import SwiftUI

/// `S.strain` — the strain detail screen.
///
/// The mockup draws an intraday climb curve. The read API has no intraday strain
/// series — only the day's resolved score and its target — so that card is not
/// drawn at all. It is replaced by the one honest thing those two numbers
/// support: a bar of the score against the target, with the origin chip and the
/// mockup's footnote. A curve through a single point would be a fabrication of
/// the most convincing kind, and an empty chart frame is only slightly less so.
struct HCCStrainView: View {
  @ObservedObject var store: HealthDataStore
  var dayKey: String?

  @State private var route: HCCDetailRoute?
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
  private var score: HCCHomeScore? { home?.score("strain") }

  private var strain: Double? {
    guard let score, !score.calibrating else { return nil }
    return score.value
  }

  /// Today's target, from today's recovery. Null is a real answer — a day with
  /// no recovery has no target, and 13.5 is the mockup's sample, not a default.
  private var target: Double? {
    home?.strainTarget ?? store.hcc.scoreDays.first { $0.date == day }?.strainTarget
  }

  private var scaleMax: Double { store.hcc.instance?.scoreBands.strain.max ?? HCCTheme.strainMax }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Strain", subtitle: subtitle)
      hero
      climb
      activities
      history
    }
    .task(id: day) { await ensureDayLoaded() }
    .sheet(item: $route) { HCCDetailRouteSheet(route: $0, store: store) }
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  /// "Aug 25 · WHOOP · co-wear" while a wrist is driving the number, "Aug 25 ·
  /// computed" once the server's own engine is.
  private var subtitle: String {
    let dayLabel = HealthDataStore.hccDayLabel(day)
    switch score?.origin {
    case "whoop": return "\(dayLabel) · \(HCCCopy.originLabel("whoop")) · co-wear"
    case "computed": return "\(dayLabel) · computed"
    default: return dayLabel
    }
  }

  // ── Hero ───────────────────────────────────────────────────────────────────

  @ViewBuilder
  private var hero: some View {
    HCCRing(
      progress: (strain ?? 0) / scaleMax,
      kind: .strain,
      size: 160,
      stroke: 11,
      ticks: true,
      value: strain.map { HCCFormat.decimal($0, 1) },
      sub: target.map { "TARGET \(HCCFormat.decimal($0, 1))" },
      target: target.map { min(max($0 / scaleMax, 0), 1) }
    )
    .frame(maxWidth: .infinity)
    .padding(.top, 6)
    .padding(.bottom, 2)

    if strain == nil {
      HCCErrorNote(
        HealthDataStore.hccNeutralCopy(score?.reason)
          ?? store.hcc.lastError
          ?? "Your Command Center has no strain score for this day.",
        title: "No score"
      )
    }
  }

  // ── Today's climb ──────────────────────────────────────────────────────────

  /// light / moderate / high at the mockup's 10 and 14 cutoffs.
  private var effortWord: String? {
    guard let strain else { return nil }
    if strain >= 14 { return "high" }
    if strain >= 10 { return "moderate" }
    return "light"
  }

  /// "WHOOP" while a wrist is driving the number, "computed" once the server's
  /// own engine is. Nothing is shown when the server named no origin.
  private var originWord: String? {
    switch score?.origin {
    case "whoop": HCCCopy.originLabel("whoop")
    case "computed": "computed"
    default: nil
    }
  }

  /// "11.4 / 13.5" — where the day sits against its target, both in the data
  /// face. Either half is "--" on its own when the server has no value for it.
  private var progressText: String {
    let value = strain.map { HCCFormat.decimal($0, 1) } ?? HCCFormat.placeholder
    guard let target else { return value }
    return "\(value) / \(HCCFormat.decimal(target, 1))"
  }

  /// The mockup's intraday climb curve is deliberately absent: the read API has
  /// no intraday strain series, and a curve drawn through the single point it
  /// does have would be an invention. What is honest — the day's score against
  /// the target it was set — is one bar.
  private var climb: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        HCCLabel("Strain vs target", size: 11)
        Spacer(minLength: 8)
        if let originWord {
          HCCChip(originWord, dotColor: HCCTheme.Color.strain)
        }
        if let effortWord {
          HCCChip(effortWord, dotColor: HCCTheme.Color.strain)
        }
      }
      HStack(spacing: 10) {
        StrainTargetBar(value: strain, target: target, scaleMax: scaleMax)
        Text(progressText)
          .font(HCCTheme.Font.data(size: 12.5, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize()
      }
      HCCFootnote("Target set from this morning's recovery. Mirrors WHOOP while co-wearing, then switches to the computed value.", size: 11.5)
    }
    .hccCard()
  }

  // ── Activities ─────────────────────────────────────────────────────────────

  /// Workouts only — the derived sleep row belongs on the sleep screen.
  private var workouts: [HCCActivity]? {
    store.hccActivities(for: day)?.filter { $0.kind.uppercased() != "SLEEP" }
  }

  private var activities: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Activities", size: 11)
      if let workouts {
        if workouts.isEmpty {
          HCCEmptyNote("No activities yet")
        } else {
          ForEach(workouts) { activity in
            ActivityRow(activity: activity) { route = .activity(id: activity.id) }
          }
        }
      } else {
        HCCLoadingNote()
      }
    }
    .hccCard()
  }

  // ── History ────────────────────────────────────────────────────────────────

  private var days: [(date: String, value: Double, target: Double?)] {
    store.hcc.scoreDays.compactMap { scoreDay in
      guard let strain = scoreDay.strain else { return nil }
      return (scoreDay.date, strain.value, scoreDay.strainTarget)
    }
    .suffix(7)
    .map { $0 }
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Last \(max(days.count, 1)) days vs target", size: 11)
      if days.isEmpty {
        HCCEmptyNote("No scored days on record yet.")
      } else {
        // Ticks are drawn only when EVERY day has a target. `HCCBars` places a
        // tick per index, and a placeholder for a missing one would land on the
        // floor and read as "your target was zero".
        HCCBars(
          values: days.map(\.value),
          max: scaleMax,
          color: HCCTheme.Color.strain,
          targets: days.allSatisfy { $0.target != nil } ? days.compactMap(\.target) : nil
        )
        HCCAxis(
          leading: HCCFormat.shortDay(days.first?.date),
          trailing: days.last?.date == HealthDataStore.hccDayKey(Date())
            ? "today"
            : HCCFormat.shortDay(days.last?.date)
        )
      }
    }
    .hccCard()
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  private func ensureDayLoaded() async {
    guard store.hcc.homeByDate[day] == nil, !isEnsuringDay else { return }
    isEnsuringDay = true
    defer { isEnsuringDay = false }
    await store.refreshFromHCC(date: HealthDataStore.hccLocalDate(fromDayKey: day))
  }
}

// ── Strain vs target bar ─────────────────────────────────────────────────────

/// `.bar` with the target tick from `.bars b.t::after`: the fill is the day's
/// score on the 0–21 scale, the tick is the target on the same scale.
///
/// A missing value draws no fill and a missing target draws no tick — neither
/// is replaced by zero, which would read as a score of nought or a target of
/// nought rather than as "the server did not say".
private struct StrainTargetBar: View {
  let value: Double?
  let target: Double?
  let scaleMax: Double

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule()
          .fill(HCCTheme.Color.line)
          .frame(height: 8)
        if let value {
          Capsule()
            .fill(HCCTheme.Color.strain)
            .frame(width: width * CGFloat(fraction(value)), height: 8)
        }
        if let target {
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(HCCTheme.Color.text.opacity(0.8))
            .frame(width: 2, height: 14)
            .offset(x: width * CGFloat(fraction(target)) - 1)
        }
      }
      .frame(height: 14)
    }
    .frame(height: 14)
  }

  private func fraction(_ raw: Double) -> Double {
    guard scaleMax > 0 else { return 0 }
    return min(max(raw / scaleMax, 0), 1)
  }
}

// ── Activity row ─────────────────────────────────────────────────────────────

/// `.actv` — the strain badge, the activity name, and its clock window.
private struct ActivityRow: View {
  let activity: HCCActivity
  let action: () -> Void

  /// `ASSAULT_BIKE` → `Assault bike`. The server's enum is an identifier, not a
  /// label; the row uppercases it in CSS, so the underscore is all that has to
  /// go.
  static func readableType(_ raw: String) -> String {
    let words = raw.replacingOccurrences(of: "_", with: " ").lowercased()
    guard let first = words.first else { return raw }
    return first.uppercased() + words.dropFirst()
  }

  var body: some View {
    let times = HCCFormat.clockRange(start: activity.startAt, end: activity.endAt)

    Button(action: action) {
      HStack(spacing: 10) {
        HStack(spacing: 5) {
          Image(systemName: "flame")
            .font(.system(size: 12, weight: .medium))
          Text(activity.strain.map { HCCFormat.decimal($0, 1) } ?? HCCFormat.placeholder)
            .font(HCCTheme.Font.data(size: 15, weight: .medium))
            .monospacedDigit()
        }
        .foregroundStyle(.white)
        .frame(width: 74, height: 44)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(HCCTheme.Color.strain.opacity(0.55))
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(Self.readableType(activity.type))
            .font(HCCTheme.Font.body(size: 12, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(HCCTheme.Color.text)
            .lineLimit(2)
          if activity.strainEstimated {
            Text("estimated strain")
              .font(HCCTheme.Font.data(size: 9.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 2) {
          Text(times.0)
          Text(times.1)
        }
        .font(HCCTheme.Font.data(size: 10.5))
        .foregroundStyle(HCCTheme.Color.muted)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
          .fill(HCCTheme.Color.card2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
          .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}
