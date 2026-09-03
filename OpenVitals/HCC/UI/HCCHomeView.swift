import SwiftUI

/// Home in cloud mode — `S.home` from the approved "C · Command" mockup.
///
/// Reading order, top to bottom: which day and which device, the three rings,
/// the first open insight, the day's activities, tonight's sleep, then the
/// user's own dashboard tiles.
///
/// Every value on this screen is one the server produced. The formatting helpers
/// at the bottom of this file are the only place a string is made out of a
/// number, and each of them returns `--` rather than a stand-in when the server
/// sent null — a ring with no score, a tile with no reading and an activity with
/// no strain all say so instead of showing a zero.
struct HCCHomeView: View {
  @ObservedObject var store: HealthDataStore
  /// The day on screen. Owned by the shell so a detail screen and Home agree
  /// about which day is being looked at.
  @Binding var selectedDate: Date

  @State private var path: [HCCHomeRoute] = []
  @State private var sheet: HCCHomeSheet?
  @State private var didRunDebugLaunch = false

  var body: some View {
    NavigationStack(path: $path) {
      ScrollViewReader { scroller in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          topBar
          // Only when the day itself did not arrive. A partial failure — the
          // benign 404 `/sleep/latest` answers with on a day with no night, say
          // — must not put a red line over a screen that filled correctly.
          if home == nil, let error = store.hcc.lastError {
            statusNote(error)
          }
          rings.id(HCCHomeAnchor.rings.rawValue)
          insightCard
          activitiesCard.id(HCCHomeAnchor.activities.rawValue)
          tonightCard.id(HCCHomeAnchor.tonight.rawValue)
          dashboardSection.id(HCCHomeAnchor.dashboard.rawValue)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
      }
      .onAppear { scrollToDebugAnchorIfRequested(scroller) }
      }
      .scrollIndicators(.hidden)
      .refreshable { await store.refreshFromHCC(date: selectedDate, force: true) }
      .hccBackground()
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: HCCHomeRoute.self) { route in
        HCCHomeDestination(route: route, store: store)
      }
    }
    .sheet(item: $sheet) { sheet in
      HCCHomeSheetHost(sheet: sheet, store: store)
    }
    .task(id: dayKey) {
      await store.refreshFromHCC(date: selectedDate)
    }
    .onAppear(perform: runDebugLaunchHookIfRequested)
  }

  // ── The day being shown ────────────────────────────────────────────────────

  /// The server's civil day key for the selection. Used to ask for a day and to
  /// look one up in the cache — never to re-bucket a value.
  private var dayKey: String { HealthDataStore.hccDayKey(selectedDate) }

  private var isToday: Bool { dayKey == HealthDataStore.hccDayKey(Date()) }

  /// Whether the live-activity surface exists in this build (Phase 4b). Flip to
  /// `true` and the "◉ Start activity" button returns to the row.
  static let liveActivityIsAvailable = false

  private var home: HCCHome? { store.hcc.homeByDate[dayKey] }

  /// The zone every clock on this screen is drawn in. `nil` until `/instance`
  /// has been read, which falls back to the device's zone rather than guessing
  /// an offset.
  private var instanceZone: TimeZone? {
    store.hcc.instance.flatMap { TimeZone(identifier: $0.timezone) }
  }

  /// "TODAY" / "YESTERDAY" / "TUE, SEP 1", uppercased by the pill itself.
  private var dayLabel: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(selectedDate) { return "Today" }
    if calendar.isDateInYesterday(selectedDate) { return "Yesterday" }
    return selectedDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }

  /// The same label inside a sentence. "today" and "yesterday" read naturally
  /// lowercased; a date does not — "no open insights for tue, aug 25" looks
  /// like a typo where "for Tue, Aug 25" reads correctly.
  private var dayLabelInSentence: String {
    let calendar = Calendar.current
    let isRelative = calendar.isDateInToday(selectedDate) || calendar.isDateInYesterday(selectedDate)
    return isRelative ? dayLabel.lowercased() : dayLabel
  }

  private func step(days: Int) {
    guard let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else {
      return
    }
    selectedDate = next
  }

  // ── Top bar ────────────────────────────────────────────────────────────────

  private var topBar: some View {
    HStack(spacing: 8) {
      HCCDayNav(
        label: dayLabel,
        canGoBack: true,
        canGoForward: !isToday,
        goBack: { step(days: -1) },
        goForward: { step(days: 1) }
      )
      Spacer(minLength: 8)
      devicePill
    }
    .padding(.bottom, 12)
  }

  private var devicePill: some View {
    let device = store.hccDrivingDevice() ?? store.hcc.devices.first
    return HCCDevicePill(
      // The server's own label, with any manufacturer token rewritten — the
      // FITBIT row carries the real hardware name, the WHOOP row carries the
      // brand, and only one of those may reach the screen.
      label: device.flatMap { HealthDataStore.hccNeutralCopy($0.label) },
      batteryPercent: device?.battery?.level,
      stateColor: Self.deviceStateColor(device?.status),
      action: { sheet = .devices }
    )
  }

  /// The pill's dot: what the connection can still do, not what the numbers say.
  private static func deviceStateColor(_ status: String?) -> Color {
    switch status {
    case "ACTIVE": HCCTheme.Color.good
    case "NEEDS_REAUTH": HCCTheme.Color.warn
    case "REVOKED": HCCTheme.Color.bad
    default: HCCTheme.Color.muted
    }
  }

  /// The one line the mockup has no slot for: when a read failed, saying so is
  /// the difference between "no data" and "we could not ask".
  private func statusNote(_ text: String) -> some View {
    Text(text)
      .font(HCCTheme.Font.body(size: 11.5))
      .foregroundStyle(HCCTheme.Color.warn)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, 8)
  }

  // ── Rings ──────────────────────────────────────────────────────────────────

  private var rings: some View {
    HStack(alignment: .top, spacing: 8) {
      ringWrap(title: "Sleep", kind: .sleep, model: sleepRing)
      ringWrap(title: "Recovery", kind: .rec, model: recoveryRing)
      ringWrap(title: "Strain", kind: .strain, model: strainRing)
    }
    .padding(.top, 2)
    .padding(.bottom, 12)
  }

  private func ringWrap(title: String, kind: HCCRingKind, model: RingModel) -> some View {
    Button {
      guard let route = model.route else { return }
      path.append(route)
    } label: {
      HCCRingWrap(
        title: title,
        ring: HCCRing(
          progress: model.progress,
          kind: kind,
          size: 94,
          stroke: 7,
          value: model.value,
          unit: model.unit,
          sub: model.sub,
          target: model.target,
          band: model.band
        )
      )
    }
    .buttonStyle(.plain)
  }

  /// What one ring draws. `value == nil` is the "no honest number" case and
  /// leaves the centre reading `--`.
  private struct RingModel {
    var progress: Double = 0
    var value: String?
    var unit: String?
    var sub: String?
    var target: Double?
    /// Recovery only: the band the score falls in, which chooses the ring's
    /// orb gradient (D-A1). `nil` means there is no band to show.
    var band: HCCRecoveryBand?
    var route: HCCHomeRoute?
  }

  private var sleepRing: RingModel {
    let score = home?.score("sleep")
    let value = Self.scoreValue(score)
    return RingModel(
      progress: (value ?? 0) / 100,
      value: value.map { HealthDataStore.hccDecimalText($0, fractionDigits: 0) },
      unit: "%",
      route: .sleep(day: dayKey)
    )
  }

  private var recoveryRing: RingModel {
    let score = home?.score("recovery")
    let value = Self.scoreValue(score)
    return RingModel(
      progress: (value ?? 0) / 100,
      value: value.map { HealthDataStore.hccDecimalText($0, fractionDigits: 0) },
      unit: "%",
      sub: recoverySub,
      // The band comes from the server's own cutoffs when `/instance` has been
      // read. A calibrating or absent score has no band, and the ring draws its
      // muted pair rather than a colour that would read as a verdict.
      band: value.map { HCCRecoveryBand.band(for: $0, bands: store.hcc.instance?.scoreBands.recovery) },
      route: .recovery(day: dayKey)
    )
  }

  /// "74 · 50" — the two streams recovery is computed from. Either can be
  /// missing on its own, and a missing one is a `--`, never the other one's
  /// value or a carried-over reading.
  private var recoverySub: String? {
    guard let home, home.hrv != nil || home.rhr != nil else { return nil }
    let hrv = home.hrv.map { HealthDataStore.hccDecimalText($0, fractionDigits: 0) } ?? "--"
    let rhr = home.rhr.map { HealthDataStore.hccDecimalText($0, fractionDigits: 0) } ?? "--"
    return "\(hrv) · \(rhr)"
  }

  private var strainRing: RingModel {
    let score = home?.score("strain")
    let value = Self.scoreValue(score)
    return RingModel(
      progress: (value ?? 0) / HCCTheme.strainMax,
      value: value.map { HealthDataStore.hccDecimalText($0, fractionDigits: 1) },
      // Strain is a 0–21 scale, not a percentage; the ring carries no unit.
      unit: nil,
      // The tick is the strain worth aiming for today, from today's recovery.
      target: home?.strainTarget.map { $0 / HCCTheme.strainMax },
      route: .strain(day: dayKey)
    )
  }

  /// A score's number, or nil when the server says it is still calibrating or
  /// has none. Both cases render `--`; neither is drawn as zero.
  private static func scoreValue(_ score: HCCHomeScore?) -> Double? {
    guard let score, !score.calibrating else { return nil }
    return score.value
  }

  // ── Insight ────────────────────────────────────────────────────────────────

  /// The cards written ABOUT the day the top bar shows — not the standing feed.
  ///
  /// The two differ the moment the day arrows are used: the standing feed leads
  /// with whatever is newest, so browsing back to Aug 25 used to show today's
  /// card under Aug 25's rings, which reads as a claim about Aug 25. The
  /// per-day feed is the one the counter counts, too, so "✓ 3" means three open
  /// cards for THIS day.
  private var insightCard: some View {
    let open = store.hccOpenInsights(for: dayKey)
    let hasRead = store.hcc.insightsByDate[dayKey] != nil
    return Group {
      if let card = open.first {
        HCCInsightCardView(
          title: card.title,
          message: HealthDataStore.hccNeutralCopy(card.summary) ?? card.summary,
          source: Self.insightSource(card),
          openCount: open.count,
          dismiss: { Task { await store.dismissInsight(id: card.id) } }
        )
        .hccCard()
      } else if hasRead {
        HCCEmptyNote("No open insights for \(dayLabelInSentence). New ones appear as syncs land.")
          .hccCard()
      } else {
        // Empty and "not read yet" are different claims; only the first one is
        // an answer.
        HCCEmptyNote("Loading this day's insights...")
          .hccCard()
      }
    }
  }

  /// The mockup's source line: where the card was written from. The metric
  /// slugs when it names any, the card's own kind otherwise — never a summary
  /// of the reasoning, which would be a claim the server did not make.
  private static func insightSource(_ card: HCCInsightCard) -> String? {
    if !card.relatedMetricSlugs.isEmpty {
      return card.relatedMetricSlugs.joined(separator: " · ")
    }
    return card.kind.replacingOccurrences(of: "_", with: " ").lowercased()
  }

  // ── Activities ─────────────────────────────────────────────────────────────

  private var activitiesCard: some View {
    let activities = store.hccActivities(for: dayKey)
    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        HCCLabel(isToday ? "Today's activities" : "Activities", size: 11)
        Spacer(minLength: 8)
        // A count of "not loaded yet" would be a claim; the chip waits.
        HCCChip(activities.map { "\($0.count)" } ?? "--")
      }
      .padding(.bottom, 8)

      if let activities {
        if activities.isEmpty {
          HCCEmptyNote("No activities recorded for this day.")
        } else {
          VStack(spacing: 8) {
            ForEach(activities) { activity in
              activityRow(activity)
            }
          }
          .padding(.bottom, 4)
        }
      } else {
        HCCEmptyNote("Loading this day's activities...")
      }

      // Same rule as the Coach bubble: no control that does nothing. Live
      // activity arrives in Phase 4b; until then "Add activity" has the row to
      // itself and `liveActivityIsAvailable` is the one line that brings the
      // second button back.
      HCCButtonRow(
        primary: Self.liveActivityIsAvailable
          ? HCCButtonSpec(title: "◉ Start activity") { sheet = .comingSoon("Live activity") }
          : nil,
        secondary: HCCButtonSpec(title: "＋ Add activity") { sheet = .addActivity }
      )
    }
    .hccCard()
    .padding(.top, 4)
  }

  private func activityRow(_ activity: HCCActivity) -> some View {
    let isSleep = activity.kind == "SLEEP"
    return HCCActivityRow(
      systemImage: Self.activityIcon(type: activity.type, isSleep: isSleep),
      badgeText: isSleep
        // A night's badge is how long was slept; a workout's is its strain.
        ? Self.hoursMinutes(minutes: activity.durationMin)
        : (activity.strain.map { HealthDataStore.hccDecimalText($0, fractionDigits: 1) } ?? "--"),
      name: Self.activityName(activity.type),
      startText: Self.clockText(activity.startAt, relativeTo: dayKey, zone: instanceZone),
      endText: Self.clockText(activity.endAt, relativeTo: dayKey, zone: instanceZone),
      tint: isSleep ? HCCTheme.Color.sleep : HCCTheme.Color.strain,
      action: { path.append(.activity(id: activity.id)) }
    )
  }

  // ── Tonight ────────────────────────────────────────────────────────────────

  private var tonightCard: some View {
    let plan = store.hcc.sleepPlan
    let alarm = store.hcc.alarm
    return Button {
      sheet = .alarm
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          HCCLabel("Tonight's sleep", size: 11)
          Spacer(minLength: 8)
          Text("›").foregroundStyle(HCCTheme.Color.muted)
        }
        HCCTonightSleepGrid(
          bedtime: Self.clockText(plan?.recommendedBedtime, zone: instanceZone),
          alarmTime: alarm.map { Self.alarmClock($0.time) } ?? "--",
          alarmState: alarm.map { $0.on ? "● Alarm on" : "Alarm off" } ?? "No alarm set",
          alarmIsOn: alarm?.on ?? false,
          alarmMode: alarm.map { $0.mode == "exact" ? "exact time" : "by sleep goal" } ?? "--"
        )
        HCCButtonRow(secondary: HCCButtonSpec(title: "✎ Edit alarm") { sheet = .alarm })
      }
      .hccCard()
      .contentShape(RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  // ── Dashboard ──────────────────────────────────────────────────────────────

  private var dashboardSection: some View {
    let tiles = resolvedTiles
    return VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "My Dashboard") {
        HCCSectionLink(title: "Customize \u{270E}") { sheet = .customize }
      }
      if tiles.isEmpty {
        HCCEmptyNote("No tiles yet. Tap Customize once your instance is serving these streams.")
          .hccCard()
      } else {
        ForEach(tiles) { tile in
          tileView(tile)
        }
      }
    }
  }

  /// The tiles to draw, in order, filtered to the ones this instance can
  /// actually fill.
  ///
  /// Two rules, both from the design review:
  ///
  ///  * The server's "default" layout is its whole catalog — sixteen tiles,
  ///    most of which no wearable here writes. When the server says the layout
  ///    is its default (or has not answered yet), the phone uses its OWN short
  ///    default instead. A layout the user actually saved is used as saved.
  ///  * A tile the API cannot serve is HIDDEN, not drawn empty. A column of
  ///    "-- no reading today" rows teaches the reader to ignore the dashboard.
  private var resolvedTiles: [HCCDashboardTile] {
    let dashboard = store.hcc.dashboard
    let catalog = dashboard?.catalog ?? []
    let order: [HCCDashboardTile]
    if dashboard?.isDefault ?? true {
      // Prefer the server's label for a slug when it sent one, so an instance
      // that renamed a tile is reflected; fall back to the built-in entry.
      order = Self.defaultTiles.map { tile in
        catalog.first { $0.slug == tile.slug } ?? tile
      }
    } else {
      order = (dashboard?.tiles ?? []).compactMap { slug in
        catalog.first { $0.slug == slug }
      }
    }
    return order.filter(canFill)
  }

  /// The phone's own default layout, used when the server is serving its
  /// built-in order. Labels here are the fallback for a dashboard that has not
  /// loaded yet; the catalog's label wins whenever one arrives.
  static let defaultTiles: [HCCDashboardTile] = [
    HCCDashboardTile(slug: "strain_recovery_graph", label: "Strain & Recovery", metricSlug: nil, kind: "graph"),
    HCCDashboardTile(slug: "rhr", label: "Resting HR", metricSlug: "resting_hr", kind: "metric"),
    HCCDashboardTile(slug: "hrv", label: "HRV", metricSlug: "hrv_sdnn", kind: "metric"),
    HCCDashboardTile(slug: "wrist_temp", label: "Wrist Temp", metricSlug: "wrist_temp", kind: "metric"),
    HCCDashboardTile(slug: "sleep_debt", label: "Sleep Debt", metricSlug: nil, kind: "derived"),
  ]

  /// Whether there is anything honest to draw in this tile right now.
  ///
  /// The server is expected to grow an `available` flag per catalog entry; until
  /// it does, availability IS "the read that backs this tile came back with a
  /// value", which is the same question one step later.
  private func canFill(_ tile: HCCDashboardTile) -> Bool {
    if tile.slug == "strain_recovery_graph" { return !chartPoints.isEmpty }
    return tileValue(tile) != nil
  }

  /// The seven days behind the graph, ending on the most recent day that scored
  /// anything. Empty when nothing in the history scored — a week of empty
  /// columns is not a chart, and that is when the tile is dropped.
  private var chartPoints: [HCCStrainRecoveryPoint] {
    HCCStrainRecoveryChart.points(from: store.hcc.scoreDays)
  }

  /// True when that window runs up to the day on screen. When it does not, the
  /// chip says which day it ends on instead of "7 days", and the chart drops
  /// its today shading — a stale week is labelled, never re-dated.
  private var chartEndsOnSelectedDay: Bool {
    chartPoints.last?.day == dayKey
  }

  @ViewBuilder
  private func tileView(_ tile: HCCDashboardTile) -> some View {
    if tile.slug == "strain_recovery_graph" {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          HCCLabel(tile.label, size: 11)
          Spacer(minLength: 8)
          HCCChip(
            chartEndsOnSelectedDay
              ? "\(chartPoints.count) days"
              : "\(chartPoints.count) days to \(chartPoints.last.map { HealthDataStore.hccShortDayLabel($0.day) } ?? "--")"
          )
        }
        .padding(.bottom, 4)
        HCCStrainRecoveryChart(
          points: chartPoints,
          bands: store.hcc.instance?.scoreBands.recovery,
          highlightsLast: chartEndsOnSelectedDay
        )
      }
      .hccCard()
      .padding(.bottom, 8)
    } else if let value = tileValue(tile) {
      HCCDashboardTileRow(
        label: tile.label,
        value: value.value,
        sub: value.sub,
        trend: value.trend
      )
    }
  }
}

// ── Tile values ──────────────────────────────────────────────────────────────

extension HCCHomeView {
  /// One tile's three strings.
  struct TileValue {
    var value: String
    var sub: String
    var trend: HCCTileTrend = .none
  }

  /// Resolve a catalog tile against the payloads already in the cache, or `nil`
  /// when there is no honest number for it.
  ///
  /// Nothing here fetches, and nothing computes a health number: a derived tile
  /// restates a figure the sleep plan or the score history already carries, and
  /// a metric tile reads a stream's own latest point. `nil` is what hides the
  /// tile — this function never invents a placeholder to fill a row with.
  func tileValue(_ tile: HCCDashboardTile) -> TileValue? {
    switch tile.kind {
    case "list":
      return listTile(tile)
    case "derived":
      return derivedTile(tile)
    default:
      guard let slug = tile.metricSlug else { return nil }
      if let series = store.hcc.vitals.first(where: { $0.slug == slug }) {
        return vitalTile(series)
      }
      if let metric = home?.vitals.first(where: { $0.slug == slug }) {
        return biomarkerTile(metric)
      }
      return nil
    }
  }

  private func listTile(_ tile: HCCDashboardTile) -> TileValue? {
    switch tile.slug {
    case "insights_open":
      // The same day-scoped feed the card above the tiles reads. A tile saying
      // "3 open cards" under an "no open insights for Tue, Aug 25" card would
      // be two answers to one question.
      guard store.hcc.insightsByDate[dayKey] != nil else { return nil }
      let count = store.hccOpenInsights(for: dayKey).count
      return TileValue(value: "\(count)", sub: count == 1 ? "open card" : "open cards")
    case "activities_today":
      guard let activities = store.hccActivities(for: dayKey) else { return nil }
      return TileValue(
        value: "\(activities.count)",
        sub: activities.count == 1 ? "activity" : "activities"
      )
    default:
      return nil
    }
  }

  private func derivedTile(_ tile: HCCDashboardTile) -> TileValue? {
    let plan = store.hcc.sleepPlan
    switch tile.slug {
    case "sleep_debt":
      guard let debt = plan?.currentDebtH ?? store.hcc.sleep?.debtH else { return nil }
      let need = plan?.needH ?? store.hcc.sleep?.needH
      return TileValue(
        value: Self.hoursMinutes(hours: debt),
        sub: need.map { "need \(Self.hoursMinutes(hours: $0))" } ?? "carried into today"
      )
    case "sleep_need":
      guard let need = plan?.needH else { return nil }
      let base = plan?.decomposition?.baseNeedH
      return TileValue(
        value: Self.hoursMinutes(hours: need),
        sub: base.map { "base \(Self.hoursMinutes(hours: $0))" } ?? "tonight"
      )
    case "weekly_strain":
      let week = store.hcc.scoreDays.suffix(7).compactMap { $0.strain?.value }
      guard !week.isEmpty else { return nil }
      return TileValue(
        value: HealthDataStore.hccDecimalText(week.reduce(0, +), fractionDigits: 1),
        sub: "\(week.count) of 7 days scored"
      )
    default:
      return nil
    }
  }

  /// A wearable stream from `/vitals`: its latest point, against its own
  /// trailing baseline.
  private func vitalTile(_ series: HCCVitalSeries) -> TileValue? {
    guard let latest = series.latest else { return nil }
    let digits = series.slug == "resting_hr" ? 0 : 1
    let value = HealthDataStore.hccValueText(latest.value, slug: series.slug, unit: series.unit)
    guard let baseline = series.baseline else {
      return TileValue(value: value, sub: "no baseline yet")
    }
    let delta = latest.deltaVsBaseline ?? series.deltaVsBaseline
    return TileValue(
      value: value,
      sub: "\(HealthDataStore.hccDecimalText(baseline.mean, fractionDigits: digits)) baseline",
      trend: Self.trend(delta)
    )
  }

  /// A lab or body metric from `/home`'s key-vitals list.
  private func biomarkerTile(_ metric: HCCMetricView) -> TileValue? {
    guard let value = metric.value else { return nil }
    return TileValue(
      value: HealthDataStore.hccValueText(value, slug: metric.slug, unit: metric.unit),
      sub: metric.ageText,
      // The server writes the direction as the first character of its trend
      // sentence; reading the arrow is cheaper and safer than re-deriving a
      // direction from two values this screen does not both hold.
      trend: Self.trend(arrow: metric.trend)
    )
  }

  static func trend(_ delta: Double?) -> HCCTileTrend {
    guard let delta else { return .none }
    if delta > 0 { return .up }
    if delta < 0 { return .down }
    return .flat
  }

  static func trend(arrow text: String?) -> HCCTileTrend {
    guard let first = text?.first else { return .none }
    switch first {
    case "↑": return .up
    case "↓": return .down
    case "→": return .flat
    default: return .none
    }
  }
}

// ── Formatting ───────────────────────────────────────────────────────────────

extension HCCHomeView {
  /// "7:21" from minutes — the badge on a sleep row, and the sleep tiles.
  static func hoursMinutes(minutes: Double) -> String {
    let total = Int(minutes.rounded())
    return "\(total / 60):\(String(format: "%02d", total % 60))"
  }

  static func hoursMinutes(hours: Double) -> String {
    hoursMinutes(minutes: hours * 60)
  }

  /// An ISO instant as a clock time in the INSTANCE's timezone.
  ///
  /// Not the device's. The server buckets a day, an activity and an alarm in
  /// the instance's zone, so rendering an instant in the phone's zone would put
  /// a workout at 2 a.m. on a screen whose header says it happened yesterday.
  /// One clock per screen, and it is the server's. Returns `--` for anything
  /// that does not parse — an unparsed timestamp is missing data, not midnight.
  static func clockText(_ iso: String?, zone: TimeZone?) -> String {
    guard let date = HCCTime.instant(iso) else { return "--" }
    return date.formatted(clockStyle(zone: zone))
  }

  /// The same, prefixed with the weekday when the instant falls on a different
  /// civil day than the row it is in — the mockup's `[Tue.] 11:10 p.m.`, which
  /// is what stops a night that began yesterday from reading as tonight.
  static func clockText(_ iso: String, relativeTo dayKey: String, zone: TimeZone?) -> String {
    guard let date = HCCTime.instant(iso) else { return "--" }
    let clock = date.formatted(clockStyle(zone: zone))
    guard dayKeyText(date, zone: zone) != dayKey else { return clock }
    var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
    if let zone { weekday.timeZone = zone }
    return "\(date.formatted(weekday)) \(clock)"
  }

  private static func clockStyle(zone: TimeZone?) -> Date.FormatStyle {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    if let zone { style.timeZone = zone }
    return style
  }

  /// The civil day an instant falls on, in a given zone — the same question the
  /// server answered when it bucketed the row.
  private static func dayKeyText(_ date: Date, zone: TimeZone?) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    if let zone { formatter.timeZone = zone }
    return formatter.string(from: date)
  }

  /// The alarm's `HH:MM` wall clock, which the server already states in the
  /// instance's timezone. It is re-rendered in the reader's 12/24-hour
  /// preference and NOT converted between zones — converting it would move an
  /// alarm the server did not move.
  static func alarmClock(_ time: String) -> String {
    let parts = time.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          let date = Calendar.current.date(
            from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
          )
    else {
      return time
    }
    return date.formatted(date: .omitted, time: .shortened)
  }

  /// SF Symbols for the sport slugs the server ships. The mockup draws these as
  /// emoji; symbols keep one icon language with the tab bar and the rows, and
  /// stay monochrome inside the tinted badge.
  static func activityIcon(type: String, isSleep: Bool) -> String {
    if isSleep { return "moon" }
    switch type.lowercased() {
    case "walking", "walk", "hiking": return "figure.walk"
    case "running", "run": return "figure.run"
    case "cycling", "biking", "bike": return "figure.outdoor.cycle"
    case "assault_bike", "indoor_cycling", "spinning": return "figure.indoor.cycle"
    case "strength", "weightlifting", "lifting": return "figure.strengthtraining.traditional"
    case "swimming", "swim": return "figure.pool.swim"
    case "rowing": return "figure.rower"
    case "yoga": return "figure.yoga"
    default: return "figure.mixed.cardio"
    }
  }

  /// `assault_bike` → `Assault bike`. The server's sport list is free text, so
  /// this tidies rather than translates: an unknown sport still reads as itself.
  static func activityName(_ type: String) -> String {
    let words = type.replacingOccurrences(of: "_", with: " ")
    guard let first = words.first else { return type }
    return first.uppercased() + words.dropFirst()
  }
}

// ── Debug launch hook ────────────────────────────────────────────────────────

extension HCCHomeView {
  /// `HCC_DEBUG_OPEN_DATE` / `HCC_DEBUG_OPEN_ROUTE`, the same contract the
  /// bridge Home honours (docs/hcc-provider.md): `simctl` cannot tap, so a
  /// screenshot of a past day or of a ring detail needs a launch-time way in.
  /// DEBUG only and a no-op without the variables.
  private func runDebugLaunchHookIfRequested() {
    #if DEBUG
    guard !didRunDebugLaunch else { return }
    didRunDebugLaunch = true
    let environment = ProcessInfo.processInfo.environment
    if let day = environment["HCC_DEBUG_OPEN_DATE"],
       let date = HealthDataStore.hccLocalDate(fromDayKey: day) {
      selectedDate = date
    }
    if let raw = environment["HCC_DEBUG_OPEN_ROUTE"],
       let healthRoute = HealthRoute(rawValue: raw),
       let route = HCCHomeRoute(healthRoute: healthRoute, day: HealthDataStore.hccDayKey(selectedDate)) {
      path = [route]
    }
    #endif
  }
}

// ── Debug anchors ────────────────────────────────────────────────────────────

/// The scroll targets `HCC_DEBUG_HOME_ANCHOR` can name.
///
/// Home is about two screens tall, and `simctl` cannot scroll. This is the same
/// trick `HCC_DEBUG_GALLERY_ANCHOR` uses for the component gallery: a launch
/// variable that jumps to one block so it can be screenshotted. DEBUG only.
enum HCCHomeAnchor: String, CaseIterable {
  case rings
  case activities
  case tonight
  case dashboard
}

extension HCCHomeView {
  func scrollToDebugAnchorIfRequested(_ scroller: ScrollViewProxy) {
    #if DEBUG
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_HOME_ANCHOR"],
          let anchor = HCCHomeAnchor(rawValue: raw)
    else {
      return
    }
    // After the reads land, so the block being aimed at has its height. Twice,
    // because a day chosen by `HCC_DEBUG_OPEN_DATE` triggers a second read and
    // relayout after the first jump.
    Task { @MainActor in
      for delay in [2, 4] {
        try? await Task.sleep(for: .seconds(delay))
        scroller.scrollTo(anchor.rawValue, anchor: .top)
      }
    }
    #endif
  }
}
