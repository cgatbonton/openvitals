import SwiftUI

/// `S.sleep` — the sleep detail screen.
///
/// The one rule that shapes this file: a hypnogram is a claim about WHEN each
/// stage happened, and the server only sometimes knows. When `segments` is
/// present it is drawn exactly as sent; when it is absent the same totals are
/// shown as one stacked bar with the legend, because inventing boundaries from
/// four durations would be drawing a night nobody recorded.
struct HCCSleepView: View {
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

  /// The night that belongs to the day on screen — never the most recent night
  /// on record, which would put last week's hours under today's date.
  private var night: HCCSleepNight? {
    guard let night = store.hcc.sleep, night.date == day else { return nil }
    return night
  }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Sleep", subtitle: subtitle)
      hero
      totals
      stages
      tonight
      history
    }
    .task(id: day) { await ensureDayLoaded() }
    .sheet(item: $route) { HCCDetailRouteSheet(route: $0, store: store) }
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  private var subtitle: String {
    let when = day == HealthDataStore.hccDayKey(Date())
      ? "Last night"
      : HealthDataStore.hccDayLabel(day)
    guard let total = night?.stages.totalH else { return when }
    return "\(when) · \(HCCFormat.hours(total)) slept"
  }

  // ── Hero ───────────────────────────────────────────────────────────────────

  /// THE score for this night — the same resolved value `/home` and `/scores`
  /// show. `modelPerformance` is deliberately not rendered here; two numbers for
  /// one night on two screens is exactly the bug the DTO comment warns about.
  private var performance: Double? { night?.performance }

  @ViewBuilder
  private var hero: some View {
    HCCRing(
      progress: (performance ?? 0) / 100,
      kind: .sleep,
      size: 160,
      stroke: 11,
      ticks: true,
      value: performance.map { HCCFormat.decimal($0, 0) },
      unit: "%",
      sub: "PERFORMANCE"
    )
    .frame(maxWidth: .infinity)
    .padding(.top, 6)
    .padding(.bottom, 2)

    if night == nil {
      HCCErrorNote(
        store.hcc.lastError
          ?? "Your Command Center has no sleep on record for \(HealthDataStore.hccDayLabel(day).lowercased()).",
        title: "No night"
      )
    }
  }

  // ── Slept / Needed / Debt ──────────────────────────────────────────────────

  private var totals: some View {
    HStack(alignment: .top, spacing: 10) {
      totalColumn("Slept", HCCFormat.hours(night?.stages.totalH), color: HCCTheme.Color.text)
      totalColumn("Needed", HCCFormat.hours(night?.needH), color: HCCTheme.Color.text)
      totalColumn("Debt", HCCFormat.hours(night?.debtH), color: HCCTheme.Color.warn)
    }
    .hccCard()
  }

  private func totalColumn(_ label: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel(label, size: 11)
      Text(value)
        .font(HCCTheme.Font.display(size: 22, weight: .medium))
        .monospacedDigit()
        .tracking(-0.44)
        .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // ── Stages ─────────────────────────────────────────────────────────────────

  private var stages: some View {
    VStack(alignment: .leading, spacing: 6) {
      HCCLabel("Stages", size: 11)
      if let segments = night?.segments, !segments.isEmpty {
        Hypnogram(spans: spans(from: segments))
      } else if let totals = stageTotals, !totals.isEmpty {
        Hypnogram(spans: totals.map { Hypnogram.Span(stage: $0.stage, weight: $0.hours, fullHeight: true) })
      } else {
        HCCEmptyNote("No stage breakdown on record for this night.")
      }
      if let totals = stageTotals, !totals.isEmpty {
        legend(totals)
      }
      if night?.segments?.isEmpty ?? true, stageTotals?.isEmpty == false {
        HCCFootnote("Stage totals only — your Command Center did not store a timeline for this night.")
          .padding(.top, 2)
      }
    }
    .hccCard()
  }

  private struct StageTotal: Identifiable {
    let stage: String
    let hours: Double
    var id: String { stage }
  }

  /// The four totals the server sends, in the mockup's legend order, dropping
  /// any the server left null.
  private var stageTotals: [StageTotal]? {
    guard let stages = night?.stages else { return nil }
    return [
      ("awake", stages.awakeH),
      ("rem", stages.remH),
      ("light", stages.lightH),
      ("deep", stages.deepH),
    ]
    .compactMap { name, hours in
      guard let hours, hours > 0 else { return nil }
      return StageTotal(stage: name, hours: hours)
    }
  }

  private func spans(from segments: [HCCSleepSegment]) -> [Hypnogram.Span] {
    segments.compactMap { segment in
      guard let start = HCCTime.instant(segment.start),
            let end = HCCTime.instant(segment.end),
            end > start
      else {
        return nil
      }
      return Hypnogram.Span(stage: segment.stage, weight: end.timeIntervalSince(start), fullHeight: false)
    }
  }

  private func legend(_ totals: [StageTotal]) -> some View {
    // `.legend` wraps; a fixed row would clip "Light 4h 09m" on a narrow phone.
    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
      ForEach(totals) { total in
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Hypnogram.color(for: total.stage))
            .frame(width: 8, height: 8)
          Text("\(Hypnogram.name(for: total.stage)) \(HCCFormat.hours(total.hours))")
            .font(HCCTheme.Font.data(size: 10))
            .tracking(0.4)
            .foregroundStyle(HCCTheme.Color.muted)
        }
      }
    }
    .padding(.top, 2)
  }

  // ── Tonight ────────────────────────────────────────────────────────────────

  private var plan: HCCSleepPlan? { store.hcc.sleepPlan }

  private var tonight: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Tonight", size: 11)
      if let plan, let parts = plan.decomposition {
        HCCKeyValueGrid(rows: [
          HCCKeyValue("Baseline need", HCCFormat.hours(parts.baseNeedH)),
          HCCKeyValue("Recent strain", HCCFormat.signedHours(parts.strainH)),
          HCCKeyValue("Sleep debt", HCCFormat.signedHours(parts.debtH)),
          HCCKeyValue("Need", HCCFormat.hours(plan.needH), emphasized: true),
        ])
        Text(bedtimeSentence(plan))
          .font(HCCTheme.Font.body(size: 12))
          .foregroundStyle(HCCTheme.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 2)
      } else if day == HealthDataStore.hccDayKey(Date()) {
        HCCEmptyNote("Your Command Center has no history to size tonight with yet.")
      } else {
        HCCEmptyNote("Tonight's plan is only sized for today.")
      }
    }
    .hccCard()
    .contentShape(Rectangle())
    .onTapGesture { route = .alarm }
    .accessibilityAddTraits(.isButton)
  }

  private func bedtimeSentence(_ plan: HCCSleepPlan) -> String {
    let bedtime = HCCFormat.clock(plan.recommendedBedtime)
    let alarm = Self.alarmClockText(plan.alarm.time)
    switch (bedtime, plan.alarm.on) {
    case let (bedtime?, true):
      return "Recommended bedtime \(bedtime) for the \(alarm) alarm. Tap to edit."
    case let (bedtime?, false):
      return "Recommended bedtime \(bedtime). The alarm is off. Tap to edit."
    case (nil, true):
      return "Alarm set for \(alarm). Tap to edit."
    case (nil, false):
      return "No alarm set. Tap to edit."
    }
  }

  /// `HH:MM` in the instance timezone → the device's short time format. Only a
  /// RENDERING change: the wall-clock digits the server stored are preserved.
  static func alarmClockText(_ time: String) -> String {
    let parts = time.split(separator: ":")
    guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return time }
    let components = DateComponents(
      calendar: Calendar.current,
      year: 2000, month: 1, day: 1, hour: hour, minute: minute
    )
    guard let date = Calendar.current.date(from: components) else { return time }
    return date.formatted(date: .omitted, time: .shortened)
  }

  // ── History ────────────────────────────────────────────────────────────────

  private var nights: [(date: String, value: Double)] {
    store.hcc.scoreDays.compactMap { scoreDay in
      guard let performance = scoreDay.sleepPerformance else { return nil }
      return (scoreDay.date, performance.value)
    }
    .suffix(7)
    .map { $0 }
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Last \(max(nights.count, 1)) nights", size: 11)
      if nights.isEmpty {
        HCCEmptyNote("No scored nights on record yet.")
      } else {
        HCCBars(values: nights.map(\.value), max: 100, color: HCCTheme.Color.sleep)
        HCCAxis(
          leading: HCCFormat.shortDay(nights.first?.date),
          trailing: nights.last?.date == HealthDataStore.hccDayKey(Date())
            ? "today"
            : HCCFormat.shortDay(nights.last?.date)
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

// ── Hypnogram ────────────────────────────────────────────────────────────────

/// `.hypno` — proportional stage bars, each rising from the baseline to the
/// height its stage is drawn at (awake full, REM 80%, light 60%, deep 35%).
///
/// `fullHeight` is the totals fallback: the same colours and proportions with
/// every block at full height, so it reads as a composition bar rather than as
/// a timeline the server never sent.
private struct Hypnogram: View {
  struct Span: Identifiable {
    let stage: String
    /// Any positive unit — seconds for a timeline, hours for totals. Only the
    /// ratios matter.
    let weight: Double
    let fullHeight: Bool
    let id = UUID()
  }

  let spans: [Span]
  var height: CGFloat = 44

  var body: some View {
    let total = spans.reduce(0) { $0 + max($1.weight, 0) }
    GeometryReader { proxy in
      let gaps = CGFloat(max(spans.count - 1, 0))
      let usable = max(proxy.size.width - gaps, 1)
      HStack(alignment: .bottom, spacing: 1) {
        ForEach(spans) { span in
          Rectangle()
            .fill(Self.color(for: span.stage))
            .frame(
              width: total > 0 ? usable * CGFloat(max(span.weight, 0) / total) : 0,
              height: height * (span.fullHeight ? 1 : Self.heightFraction(for: span.stage))
            )
        }
      }
      .frame(width: proxy.size.width, height: height, alignment: .bottomLeading)
    }
    .frame(height: height)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.vertical, 2)
  }

  /// `.hypno .aw/.li/.de/.re` — the mockup's colours, with the two `color-mix`
  /// values resolved to their sRGB result.
  static func color(for stage: String) -> Color {
    switch stage.lowercased() {
    case "awake", "aw": HCCTheme.Color.warn
    // color-mix(in srgb, --sleep 55%, --card)
    case "light", "li": HCCTheme.Color.hex(0x3A6AA1)
    case "deep", "de": HCCTheme.Color.sleep
    // color-mix(in srgb, --sleep 70%, white)
    case "rem", "re": HCCTheme.Color.hex(0x8CC3FF)
    default: HCCTheme.Color.line
    }
  }

  static func heightFraction(for stage: String) -> CGFloat {
    switch stage.lowercased() {
    case "awake", "aw": 1.0
    case "rem", "re": 0.8
    case "light", "li": 0.6
    case "deep", "de": 0.35
    default: 0.5
    }
  }

  static func name(for stage: String) -> String {
    switch stage.lowercased() {
    case "awake", "aw": "Awake"
    case "rem", "re": "REM"
    case "light", "li": "Light"
    case "deep", "de": "Deep"
    default: stage.capitalized
    }
  }
}
