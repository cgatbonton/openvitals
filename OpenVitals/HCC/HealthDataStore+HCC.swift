import Foundation
import SwiftUI

// Cloud-mode population of the health store (plan §4.2, §4.5).
//
// The bridge path fills `HealthDataStore`'s published state out of the local
// SQLite/Rust pipeline. This file fills exactly the same published properties
// out of the Health Command Center read API, so every screen downstream is
// unchanged — it reads `healthDashboardExploreSnapshots` and friends without
// knowing or caring which provider produced them.
//
// Three rules hold everywhere below:
//
//  * A number is the server's or it does not exist. `calibrating` or a null
//    value becomes `.unavailable(reason)` with the server's own sentence and
//    the value "--"; nothing is interpolated, defaulted or carried over from a
//    previous day.
//  * Day keys stay strings. The server's `YYYY-MM-DD` IS the bucket; it is
//    turned into a `Date` only to produce a "Today"/"Yesterday"/"Aug 25"
//    LABEL, never to re-decide which day a value belongs to.
//  * Copy names no manufacturer. Origins and sources go through `HCCCopy`.

// ── Cache ────────────────────────────────────────────────────────────────────

/// The mutable cloud state behind the published snapshots.
///
/// Swift extensions cannot add stored properties, so this object is held by the
/// one stored property this workstream adds to `HealthDataStore` (`var hcc`).
/// Keeping it in a single box rather than a fistful of properties also means
/// the bridge path pays for exactly one reference it never touches.
@MainActor
final class HCCStoreState {
  /// Home payloads keyed by the server's civil day, so the Home date toggle can
  /// show a past day without refetching it.
  var homeByDate: [String: HCCHome] = [:]
  /// Ring history for the trend sparklines, newest last.
  var scoreDays: [HCCScoreDay] = []
  var sleep: HCCSleepNight?
  var vitals: [HCCVitalSeries] = []
  /// The day the last completed refresh loaded.
  var lastRequestedDay: String?
  /// The day a screen has asked for and no read has consumed yet. One slot on
  /// purpose: only one day is ever on screen, so the newest request wins.
  var pendingDay: String?
  /// The in-flight reader, owned by the store so no view can cancel it.
  var refreshTask: Task<Void, Never>?
  /// Set when a fetch failed, so the status line can say so instead of
  /// implying the screen is simply empty.
  var lastError: String?

  // ── Beyond the rings (the Command design screens) ─────────────────────────

  /// Open cards from `/insights?status=open` with NO date — the standing feed
  /// behind the Insights page.
  var insights: [HCCInsightCard] = []
  /// Open cards for one civil day, from `/insights?status=open&date=`, keyed by
  /// the day that was asked for.
  ///
  /// A separate cache rather than a filter over `insights`, because the server
  /// does the day matching on `citations.date` — a field this client does not
  /// receive and could not reproduce. `nil` for a day means "not read yet";
  /// an EMPTY array is a real answer, since a card with no dated citation
  /// belongs to no day at all.
  var insightsByDate: [String: [HCCInsightCard]] = [:]
  /// Ids dismissed on this device since launch.
  ///
  /// `/home` embeds its own copy of the day's flags and `HCCHome` is immutable,
  /// so a dismissal cannot be edited into the cached payload. Recording the id
  /// here and filtering at read time (`hccOpenInsights()`) is what keeps a
  /// dismissed card from reappearing the moment Home refetches.
  var dismissedInsightIds: Set<String> = []
  /// Activities keyed by the SERVER's civil day, same rule as `homeByDate`.
  var activitiesByDate: [String: [HCCActivity]] = [:]
  /// Tonight's sleep plan. Only ever fetched for today — "tonight" has no
  /// meaning for a day the user is browsing backwards into.
  var sleepPlan: HCCSleepPlan?
  /// Home's tile order plus the catalog that labels it.
  var dashboard: HCCDashboardPrefs?
  /// The wake target of record. The phone schedules the real alarm; this row is
  /// the intent both this app and the web app read.
  var alarm: HCCAlarm?
  /// True when `alarm` is the server's built-in default rather than a saved one.
  var alarmIsDefault = false
  var devices: [HCCDevice] = []
  /// The wrist source fronted for display; nil = the automatic priority rule.
  var preferredSource: String?
  var instance: HCCInstance?

  /// Set by `refreshFromHCC(date:force:)` when the caller wants the
  /// session-scoped reads redone (pull to refresh, or right after a write).
  var pendingForceSessionReads = false

  /// The reads that describe the ACCOUNT rather than a day. Fetching them on
  /// every date change would triple the cost of tapping the day arrows for
  /// payloads that do not change between days.
  var hasSessionReads: Bool { instance != nil && dashboard != nil && alarm != nil }

  var hasAnyData: Bool { !homeByDate.isEmpty || sleep != nil || !vitals.isEmpty }

  // ── Per-feature state slots ────────────────────────────────────────────────

  /// Feature state boxes (journal, training, uploads, live workout, coach…)
  /// keyed by type. Each feature keeps its own `ObservableObject` in its own
  /// file and reaches it through `slot(_:)`, so adding a feature never edits
  /// this class and views observe exactly the box they draw from.
  private var slots: [ObjectIdentifier: AnyObject] = [:]

  /// The one box of type `T`, created on first use.
  func slot<T: AnyObject>(_ make: () -> T) -> T {
    let key = ObjectIdentifier(T.self)
    if let existing = slots[key] as? T { return existing }
    let made = make()
    slots[key] = made
    return made
  }
}

// ── Refresh ──────────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// Pull one day of Home, two weeks of rings, the night, and a month of vitals,
  /// then rebuild every published property the screens read.
  ///
  /// Never throws: a health screen that cannot reach the server shows an
  /// unavailable state with the reason, not an error dialog. A 401 means the
  /// token is gone, which is a session question rather than a data question, so
  /// it is handed to `HCCSession`.
  ///
  /// `force` additionally redoes the session-scoped reads (`/instance`,
  /// `/dashboard`, `/alarm`, `/devices`) that are otherwise fetched once —
  /// what a pull-to-refresh, or a screen that just wrote one of them, wants.
  func refreshFromHCC(date: Date? = nil, force: Bool = false) async {
    // Queue the day, then make sure a reader is running. Callers never do the
    // work themselves — see `runHCCRefreshLoop()` for why that matters.
    hcc.pendingDay = date.map(Self.hccDayKey) ?? Self.hccDayKey(Date())
    // Sticky: a forced request that arrives while a plain read is in flight
    // must not be downgraded by the read that is already running.
    hcc.pendingForceSessionReads = hcc.pendingForceSessionReads || force

    if let running = hcc.refreshTask {
      await running.value
      return
    }

    healthMetricRefreshIsRunning = true
    healthMetricRefreshStatus = "Reading your Command Center..."

    // Owned by the store, NOT by the view that asked for it.
    //
    // Every caller is a screen: a `.task` on Home or on a detail page. SwiftUI
    // cancels a `.task` when its view goes away or its id changes — which is
    // exactly what a deep link into a detail screen, a date change, or a tab
    // switch does, all while a read is in flight. Doing the work inside the
    // caller's task meant that cancellation killed the read: the four requests
    // came back 200 on the wire and every one of them was thrown away as
    // `CancellationError`, leaving the screen empty with nothing left running
    // to fix it. An unstructured task started here belongs to the store and
    // outlives whichever screen happened to ask first.
    let work = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runHCCRefreshLoop()
    }
    hcc.refreshTask = work
    await work.value
  }

  /// Read queued days until the queue is empty, one at a time.
  ///
  /// The loop (rather than a recursive drain) is what guarantees the day the
  /// user is actually looking at is the last one read: three screens asking for
  /// three days while one read is in flight leave one entry in `pendingDay`,
  /// and this keeps going until nothing is left.
  private func runHCCRefreshLoop() async {
    while let day = hcc.pendingDay {
      hcc.pendingDay = nil
      await performHCCRead(day: day)
    }
    hcc.refreshTask = nil
    healthMetricRefreshIsRunning = false
  }

  /// One day: four reads in parallel, then one state update.
  private func performHCCRead(day requestedDay: String) async {
    var resolving = requestedDay
    // The day key we were handed was computed with whatever zone was known at
    // the time. If that was NOTHING, it is the device's, which is the one zone
    // the server does not bucket in — so settle the question before asking for
    // a day rather than spending the first refresh on the wrong one. Costs a
    // serialized request only on a launch that never signed in (the DEBUG token
    // path); a signed-in phone has the zone from the stored account summary.
    if !HCCInstanceZone.isKnown {
      let askedForToday = resolving == Self.hccDayKey(Date())
      if let fetched = try? await HCCSession.shared.client.instance() {
        hcc.instance = fetched
        HCCInstanceZone.set(fetched.timezone)
        if askedForToday { resolving = Self.hccDayKey(Date()) }
      }
    }
    // Immutable from here down: the fan-out below captures it in concurrently
    // executing closures, which a `var` may not be.
    let requested = resolving

    let isToday = requested == Self.hccDayKey(Date())
    // `?date=` only for a past day: omitting it lets the server pick the day in
    // ITS timezone, which is the correct answer for "today" on a phone that may
    // be in a different one.
    let dayParam: String? = isToday ? nil : requested

    hcc.lastRequestedDay = requested

    // Account-level reads: once per launch, or when a caller forces them.
    let wantsSessionReads = hcc.pendingForceSessionReads || !hcc.hasSessionReads || hcc.devices.isEmpty
    hcc.pendingForceSessionReads = false

    let client = HCCSession.shared.client
    async let homeResult = HCCFetch.result { try await client.home(date: dayParam) }
    async let scoresResult = HCCFetch.result { try await client.scores(days: 14) }
    async let sleepResult = HCCFetch.result {
      if let dayParam {
        return try await client.sleep(date: dayParam)
      }
      return try await client.sleepLatest()
    }
    async let vitalsResult = HCCFetch.result { try await client.vitals(days: 30) }
    async let insightsResult = HCCFetch.result { try await client.insights(status: "open") }
    // The day's own cards. Always an explicit date: omitting it is the general
    // feed, which is the OTHER read above, not "today".
    async let dayInsightsResult = HCCFetch.result {
      try await client.insights(status: "open", date: requested)
    }
    async let activitiesResult = HCCFetch.result { try await client.activities(date: dayParam) }
    // "Tonight" is only a question about today.
    async let planResult = HCCFetch.optional(isToday) { try await client.sleepPlan() }
    async let dashboardResult = HCCFetch.optional(wantsSessionReads) { try await client.dashboard() }
    async let alarmResult = HCCFetch.optional(wantsSessionReads) { try await client.alarm() }
    async let devicesResult = HCCFetch.optional(wantsSessionReads) { try await client.devices() }
    async let instanceResult = HCCFetch.optional(wantsSessionReads) { try await client.instance() }

    let home = await homeResult
    let scores = await scoresResult
    let sleep = await sleepResult
    let vitals = await vitalsResult
    let insights = await insightsResult
    let dayInsights = await dayInsightsResult
    let activities = await activitiesResult
    let plan = await planResult
    let dashboard = await dashboardResult
    let alarm = await alarmResult
    let devices = await devicesResult
    let instance = await instanceResult

    // A view is about to see a different `hcc`; `hcc` is a plain reference on
    // the store, so nothing else would tell SwiftUI that.
    hccWillChange()

    let failures = [
      home.failure, scores.failure, sleep.failure, vitals.failure,
      insights.failure, dayInsights.failure, activities.failure,
      plan.flatMap(\.failure), dashboard.flatMap(\.failure), alarm.flatMap(\.failure),
      devices.flatMap(\.failure), instance.flatMap(\.failure),
    ].compactMap { $0 }
    if failures.contains(where: \.isUnauthorized) {
      HCCSession.shared.handleUnauthorized()
      // The account is gone; its timezone must not outlive it and silently
      // bucket the NEXT account's days.
      HCCInstanceZone.reset()
      hcc.lastError = HCCAPIError.unauthorized.errorDescription
      healthMetricRefreshStatus = hcc.lastError ?? "Signed out"
      hcc.pendingDay = nil
      rebuildHCCDashboardState()
      return
    }

    if case let .success(value) = home {
      // Keyed by the day the SERVER says this is: asking for "today" with no
      // `?date=` lets the instance's timezone decide, and that answer is the
      // one the cache must be keyed on.
      hcc.homeByDate[value.date] = value
      hcc.lastRequestedDay = value.date
    }
    if case let .success(value) = scores {
      hcc.scoreDays = value.days
    }
    switch sleep {
    case let .success(value):
      hcc.sleep = value
    case let .failure(error):
      // 404 is "no night on record", which is an answer, not a fault.
      if case let .http(status, _) = error, status == 404 { hcc.sleep = nil }
    }
    if case let .success(value) = vitals {
      hcc.vitals = value.vitals
    }
    if case let .success(value) = insights {
      hcc.insights = value.insights
    }
    if case let .success(value) = dayInsights {
      // Keyed on the day that was REQUESTED, which is what the server filtered
      // on. `/insights` does not echo the date it filtered by (unlike
      // `/activities`), so this is the one key here that is ours rather than the
      // server's — which is safe precisely because `hccDayKey` now works in the
      // INSTANCE's zone, so "the day we asked for" and "the day the server
      // bucketed" are the same string on any device, anywhere.
      hcc.insightsByDate[requested] = value.insights
    }
    if case let .success(value) = activities {
      // Keyed on the day the SERVER bucketed, exactly like `/home`.
      hcc.activitiesByDate[value.date] = value.activities
    }
    switch plan {
    case .success(let value)?:
      hcc.sleepPlan = value
      // The plan carries the alarm the server sized tonight against; taking it
      // here keeps one alarm on screen rather than two reads of the same row.
      hcc.alarm = value.alarm
    case .failure(let error)?:
      // 404 is "no history to size a night with", which is an answer.
      if case let .http(status, _) = error, status == 404 { hcc.sleepPlan = nil }
    case nil:
      break
    }
    if case let .success(value)? = dashboard {
      hcc.dashboard = value
    }
    if case let .success(value)? = alarm {
      hcc.alarm = value.alarm
      hcc.alarmIsDefault = value.isDefault
    }
    if case let .success(value)? = devices {
      hcc.devices = value.devices
      hcc.preferredSource = value.preferredSource
    }
    if case let .success(value)? = instance {
      hcc.instance = value
      // The authoritative answer to "which zone are the day keys in".
      HCCInstanceZone.set(value.timezone)
    }

    // A partial failure is reported but does not discard what did arrive.
    hcc.lastError = failures.first?.errorDescription
    healthMetricRefreshStatus = hcc.lastError ?? "Updated \(Self.hccClockText(Date()))"
    rebuildHCCDashboardState()

    // HCC: the widgets and the Live Activity read what this loop just cached.
    // Registering the store here rather than at app launch is what lets a
    // silent push or a `BGAppRefreshTask` reach the same instance the screens
    // use — the store is a `@StateObject` on the shell, so at launch there is
    // not one yet. See `HCCAppServices` in HCCAppDelegate.swift.
    HCCAppServices.shared.register(self)
    HCCWidgetBridge.publish(from: self)
    HCCStrainLiveActivityController.shared.sync(from: self)
  }

  /// Rebuild every published property from whatever is cached. Cheap and pure —
  /// safe to call from `refreshHealthDashboardSnapshots()` on any screen appear.
  func rebuildHCCDashboardState() {
    let day = hcc.lastRequestedDay ?? Self.hccDayKey(Date())
    let home = hcc.homeByDate[day] ?? hcc.homeByDate.values.first

    healthDashboardExploreSnapshots = [
      hccScoreSnapshot(route: .sleep, home: home),
      hccScoreSnapshot(route: .recovery, home: home),
      hccScoreSnapshot(route: .strain, home: home),
      hccHealthMonitorSnapshot(),
    ]
    // Cloud mode offers no stress, cardio-load, energy-bank, packet-input,
    // algorithm, reference or calibration surface — the server does not compute
    // them. Leaving them out of these arrays is what hides them on Home and
    // Health rather than showing a row that can never fill.
    healthDashboardAlgorithmSnapshots = []
    healthDashboardVitalSnapshots = hccVitalSnapshots()
    primarySleepDetail = hccPrimarySleepDetail()
    healthDashboardCardioLoadDays = hccCardioLoadDays()

    healthDashboardStepsText = "--"
    healthDashboardStepsStatus = Self.hccNotSyncedReason
    healthDashboardStepsSource = .unavailable(Self.hccNotSyncedReason)
    healthDashboardActiveEnergyText = "--"
    healthDashboardActiveEnergyStatus = Self.hccNotSyncedReason
    healthDashboardActiveEnergySource = .unavailable(Self.hccNotSyncedReason)

    catalogStatus = "Command Center"
    catalogSource = .cloud("Command Center read API")
    packetInputStatus = "Cloud"
    packetScoreStatus = "Cloud"
  }

  static let hccNotSyncedReason = "Not synced by Command Center yet"

  /// Tell SwiftUI that `hcc` is about to change.
  ///
  /// Views observe `HealthDataStore`, but `hcc` is a plain (non-`@Published`)
  /// reference on it, so mutating the box fires nothing on its own. The ring
  /// path got away with that because it always ended in `rebuildHCCDashboardState()`,
  /// which writes `@Published` properties. The design screens read the typed
  /// DTOs straight off `hcc`, so every mutation path announces itself here —
  /// BEFORE it mutates, which is the contract `ObservableObject` expects.
  func hccWillChange() {
    objectWillChange.send()
  }
}

// ── Per-date access ──────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// The three ring snapshots for a day the cache already holds, in the order
  /// Home draws them (sleep, recovery, strain). `nil` means "not fetched yet" —
  /// the caller keeps its existing rings and asks for a refresh.
  func hccScoreSnapshots(for date: Date) -> [HealthMetricSnapshot]? {
    guard let home = hcc.homeByDate[Self.hccDayKey(date)] else { return nil }
    return [
      hccScoreSnapshot(route: .sleep, home: home),
      hccScoreSnapshot(route: .recovery, home: home),
      hccScoreSnapshot(route: .strain, home: home),
    ]
  }

  /// Strain for one day, on the server's own 0–21 scale (`unit == "/21"`); the
  /// Home dial converts that to a percent itself.
  func hccStrainSnapshot(for date: Date) -> HealthMetricSnapshot? {
    guard let home = hcc.homeByDate[Self.hccDayKey(date)] else { return nil }
    return hccScoreSnapshot(route: .strain, home: home)
  }

  /// One cloud snapshot for a route the Health shell asks about directly.
  func hccSnapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    let day = hcc.lastRequestedDay ?? Self.hccDayKey(Date())
    let home = hcc.homeByDate[day] ?? hcc.homeByDate.values.first
    switch route {
    case .sleep, .recovery, .strain:
      return hccScoreSnapshot(route: route, home: home)
    case .healthMonitor:
      return hccHealthMonitorSnapshot()
    default:
      return hccUnsupportedRouteSnapshot(route)
    }
  }

  /// Home's "Missing Data" list, built from the server's own reasons rather
  /// than the bridge's "capture more packets" copy, which is meaningless here.
  func hccMissingDataItems() -> [HomeMissingDataItem] {
    let day = hcc.lastRequestedDay ?? Self.hccDayKey(Date())
    guard let home = hcc.homeByDate[day] ?? hcc.homeByDate.values.first else {
      return []
    }
    return [(HealthRoute.sleep, "sleep"), (.recovery, "recovery"), (.strain, "strain")]
      .compactMap { route, key -> HomeMissingDataItem? in
        guard let score = home.score(key), score.calibrating || score.value == nil else { return nil }
        let base = Self.hccBaseSnapshot(for: route)
        return HomeMissingDataItem(
          id: "hcc-\(key)",
          title: score.label,
          detail: Self.hccNeutralCopy(score.reason) ?? "Your Command Center has not scored this yet.",
          systemImage: base.systemImage,
          tint: OpenVitalsTheme.routeTint(route),
          route: route
        )
      }
  }

  /// Rows for the Health Monitor grid, one per `/vitals` stream.
  func hccVitalSnapshots() -> [HealthMetricSnapshot] {
    Self.hccVitalRows.compactMap { row in
      guard let series = hcc.vitals.first(where: { $0.slug == row.slug }) else { return nil }
      let base = Self.hccVitalBase(
        id: row.id,
        title: Self.hccNeutralCopy(series.label) ?? series.label,
        unit: series.unit ?? ""
      )
      let trend = Self.hccVitalTrend(base: base, series: series)

      guard let latest = series.latest else {
        return Self.hccSnapshot(
          base: base,
          value: "--",
          unit: series.unit ?? "",
          status: "No data",
          freshness: "Not recorded",
          provenance: "Command Center",
          source: .unavailable("Your Command Center has no \(series.label.lowercased()) readings on record."),
          trend: trend
        )
      }

      return Self.hccSnapshot(
        base: base,
        value: Self.hccValueText(latest.value, slug: row.slug, unit: nil),
        unit: series.unit ?? "",
        status: Self.hccBaselineStatus(series: series, latest: latest),
        freshness: Self.hccDayLabel(latest.t),
        provenance: "Command Center · \(HCCCopy.originLabel(nil))",
        source: .cloudDeviceSensor("Command Center · \(series.slug)"),
        trend: trend
      )
    }
  }

  /// The server's value for one score on the day being shown, or nil when it is
  /// calibrating or absent. The number itself, not a rendering of it.
  func hccScoreValue(for route: HealthRoute) -> Double? {
    let day = hcc.lastRequestedDay ?? Self.hccDayKey(Date())
    guard let home = hcc.homeByDate[day] ?? hcc.homeByDate.values.first,
          let score = home.score(Self.hccScoreKey(for: route)),
          !score.calibrating
    else {
      return nil
    }
    return score.value
  }

  /// The five Recovery stat cards, from `/vitals`. Returns "--" rather than a
  /// stand-in whenever the stream has no latest point.
  func hccVitalDisplayText(slug: String) -> String {
    guard let series = hcc.vitals.first(where: { $0.slug == slug }),
          let latest = series.latest
    else {
      return "--"
    }
    return Self.hccValueText(latest.value, slug: slug, unit: series.unit)
  }
}

// ── Snapshot builders ────────────────────────────────────────────────────────

@MainActor
private extension HealthDataStore {
  /// One of the three headline scores as the shared snapshot type.
  func hccScoreSnapshot(route: HealthRoute, home: HCCHome?) -> HealthMetricSnapshot {
    let base = Self.hccBaseSnapshot(for: route)
    let key = Self.hccScoreKey(for: route)
    let unit = route == .strain ? "/21" : "%"
    // A value-less row carries the percent unit even for strain: "--" needs no
    // scale, and "-- /21" is what the dial would otherwise try to read a number
    // out of.
    let emptyUnit = "%"
    let trend = hccScoreTrend(route: route, base: base)

    guard let score = home?.score(key) else {
      return Self.hccSnapshot(
        base: base,
        value: "--",
        unit: emptyUnit,
        status: "No data",
        freshness: home.map { Self.hccDayLabel($0.date) } ?? "Not loaded",
        provenance: "Command Center",
        source: .unavailable("Your Command Center has no \(base.title.lowercased()) score on record."),
        trend: trend
      )
    }

    let originLabel = HCCCopy.originLabel(score.origin)
    let dayLabel = score.day.map(Self.hccDayLabel) ?? (home.map { Self.hccDayLabel($0.date) } ?? "Unknown day")
    let freshness = score.stale ? "\(dayLabel) · stale" : dayLabel

    // A calibrating score, or one the server has no value for, is not a number
    // to show — the reason sentence replaces it.
    guard !score.calibrating, let value = score.value else {
      return Self.hccSnapshot(
        base: base,
        value: "--",
        unit: emptyUnit,
        status: score.calibrating ? "Calibrating" : "No data",
        freshness: freshness,
        provenance: "Command Center · \(originLabel)",
        source: .unavailable(
          Self.hccNeutralCopy(score.reason) ?? "Your Command Center is still calibrating this score."
        ),
        trend: trend
      )
    }

    return Self.hccSnapshot(
      base: base,
      value: route == .strain
        ? Self.hccDecimalText(value, fractionDigits: 1)
        : Self.hccDecimalText(value, fractionDigits: 0),
      unit: unit,
      status: Self.hccStatusWord(score.status),
      freshness: freshness,
      provenance: "Command Center · \(originLabel)",
      source: .cloud("Command Center · \(originLabel)"),
      trend: trend
    )
  }

  /// The Health Monitor tile, which in cloud mode summarises how many vital
  /// streams actually reported rather than showing a live BLE heart rate.
  func hccHealthMonitorSnapshot() -> HealthMetricSnapshot {
    let base = Self.hccBaseSnapshot(for: .healthMonitor)
    let reporting = hcc.vitals.filter { $0.latest != nil }
    guard !reporting.isEmpty else {
      return Self.hccSnapshot(
        base: base,
        value: "--",
        unit: "",
        status: "No vitals",
        freshness: "Not loaded",
        provenance: "Command Center",
        source: .unavailable("Your Command Center has no wearable vitals on record."),
        trend: Self.hccEmptyTrend(base: base)
      )
    }
    let latestDay = reporting.compactMap { $0.latest?.t }.max()
    return Self.hccSnapshot(
      base: base,
      value: "\(reporting.count)",
      unit: reporting.count == 1 ? "stream" : "streams",
      status: "Reporting",
      freshness: latestDay.map(Self.hccDayLabel) ?? "Unknown day",
      provenance: "Command Center · \(HCCCopy.originLabel(nil))",
      source: .cloudDeviceSensor("Command Center vitals"),
      trend: Self.hccEmptyTrend(base: base)
    )
  }

  /// The night as the shared sleep detail model.
  func hccPrimarySleepDetail() -> PrimarySleepDetail? {
    guard let night = hcc.sleep else { return nil }
    // Only the night that belongs to the day being viewed. `/sleep/latest`
    // answers with the most recent night on record, which on a day with no
    // sleep yet is an OLDER night — publishing it would put last week's hours
    // and score under today's date. The picker fetches that day directly.
    guard night.date == (hcc.lastRequestedDay ?? Self.hccDayKey(Date())) else { return nil }
    let source = HealthDataSource.cloudDeviceSensor(
      "Command Center · \(HCCCopy.sourceLabel(night.source))"
    )
    let stages = Self.hccSleepSegments(night: night, source: source)

    let totalMinutes = night.stages.totalH.map { $0 * 60 }
    let inBedMinutes: Double? = {
      guard let total = night.stages.totalH else { return nil }
      return (total + (night.stages.awakeH ?? 0)) * 60
    }()

    return PrimarySleepDetail(
      id: "hcc-sleep-\(night.date)",
      dateLabel: Self.hccDayLabel(night.date),
      // The server sends stage totals, not a clock window, unless the stored
      // payload carried a real timeline. Nothing is invented to fill these.
      startLabel: stages.first.map(\.startLabel) ?? "--",
      endLabel: stages.last.map(\.endLabel) ?? "--",
      durationText: totalMinutes.map(HealthDataStore.minutesText) ?? "--",
      timeInBedText: inBedMinutes.map(HealthDataStore.minutesText) ?? "--",
      scoreText: night.performance.map { Self.hccDecimalText($0, fractionDigits: 0) } ?? "--",
      qualityText: Self.hccSleepQualityText(night),
      source: source,
      stages: stages
    )
  }

  /// The last seven days of strain, for the existing weekly chart.
  func hccCardioLoadDays() -> [CardioLoadDay] {
    hcc.scoreDays.suffix(7).compactMap { day in
      guard let strain = day.strain else { return nil }
      let originLabel = HCCCopy.originLabel(strain.origin)
      return CardioLoadDay(
        id: "hcc-strain-\(day.date)",
        dateLabel: Self.hccDayLabel(day.date),
        load: strain.value,
        status: "Strain",
        // Cloud strain is a whole-day score, not a session; there is no honest
        // duration to print next to it.
        durationText: "--",
        percent: min(max(strain.value / 21, 0), 1),
        source: .cloud("Command Center · \(originLabel)")
      )
    }
  }

  func hccUnsupportedRouteSnapshot(_ route: HealthRoute) -> HealthMetricSnapshot {
    let base = Self.hccBaseSnapshot(for: route)
    return Self.hccSnapshot(
      base: base,
      value: "--",
      unit: base.unit,
      status: "Not in cloud mode",
      freshness: "Not available",
      provenance: "Command Center",
      source: .unavailable("Your Command Center does not compute \(base.title.lowercased())."),
      trend: Self.hccEmptyTrend(base: base)
    )
  }

  /// 14 points of ring history for a score route.
  func hccScoreTrend(route: HealthRoute, base: HealthMetricSnapshot) -> HealthTrendModel {
    let points: [HealthTrendPoint] = hcc.scoreDays.compactMap { day in
      let merged: HCCMergedScore?
      switch route {
      case .sleep: merged = day.sleepPerformance
      case .recovery: merged = day.recovery
      case .strain: merged = day.strain
      default: merged = nil
      }
      guard let merged else { return nil }
      return HealthTrendPoint(label: HealthDataStore.hccShortDayLabel(day.date), value: merged.value)
    }
    return HealthDataStore.hccTrend(base: base, points: points, rangeLabel: "Last 14 days")
  }
}

// ── Formatting and static helpers ────────────────────────────────────────────

extension HealthDataStore {
  /// The device's current civil day as a `YYYY-MM-DD` key.
  ///
  /// Only ever used to ask the server for a day and to look one up in the
  /// cache — the value a day carries is always the one the server bucketed.
  nonisolated static func hccDayKey(_ date: Date) -> String {
    hccDayKeyFormatter(for: hccInstanceTimeZone).string(from: date)
  }

  /// The zone the SERVER buckets civil days in.
  ///
  /// This is the instance's timezone, not the phone's. The server decides which
  /// civil day a reading belongs to in ITS zone, and `?date=` on `/home`,
  /// `/activities`, `/sleep` and `/insights` is read in that same zone — so a
  /// phone in a different one that asked with its own day key would request the
  /// wrong day on every one of them. Anyone travelling east or west far enough
  /// to cross the date boundary would silently see yesterday's or tomorrow's
  /// numbers under today's heading.
  nonisolated static var hccInstanceTimeZone: TimeZone { HCCInstanceZone.current }

  /// A Gregorian calendar fixed to the instance zone, for day arithmetic.
  nonisolated static var hccInstanceCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = hccInstanceTimeZone
    return calendar
  }

  /// "Today" / "Yesterday" / "Aug 25" for a server day key.
  ///
  /// The key is read as local midnight purely so `isDateInToday` can answer;
  /// no value is re-bucketed by doing this.
  /// "Today" / "Yesterday" / "Aug 25" for a server day key.
  ///
  /// Decided by comparing day KEYS rather than `Date`s: "is this the same civil
  /// day" is a question about the instance's calendar, and the string form is
  /// the one thing that already carries that answer. `ScoreDateTimeline`'s
  /// version is not reused because its fallback branch formats in the device
  /// zone, which is the very thing being corrected here.
  nonisolated static func hccDayLabel(_ dayKey: String) -> String {
    let now = Date()
    if dayKey == hccDayKey(now) { return "Today" }
    if let yesterday = hccInstanceCalendar.date(byAdding: .day, value: -1, to: now),
       dayKey == hccDayKey(yesterday) {
      return "Yesterday"
    }
    return hccShortDayLabel(dayKey)
  }

  nonisolated static func hccShortDayLabel(_ dayKey: String) -> String {
    guard let date = hccLocalDate(fromDayKey: dayKey) else { return dayKey }
    // `.formatted` would otherwise render instance-midnight in the DEVICE zone,
    // which is a day early for anyone west of the instance.
    var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
    style.timeZone = hccInstanceTimeZone
    return date.formatted(style)
  }

  /// A day key back to the instant of its midnight IN THE INSTANCE ZONE. Only
  /// ever used to produce a label; no value is re-bucketed by it.
  nonisolated static func hccLocalDate(fromDayKey dayKey: String) -> Date? {
    hccDayKeyFormatter(for: hccInstanceTimeZone).date(from: dayKey)
  }

  nonisolated static func hccClockText(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }

  /// `nominal` / `watch` / `alert` as the words the cards already use.
  /// Server copy, with the manufacturer taken out.
  ///
  /// The read API names the band in its calibration sentences and in the basis
  /// line under an optimal range. This fork's interface does not (AGENTS.md),
  /// so the brand token is rewritten to the neutral label — the sentence itself
  /// is the honest explanation and is kept word for word otherwise.
  nonisolated static func hccNeutralCopy(_ text: String?) -> String? {
    guard let text else { return nil }
    var out = text
    for token in ["WHOOP", "Whoop", "whoop"] {
      out = out.replacingOccurrences(of: token, with: HCCCopy.originLabel("whoop"))
    }
    return out
  }

  nonisolated static func hccStatusWord(_ status: String?) -> String {
    switch status {
    case "nominal": "Green"
    case "watch": "Yellow"
    case "alert": "Red"
    default: "Recorded"
    }
  }

  nonisolated static func hccDecimalText(_ value: Double, fractionDigits: Int) -> String {
    String(format: "%.\(fractionDigits)f", value)
  }

  nonisolated static func hccSignedText(_ value: Double, fractionDigits: Int) -> String {
    let text = hccDecimalText(abs(value), fractionDigits: fractionDigits)
    return value < 0 ? "−\(text)" : "+\(text)"
  }

  /// Display precision per stream — a resting HR of "49.0" reads as false
  /// precision, an HRV of "84" loses nothing.
  nonisolated static func hccValueText(_ value: Double, slug: String, unit: String?) -> String {
    let digits: Int
    switch slug {
    case "resting_hr": digits = 0
    default: digits = 1
    }
    let text = hccDecimalText(value, fractionDigits: digits)
    guard let unit, !unit.isEmpty else { return text }
    return unit == "%" ? "\(text)%" : "\(text) \(unit)"
  }

  /// The status line under a vital: how far the latest point sits from the
  /// personal baseline, which is the reading that matters for these streams.
  nonisolated static func hccBaselineStatus(series: HCCVitalSeries, latest: HCCVitalLatest) -> String {
    guard let delta = latest.deltaVsBaseline ?? series.deltaVsBaseline, let baseline = series.baseline else {
      return "No baseline yet"
    }
    let digits = series.slug == "resting_hr" ? 0 : 1
    let unit = series.unit.map { " \($0)" } ?? ""
    return "\(hccSignedText(delta, fractionDigits: digits))\(unit) vs \(baseline.n)-night baseline"
  }

  nonisolated static func hccSleepQualityText(_ night: HCCSleepNight) -> String {
    var parts: [String] = []
    if let need = night.needH { parts.append("Need \(hccDecimalText(need, fractionDigits: 1)) h") }
    if let debt = night.debtH { parts.append("Debt \(hccDecimalText(debt, fractionDigits: 1)) h") }
    if let performance = night.performance {
      parts.append("Performance \(hccDecimalText(performance, fractionDigits: 0))%")
    }
    parts.append(HCCCopy.sourceLabel(night.source))
    return parts.joined(separator: " · ")
  }

  /// A real stage timeline where the server sent one, otherwise ONE row saying
  /// these are totals. Stage boundaries are never inferred from durations.
  @MainActor
  static func hccSleepSegments(night: HCCSleepNight, source: HealthDataSource) -> [HealthSleepStageSegment] {
    if let segments = night.segments, !segments.isEmpty {
      return segments.enumerated().compactMap { index, segment in
        guard let start = HCCTime.instant(segment.start), let end = HCCTime.instant(segment.end) else {
          return nil
        }
        return HealthSleepStageSegment(
          id: "hcc-\(night.date)-\(index)",
          stage: segment.stage,
          startLabel: hccClockText(start),
          endLabel: hccClockText(end),
          durationMinutes: max(end.timeIntervalSince(start) / 60, 0),
          confidence: nil,
          source: source
        )
      }
    }
    guard let total = night.stages.totalH else { return [] }
    return [
      HealthSleepStageSegment(
        id: "hcc-\(night.date)-totals",
        stage: "totals only",
        startLabel: "--",
        endLabel: "--",
        durationMinutes: total * 60,
        confidence: nil,
        source: source
      ),
    ]
  }

  /// 30 points of one vital stream.
  @MainActor
  static func hccVitalTrend(base: HealthMetricSnapshot, series: HCCVitalSeries) -> HealthTrendModel {
    let points = series.series.map {
      HealthTrendPoint(label: hccShortDayLabel($0.t), value: $0.value)
    }
    var range = "Last \(points.count) readings"
    if let baseline = series.baseline {
      range = "\(baseline.from) to \(baseline.to)"
    }
    return hccTrend(base: base, points: points, rangeLabel: range, note: hccNeutralCopy(series.optimal?.basis))
  }

  @MainActor
  static func hccEmptyTrend(base: HealthMetricSnapshot) -> HealthTrendModel {
    hccTrend(base: base, points: [], rangeLabel: "No history")
  }

  /// Trend models built here say where the points came from and stop; the
  /// bridge's generic `trend(...)` helper writes a canned "stable baseline"
  /// analysis that would be a claim nobody made.
  @MainActor
  static func hccTrend(
    base: HealthMetricSnapshot,
    points: [HealthTrendPoint],
    rangeLabel: String,
    note: String? = nil
  ) -> HealthTrendModel {
    let summary = points.isEmpty
      ? "No readings on record."
      : "\(points.count) readings from your Command Center."
    let analysis = points.isEmpty
      ? "Your Command Center has not recorded this yet."
      : [
          "Every point is a value your Command Center already scored; nothing is recomputed on this phone.",
          note,
        ].compactMap { $0 }.joined(separator: " ")
    return HealthTrendModel(
      id: base.trend.id,
      title: base.title,
      rangeLabel: rangeLabel,
      summary: summary,
      analysis: analysis,
      resources: [],
      points: points
    )
  }

  @MainActor
  static func hccSnapshot(
    base: HealthMetricSnapshot,
    value: String,
    unit: String,
    status: String,
    freshness: String,
    provenance: String,
    source: HealthDataSource,
    trend: HealthTrendModel
  ) -> HealthMetricSnapshot {
    HealthMetricSnapshot(
      id: base.id,
      route: base.route,
      group: base.group,
      title: base.title,
      value: value,
      unit: unit,
      status: status,
      freshness: freshness,
      provenance: provenance,
      source: source,
      systemImage: base.systemImage,
      tint: OpenVitalsTheme.routeTint(base.route),
      trend: trend
    )
  }

  @MainActor
  static func hccBaseSnapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    baseLandingSnapshots.first { $0.route == route } ?? baseLandingSnapshots[0]
  }

  /// The `/home` score key for a route. `sleep` is the server's key for what
  /// the rings call sleep performance.
  nonisolated static func hccScoreKey(for route: HealthRoute) -> String {
    switch route {
    case .recovery: "recovery"
    case .strain: "strain"
    default: "sleep"
    }
  }

  /// `/vitals` slug → the Health Monitor row id the rest of the app already
  /// keys off (tapping "resting-hrv" opens its trend sheet, and so on).
  nonisolated static var hccVitalRows: [(slug: String, id: String)] {
    [
      (slug: "resting_hr", id: "resting-hr"),
      (slug: "hrv_sdnn", id: "resting-hrv"),
      (slug: "respiratory_rate", id: "respiratory-rate"),
      (slug: "blood_oxygen", id: "oxygen-saturation"),
      (slug: "wrist_temp", id: "wrist-temperature"),
    ]
  }

  @MainActor
  static func hccVitalBase(id: String, title: String, unit: String) -> HealthMetricSnapshot {
    let base = baseHealthMonitorSnapshots.first { $0.id == id } ?? baseHealthMonitorSnapshots[0]
    // The title comes from the server so an instance that renamed a metric is
    // reflected here; everything else (icon, route, grouping) is the app's.
    return HealthMetricSnapshot(
      id: base.id,
      route: base.route,
      group: base.group,
      title: title,
      value: base.value,
      unit: unit,
      status: base.status,
      freshness: base.freshness,
      provenance: base.provenance,
      source: base.source,
      systemImage: base.systemImage,
      tint: base.tint,
      trend: base.trend
    )
  }

  private nonisolated static func hccDayKeyFormatter(for zone: TimeZone) -> DateFormatter {
    HCCDayKeyFormatter.shared(for: zone)
  }
}

/// Formatters for the server's civil day keys, one per timezone.
///
/// Fixed POSIX locale so a device set to a non-Gregorian calendar still reads
/// `2026-09-02` correctly. The timezone is the INSTANCE's, because these keys
/// are the server's buckets (see `hccInstanceTimeZone`).
///
/// One instance per zone, configured once and never mutated afterwards:
/// `DateFormatter` is safe to *use* from several threads but not to reconfigure
/// under them, and these helpers are `nonisolated`, so a single shared
/// formatter whose `timeZone` was reassigned when the instance loaded would be
/// a data race.
private enum HCCDayKeyFormatter {
  private static let lock = NSLock()
  private static var byZone: [String: DateFormatter] = [:]

  static func shared(for zone: TimeZone) -> DateFormatter {
    lock.lock()
    defer { lock.unlock() }
    if let cached = byZone[zone.identifier] { return cached }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd"
    byZone[zone.identifier] = formatter
    return formatter
  }
}

/// The instance's timezone, readable from any thread.
///
/// `HCCSession` is `@MainActor` and its `account` is the canonical copy, but the
/// day-key helpers are `nonisolated` and run on whatever thread a request is
/// built on, so they cannot hop to the main actor to ask. This reads the same
/// account summary `HCCSession` persists at sign-in, straight out of
/// `UserDefaults` (which is thread-safe), and is refreshed from `/instance` on
/// every read that fetches it.
///
/// Resolution order: what `/instance` last said, then the summary stored at
/// sign-in, then the device zone — the last being a guess, used only before the
/// app has ever been told which instance it talks to.
enum HCCInstanceZone {
  private static let lock = NSLock()
  private static var cached: TimeZone?

  /// Record the zone the server named. Ignores an identifier the device has no
  /// zone database entry for rather than falling back silently.
  static func set(_ identifier: String?) {
    guard let identifier, let zone = TimeZone(identifier: identifier) else { return }
    lock.lock()
    cached = zone
    lock.unlock()
  }

  static var current: TimeZone {
    lock.lock()
    let hit = cached
    lock.unlock()
    if let hit { return hit }
    if let stored = storedAccountZone() {
      set(stored.identifier)
      return stored
    }
    return .current
  }

  /// Whether anything has told us the zone yet — a cached answer or the
  /// summary stored at sign-in. False only before the app has ever signed in
  /// (or under the DEBUG token injection, which skips the sign-in that would
  /// have persisted the summary).
  static var isKnown: Bool {
    lock.lock()
    let hit = cached
    lock.unlock()
    return hit != nil || storedAccountZone() != nil
  }

  /// Test seam and sign-out path: forget what we were told.
  static func reset() {
    lock.lock()
    cached = nil
    lock.unlock()
  }

  private static func storedAccountZone() -> TimeZone? {
    guard let data = UserDefaults.standard.data(forKey: HCCProviderSettings.accountKey),
          let summary = try? JSONDecoder().decode(HCCAccountSummary.self, from: data)
    else {
      return nil
    }
    return TimeZone(identifier: summary.timezone)
  }
}

// ── Fetch plumbing ───────────────────────────────────────────────────────────

/// Turns a throwing call into a value so four of them can run under `async let`
/// and be inspected individually — one stream failing must not blank the other
/// three.
private enum HCCFetch {
  static func result<T>(_ work: () async throws -> T) async -> Result<T, HCCAPIError> {
    do {
      return .success(try await work())
    } catch let error as HCCAPIError {
      return .failure(error)
    } catch {
      return .failure(.transport(error))
    }
  }

  /// The same thing, skipped entirely when `enabled` is false. `nil` therefore
  /// means "not asked for on this pass" — distinct from a failure, so a read
  /// that was deliberately skipped never shows up as an error on the status
  /// line or blanks a cached payload.
  static func optional<T>(_ enabled: Bool, _ work: () async throws -> T) async -> Result<T, HCCAPIError>? {
    guard enabled else { return nil }
    return await result(work)
  }
}

private extension Result {
  var failure: Failure? {
    if case let .failure(error) = self { return error }
    return nil
  }
}

private extension HCCAPIError {
  /// The one distinction the refresh path draws: a dead token is a session
  /// problem to hand back to `HCCSession`, everything else is a data problem
  /// to render as unavailable.
  var isUnauthorized: Bool {
    if case .unauthorized = self { return true }
    return false
  }
}

// ── Reads the design screens make of the cache ───────────────────────────────

@MainActor
extension HealthDataStore {
  /// The open cards for the day on screen.
  ///
  /// `/home`'s `flags` are the day's own cards and lead; the standing
  /// `/insights` feed follows, de-duplicated by id. Anything dismissed on this
  /// device, and anything the server has already moved out of `ACTIVE`, is
  /// filtered out — a dismissal must not come back when Home refetches.
  func hccOpenInsights() -> [HCCInsightCard] {
    Self.hccVisibleInsights(hcc.insights, dismissed: hcc.dismissedInsightIds)
  }

  /// The open cards written ABOUT one civil day — what Home shows under the
  /// rings, so a day being browsed shows that day's cards and not today's.
  ///
  /// Empty covers two different things the caller may want to tell apart: the
  /// day has no dated cards, or the day has not been read yet. Use
  /// `hcc.insightsByDate[dayKey] == nil` for the second.
  func hccOpenInsights(for dayKey: String) -> [HCCInsightCard] {
    Self.hccVisibleInsights(hcc.insightsByDate[dayKey] ?? [], dismissed: hcc.dismissedInsightIds)
  }

  /// ACTIVE, not dismissed on this device, de-duplicated — the one place that
  /// rule lives, so the day list and the feed can never drift apart.
  private static func hccVisibleInsights(
    _ cards: [HCCInsightCard],
    dismissed: Set<String>
  ) -> [HCCInsightCard] {
    var seen = Set<String>()
    return cards.filter { card in
      card.status == "ACTIVE" && !dismissed.contains(card.id) && seen.insert(card.id).inserted
    }
  }

  /// The day's activities, or `nil` when that day has not been read yet — the
  /// caller shows a loading state rather than an empty list it cannot vouch for.
  func hccActivities(for dayKey: String) -> [HCCActivity]? {
    hcc.activitiesByDate[dayKey]
  }

  /// The activities for the day currently on screen.
  func hccActivitiesForSelectedDay() -> [HCCActivity]? {
    hccActivities(for: hcc.lastRequestedDay ?? Self.hccDayKey(Date()))
  }

  /// The device the server currently believes for display, if any.
  func hccDrivingDevice() -> HCCDevice? {
    hcc.devices.first { $0.drives }
  }
}

// ── Writes ───────────────────────────────────────────────────────────────────
//
// One method per thing a screen can change. Each follows the same shape:
// announce the change, apply it locally so the tap feels immediate, call the
// server, then reconcile with what the server actually stored. A failure rolls
// the local edit back and puts the server's own message on `hcc.lastError` —
// the screens read that, so a write that did not happen never looks like one
// that did.

@MainActor
extension HealthDataStore {
  /// Move an insight card out of the open feed.
  @discardableResult
  func dismissInsight(id: String) async -> Bool {
    hccWillChange()
    hcc.dismissedInsightIds.insert(id)
    hcc.lastError = nil

    do {
      _ = try await HCCSession.shared.client.setInsightStatus(id: id, status: "DISMISSED")
      // Reconcile: drop it from the standing feed too, so a later rebuild of
      // the list does not depend on the dismissed-id set alone.
      hccWillChange()
      hcc.insights.removeAll { $0.id == id }
      for (day, cards) in hcc.insightsByDate {
        hcc.insightsByDate[day] = cards.filter { $0.id != id }
      }
      return true
    } catch {
      hccWillChange()
      hcc.dismissedInsightIds.remove(id)
      hccRecord(error)
      return false
    }
  }

  /// Front one wrist source when two report the same stream. `nil` clears the
  /// override and restores the server's standing priority order.
  @discardableResult
  func setPreferredSource(_ source: String?) async -> Bool {
    let previous = hcc.preferredSource
    hccWillChange()
    hcc.preferredSource = source
    hcc.lastError = nil

    do {
      let response = try await HCCSession.shared.client.setPreferredSource(source)
      hccWillChange()
      hcc.preferredSource = response.preferredSource
      // Which device "drives" and which numbers `/home` resolves both change
      // with this, so the day is re-read rather than patched locally.
      await refreshFromHCC(date: Self.hccLocalDate(fromDayKey: hcc.lastRequestedDay ?? ""), force: true)
      return true
    } catch {
      hccWillChange()
      hcc.preferredSource = previous
      hccRecord(error)
      return false
    }
  }

  /// Save the Home tile order.
  @discardableResult
  func saveDashboard(tiles: [String]) async -> Bool {
    let previous = hcc.dashboard
    hccWillChange()
    if let previous {
      hcc.dashboard = HCCDashboardPrefs(tiles: tiles, isDefault: false, catalog: previous.catalog)
    }
    hcc.lastError = nil

    do {
      let saved = try await HCCSession.shared.client.saveDashboard(tiles: tiles)
      hccWillChange()
      hcc.dashboard = saved
      return true
    } catch {
      hccWillChange()
      hcc.dashboard = previous
      hccRecord(error)
      return false
    }
  }

  /// Save the wake target. The server row is the record of INTENT; scheduling
  /// the actual alarm on this device is a later phase.
  @discardableResult
  func saveAlarm(_ alarm: HCCAlarm) async -> Bool {
    let previous = hcc.alarm
    let previousIsDefault = hcc.alarmIsDefault
    hccWillChange()
    hcc.alarm = alarm
    hcc.alarmIsDefault = false
    hcc.lastError = nil

    do {
      let saved = try await HCCSession.shared.client.saveAlarm(alarm)
      hccWillChange()
      hcc.alarm = saved.alarm
      hcc.alarmIsDefault = saved.isDefault
      // Tonight's need is sized against the wake time, so the plan is restale.
      if let plan = try? await HCCSession.shared.client.sleepPlan() {
        hccWillChange()
        hcc.sleepPlan = plan
      }
      return true
    } catch {
      hccWillChange()
      hcc.alarm = previous
      hcc.alarmIsDefault = previousIsDefault
      hccRecord(error)
      return false
    }
  }

  /// Log a manual activity. Returns the server's stored row — including the
  /// strain it computed or estimated — or `nil` when the write failed.
  ///
  /// No optimistic row is inserted: the list shows strain per activity, and the
  /// server is the only thing that knows whether this one gets a computed value
  /// or an estimate. Showing a placeholder row would be showing a number nobody
  /// produced.
  func addActivity(_ draft: HCCActivityCreate) async -> HCCActivityDetail? {
    hccWillChange()
    hcc.lastError = nil
    do {
      let created = try await HCCSession.shared.client.createActivity(draft)
      await reloadActivities(around: created.activity.startAt)
      return created.activity
    } catch {
      hccWillChange()
      hccRecord(error)
      return nil
    }
  }

  /// Edit a manual activity. An omitted field is left alone (see
  /// `HCCActivityPatch`).
  func updateActivity(id: String, _ patch: HCCActivityPatch) async -> HCCActivityDetail? {
    guard !patch.isEmpty else { return nil }
    hccWillChange()
    hcc.lastError = nil
    do {
      let updated = try await HCCSession.shared.client.updateActivity(id: id, patch)
      await reloadActivities(around: updated.activity.startAt)
      return updated.activity
    } catch {
      hccWillChange()
      hccRecord(error)
      return nil
    }
  }

  /// Delete a manual activity. The server refuses (409) for a provider row,
  /// because the next sync would re-create it — that message is surfaced as-is.
  @discardableResult
  func deleteActivity(id: String) async -> Bool {
    let day = hcc.lastRequestedDay ?? Self.hccDayKey(Date())
    let previous = hcc.activitiesByDate[day]
    hccWillChange()
    hcc.activitiesByDate[day] = previous?.filter { $0.id != id }
    hcc.lastError = nil

    do {
      _ = try await HCCSession.shared.client.deleteActivity(id: id)
      await reloadActivities(day: day)
      return true
    } catch {
      hccWillChange()
      hcc.activitiesByDate[day] = previous
      hccRecord(error)
      return false
    }
  }

  // ── Reconciliation ─────────────────────────────────────────────────────────

  /// Re-read one day's activities from the server, so the list shows the rows
  /// the server actually holds rather than the app's idea of them.
  private func reloadActivities(day: String) async {
    let isToday = day == Self.hccDayKey(Date())
    guard let response = try? await HCCSession.shared.client.activities(date: isToday ? nil : day) else {
      return
    }
    hccWillChange()
    hcc.activitiesByDate[response.date] = response.activities
  }

  /// The same, for the civil day an ISO instant falls on. The day key comes
  /// from the DEVICE calendar only because there is nothing else to go on here;
  /// the response is stored under the day the SERVER answers with.
  private func reloadActivities(around instant: String) async {
    let day = HCCTime.instant(instant).map(Self.hccDayKey) ?? (hcc.lastRequestedDay ?? Self.hccDayKey(Date()))
    await reloadActivities(day: day)
  }

  /// A failed write: a 401 is a session question, anything else is a message
  /// for the screen that asked.
  private func hccRecord(_ error: Error) {
    if let apiError = error as? HCCAPIError {
      if case .unauthorized = apiError {
        HCCSession.shared.handleUnauthorized()
      }
      hcc.lastError = apiError.errorDescription
    } else {
      hcc.lastError = error.localizedDescription
    }
  }
}
