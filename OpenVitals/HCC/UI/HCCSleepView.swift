import SwiftUI

/// `S.sleep` — the sleep detail screen.
///
/// The one rule that shapes this file: a hypnogram is a claim about WHEN each
/// stage happened, and the server only sometimes knows. When `segments` is
/// present the night is drawn as a depth trace, exactly as sent; when it is
/// absent the same totals are shown as a stage ledger — one bar per stage
/// against the owner's own recent average — because inventing boundaries from
/// four durations would be drawing a night nobody recorded. (Design chosen
/// 2026-09-09 from the "Sleep Stage Variations" artifact: A for timelines, D
/// for totals.)
struct HCCSleepView: View {
  @ObservedObject var store: HealthDataStore
  var dayKey: String?

  @State private var route: HCCDetailRoute?
  @State private var isEnsuringDay = false

  /// The night's own row, read when the owner taps Edit. The store caches the
  /// day's LIST, which carries no notes; the sheet needs them, and the read
  /// goes through the same page-load helper the activity screen uses so the
  /// session's 401 handling applies and the fetch never sits in the body.
  @StateObject private var nightRow = HCCPageLoad<HCCActivityDetail>()
  @State private var editing: HCCActivityDetail?
  @State private var showSheet = false
  @State private var isOpeningSheet = false
  @State private var openError: String?

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
      // Every night is editable — a device's, a hand-logged one, and the
      // derived row a night with only measurements produces (the server turns
      // that into a stored row on the first edit). A day with no night at all
      // offers to add one.
      HCCDetailHeader(title: "Sleep", subtitle: subtitle, actionTitle: actionTitle, action: openSheet)
      if let openError {
        HCCErrorNote(openError)
      }
      hero
      totals
      stages
      tonight
      history
    }
    .task(id: day) { await ensureDayLoaded() }
    .sheet(item: $route) { HCCDetailRouteSheet(route: $0, store: store) }
    .sheet(isPresented: $showSheet) {
      // The store re-reads the night behind any sleep write, so nothing here
      // has to be told what changed.
      HCCAddActivitySheet(store: store, editing: editing, initialEntry: .sleep, nightOf: day)
    }
  }

  // ── Edit ───────────────────────────────────────────────────────────────────

  /// The night's row on the day's list — a stored session, or the derived one.
  /// Nil while the list has not loaded, or when the day has no night.
  private var nightRowOnList: HCCActivity? {
    store.hccActivities(for: day)?.first(where: HCCActivityRoute.isNight)
  }

  /// No action until the list is known: offering "Add" before it loads could
  /// log a second night on top of one the server already has.
  private var actionTitle: String? {
    guard store.hccActivities(for: day) != nil, !isOpeningSheet else { return nil }
    return nightRowOnList == nil ? "Add" : "Edit"
  }

  private func openSheet() {
    guard !isOpeningSheet else { return }
    openError = nil
    guard let row = nightRowOnList else {
      editing = nil
      showSheet = true
      return
    }
    isOpeningSheet = true
    Task {
      await nightRow.reload { try await HCCSession.shared.client.activity(id: row.id).activity }
      isOpeningSheet = false
      guard let detail = nightRow.value else {
        openError = nightRow.errorText ?? "Could not open this night."
        return
      }
      editing = detail
      showSheet = true
    }
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  private var subtitle: String {
    let when = day == HealthDataStore.hccDayKey(Date())
      ? "Last night"
      : HealthDataStore.hccDayLabel(day)
    guard let total = night?.stages.totalH else { return when }
    let slept = "\(when) · \(HCCFormat.hours(total)) slept"
    // The owner's figure, not the device's — said, so the number is not read
    // as a measurement it is not.
    return night?.edited == true ? "\(slept) · edited" : slept
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
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        totalColumn("Slept", HCCFormat.hours(night?.stages.totalH), color: HCCTheme.Color.text)
        totalColumn("Needed", HCCFormat.hours(night?.needH), color: HCCTheme.Color.text)
        totalColumn("Debt", HCCFormat.hours(night?.debtH), color: HCCTheme.Color.warn)
      }
      // The need already has the nap taken off; say so, or "Needed" reads as
      // lower than the nights around it for no visible reason.
      if let nap = night?.napH, nap > 0 {
        HCCFootnote("Needed is \(HCCFormat.hours(nap)) lower for a nap the afternoon before.")
      }
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
      HStack(alignment: .firstTextBaseline) {
        HCCLabel("Stages", size: 11)
        Spacer(minLength: 8)
        if let runs = timelineRuns, let first = runs.first, let last = runs.last {
          Text("\(HCCDepthTrace.clock(first.start)) → \(HCCDepthTrace.clock(last.end))")
            .font(HCCTheme.Font.data(size: 10))
            .foregroundStyle(HCCTheme.Color.muted)
        }
      }
      if let runs = timelineRuns {
        HCCDepthTrace(runs: runs)
        if let totals = stageTotals, !totals.isEmpty {
          legend(totals)
        }
      } else if let totals = stageTotals, !totals.isEmpty {
        HCCStageLedger(rows: ledgerRows(totals))
        if let baselines = night?.stageBaselines {
          HCCFootnote("Tick = your \(baselines.nights)-night average for that stage.", size: 10.5)
            .padding(.top, 2)
        }
      } else {
        HCCEmptyNote("No stage breakdown on record for this night.")
      }
    }
    .hccCard()
  }

  private struct StageTotal: Identifiable {
    let stage: HCCSleepStage
    let hours: Double
    var id: String { stage.rawValue }
  }

  /// The four totals the server sends, deepest first, dropping any the server
  /// left null.
  private var stageTotals: [StageTotal]? {
    guard let stages = night?.stages else { return nil }
    return [
      (HCCSleepStage.deep, stages.deepH),
      (.light, stages.lightH),
      (.rem, stages.remH),
      (.awake, stages.awakeH),
    ]
    .compactMap { stage, hours in
      guard let hours, hours > 0 else { return nil }
      return StageTotal(stage: stage, hours: hours)
    }
  }

  /// The server's timeline as drawable runs, or nil when there is none — the
  /// ledger is the honest fallback, never a timeline guessed from totals.
  private var timelineRuns: [HCCDepthTrace.Run]? {
    guard let segments = night?.segments else { return nil }
    let runs = segments.compactMap { segment -> HCCDepthTrace.Run? in
      guard let stage = HCCSleepStage(segment.stage),
            let start = HCCTime.instant(segment.start),
            let end = HCCTime.instant(segment.end),
            end > start
      else {
        return nil
      }
      return HCCDepthTrace.Run(stage: stage, start: start, end: end)
    }
    .sorted { $0.start < $1.start }
    return runs.isEmpty ? nil : runs
  }

  private func ledgerRows(_ totals: [StageTotal]) -> [HCCStageLedger.Row] {
    let baselines = night?.stageBaselines
    return totals.map { total in
      let usual: Double? = switch total.stage {
      case .deep: baselines?.deepH
      case .light: baselines?.lightH
      case .rem: baselines?.remH
      case .awake: baselines?.awakeH
      }
      return HCCStageLedger.Row(stage: total.stage, hours: total.hours, usual: usual)
    }
  }

  private func legend(_ totals: [StageTotal]) -> some View {
    // `.legend` wraps; a fixed row would clip "Light 4h 09m" on a narrow phone.
    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
      ForEach(totals) { total in
        HStack(spacing: 5) {
          Circle()
            .fill(total.stage.color)
            .frame(width: 7, height: 7)
          Text(total.stage.name)
            .font(HCCTheme.Font.data(size: 10))
            .tracking(0.4)
            .foregroundStyle(HCCTheme.Color.muted)
          Spacer(minLength: 6)
          Text(HCCFormat.hours(total.hours))
            .font(HCCTheme.Font.data(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(HCCTheme.Color.text)
        }
      }
    }
    .padding(.top, 4)
  }

  // ── Tonight ────────────────────────────────────────────────────────────────

  private var plan: HCCSleepPlan? { store.hcc.sleepPlan }

  private var tonight: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Tonight", size: 11)
      if let plan, let parts = plan.decomposition {
        HCCKeyValueGrid(rows: tonightRows(plan, parts))
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

  /// The need and its terms. The nap row appears only on a day with a nap —
  /// a permanent "+0h 00m" line would be a claim the model reads naps from a
  /// stream, which it does not.
  private func tonightRows(_ plan: HCCSleepPlan, _ parts: HCCSleepNeedDecomposition) -> [HCCKeyValue] {
    var rows = [
      HCCKeyValue("Baseline need", HCCFormat.hours(parts.baseNeedH)),
      HCCKeyValue("Recent strain", HCCFormat.signedHours(parts.strainH)),
      HCCKeyValue("Sleep debt", HCCFormat.signedHours(parts.debtH)),
    ]
    if parts.napsH != 0 {
      rows.append(HCCKeyValue("Nap today", HCCFormat.signedHours(parts.napsH)))
    }
    rows.append(HCCKeyValue("Need", HCCFormat.hours(plan.needH), emphasized: true))
    return rows
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

// ── Stages: the palette both charts share ────────────────────────────────────

/// The four stages in lane order (awake on top, deep at the bottom), with one
/// palette: a single blue that darkens with depth, and a warm tone for awake so
/// it can never be read as a sleep stage. Checked colourblind-safe against the
/// card surface with the dataviz palette validator on 2026-09-09.
enum HCCSleepStage: String, CaseIterable {
  case awake, rem, light, deep

  /// The server's stage word (`deep | rem | light | awake`); a vendor alias
  /// that slipped through still lands on the right lane.
  init?(_ raw: String) {
    switch raw.lowercased() {
    case "awake", "aw", "wake": self = .awake
    case "rem", "re": self = .rem
    case "light", "li", "core": self = .light
    case "deep", "de", "sws", "slow_wave": self = .deep
    default: return nil
    }
  }

  var name: String {
    switch self {
    case .awake: "Awake"
    case .rem: "REM"
    case .light: "Light"
    case .deep: "Deep"
    }
  }

  var color: Color {
    switch self {
    case .awake: HCCTheme.Color.hex(0xE0935A)
    case .rem: HCCTheme.Color.hex(0xA6C8F2)
    case .light: HCCTheme.Color.hex(0x5B9BE3)
    case .deep: HCCTheme.Color.hex(0x2E63B8)
    }
  }

  /// Lane index for the depth trace, awake on top.
  var lane: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// ── Depth trace (a night WITH a timeline) ────────────────────────────────────

/// The classic hypnogram drawn as a line rather than blocks: a thin stepped
/// skeleton with rounded joins carries the shape of the night, and each stage
/// run is coloured on top of it. Boundaries are exactly the server's. Hour
/// ticks are in the INSTANCE zone, like every other clock on this screen.
struct HCCDepthTrace: View {
  struct Run {
    let stage: HCCSleepStage
    let start: Date
    let end: Date
  }

  /// Sorted by start, non-empty.
  let runs: [Run]
  var height: CGFloat = 134

  private static let labelWidth: CGFloat = 40
  private static let axisHeight: CGFloat = 20
  private static let skeleton = HCCTheme.Color.hex(0x4A5A80)

  var body: some View {
    Canvas { context, size in
      guard let first = runs.first, let last = runs.last else { return }
      let span = max(last.end.timeIntervalSince(first.start), 60)
      let plotX = Self.labelWidth
      let plotW = max(size.width - plotX - 4, 1)
      let top: CGFloat = 8
      let laneGap = max((size.height - Self.axisHeight - top - 8) / 3, 1)
      let x = { (date: Date) -> CGFloat in plotX + plotW * CGFloat(date.timeIntervalSince(first.start) / span) }
      let y = { (stage: HCCSleepStage) -> CGFloat in top + laneGap * CGFloat(stage.lane) }

      // Lanes and their labels.
      for stage in HCCSleepStage.allCases {
        let laneY = y(stage)
        var lane = Path()
        lane.move(to: CGPoint(x: plotX, y: laneY))
        lane.addLine(to: CGPoint(x: plotX + plotW, y: laneY))
        context.stroke(lane, with: .color(HCCTheme.Color.line), lineWidth: 1)
        context.draw(
          Text(stage.name).font(HCCTheme.Font.data(size: 9.5)).foregroundStyle(HCCTheme.Color.muted),
          at: CGPoint(x: plotX - 8, y: laneY),
          anchor: .trailing
        )
      }

      // The skeleton: one stepped path through every run, so the transitions
      // read as a trace rather than as separate blocks.
      var skeleton = Path()
      skeleton.move(to: CGPoint(x: x(first.start), y: y(first.stage)))
      for run in runs {
        skeleton.addLine(to: CGPoint(x: x(run.start), y: y(run.stage)))
        skeleton.addLine(to: CGPoint(x: x(run.end), y: y(run.stage)))
      }
      context.stroke(
        skeleton,
        with: .color(Self.skeleton),
        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
      )

      // The coloured runs on top. A run too short to draw as a line still
      // marks its stage with a dot rather than vanishing.
      for run in runs {
        let x0 = x(run.start), x1 = x(run.end), laneY = y(run.stage)
        if x1 - x0 >= 2.5 {
          var line = Path()
          line.move(to: CGPoint(x: x0 + 1, y: laneY))
          line.addLine(to: CGPoint(x: x1 - 1, y: laneY))
          context.stroke(line, with: .color(run.stage.color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        } else {
          let dot = Path(ellipseIn: CGRect(x: (x0 + x1) / 2 - 1.9, y: laneY - 1.9, width: 3.8, height: 3.8))
          context.fill(dot, with: .color(run.stage.color))
        }
      }

      // Hour ticks in the instance zone.
      let axisY = size.height - Self.axisHeight
      for hour in Self.hourMarks(from: first.start, to: last.end) {
        let tickX = x(hour)
        var tick = Path()
        tick.move(to: CGPoint(x: tickX, y: axisY + 4))
        tick.addLine(to: CGPoint(x: tickX, y: axisY + 8))
        context.stroke(tick, with: .color(HCCTheme.Color.muted), lineWidth: 1)
        context.draw(
          Text(Self.hourLabel(hour)).font(HCCTheme.Font.data(size: 9.5)).foregroundStyle(HCCTheme.Color.muted),
          at: CGPoint(x: tickX, y: axisY + 10),
          anchor: .top
        )
      }
    }
    .frame(height: height)
    .accessibilityLabel(accessibilitySummary)
  }

  private var accessibilitySummary: String {
    runs.map { "\($0.stage.name) \(Self.clock($0.start)) to \(Self.clock($0.end))" }.joined(separator: ", ")
  }

  /// Every full hour strictly inside the night, in the instance zone.
  static func hourMarks(from start: Date, to end: Date) -> [Date] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = HCCInstanceZone.current
    guard var hour = calendar.dateInterval(of: .hour, for: start)?.end else { return [] }
    var marks: [Date] = []
    while hour < end, marks.count < 24 {
      marks.append(hour)
      hour = hour.addingTimeInterval(3600)
    }
    return marks
  }

  static func hourLabel(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(timeZone: HCCInstanceZone.current).hour(.twoDigits(amPM: .omitted)))
  }

  /// A wall-clock time in the instance zone — the zone the night happened in.
  static func clock(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: HCCInstanceZone.current))
  }
}

// ── Stage ledger (a night with totals ONLY) ──────────────────────────────────

/// One thin bar per stage, deepest first, the value at the tip, and a tick
/// where the owner's own recent average sits — what a totals-only night can
/// honestly say, and one thing a composition bar never could.
struct HCCStageLedger: View {
  struct Row: Identifiable {
    let stage: HCCSleepStage
    let hours: Double
    /// The owner's recent average for this stage; nil draws no tick.
    let usual: Double?
    var id: String { stage.rawValue }
  }

  let rows: [Row]

  private var scaleMax: Double {
    let longest = rows.map { max($0.hours, $0.usual ?? 0) }.max() ?? 1
    return max(longest, 0.25) * 1.02
  }

  var body: some View {
    VStack(spacing: 10) {
      ForEach(rows) { row in
        HStack(spacing: 8) {
          Text(row.stage.name)
            .font(HCCTheme.Font.data(size: 9.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .frame(width: 40, alignment: .trailing)
          GeometryReader { proxy in
            let width = proxy.size.width
            let barWidth = width * CGFloat(row.hours / scaleMax)
            ZStack(alignment: .leading) {
              Rectangle()
                .fill(HCCTheme.Color.line)
                .frame(height: 1)
              UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 4,
                topTrailingRadius: 4,
                style: .continuous
              )
              .fill(row.stage.color)
              .frame(width: max(barWidth, 2), height: 8)
              if let usual = row.usual {
                Rectangle()
                  .fill(HCCTheme.Color.text.opacity(0.8))
                  .frame(width: 1.25, height: 16)
                  .offset(x: width * CGFloat(usual / scaleMax) - 0.6)
              }
            }
            .frame(height: 16)
          }
          .frame(height: 16)
          Text(HCCFormat.hours(row.hours))
            .font(HCCTheme.Font.data(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(HCCTheme.Color.text)
            .frame(width: 54, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(row))
      }
    }
    .padding(.vertical, 4)
  }

  private func accessibilityText(_ row: Row) -> String {
    guard let usual = row.usual else { return "\(row.stage.name) \(HCCFormat.hours(row.hours))" }
    return "\(row.stage.name) \(HCCFormat.hours(row.hours)), usually \(HCCFormat.hours(usual))"
  }
}
