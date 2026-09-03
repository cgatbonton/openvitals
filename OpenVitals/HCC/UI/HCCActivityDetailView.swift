import SwiftUI

// `S.activity` from the approved mockup: one activity, its strain, and the
// zones behind it.
//
// The mockup draws a heart-rate trace on this screen. The API has no HR series
// — the server keeps daily zone-minute rollups, not intraday samples (see
// `src/lib/activities/zones.ts`) — so the card is rendered with a sentence
// saying so rather than a synthesized curve. Drawing a plausible-looking line
// would be fabricating a measurement, which is the one thing this app must
// never do.

// ── Routing ──────────────────────────────────────────────────────────────────

/// Where an activity row goes.
///
/// A sleep row is not a workout detail: the night has its own screen,
/// `HCCSleepView`. Naming that here — rather than letting each caller re-derive
/// it from `kind` — keeps one rule for "which screen does this row open", and
/// gives Home, Strain and this screen a single seam to route through.
enum HCCActivityRoute: Hashable {
  case workout(id: String)
  /// The server's civil day the night belongs to, for `HCCSleepView`.
  case sleep(date: String)

  static func route(for activity: HCCActivity, day: String) -> HCCActivityRoute {
    activity.kind.uppercased() == "SLEEP" ? .sleep(date: day) : .workout(id: activity.id)
  }

  /// The route for an id alone, resolved against the days the store has read.
  ///
  /// Home and Strain carry only the id in their navigation path, and the id
  /// does not say what kind of row it is. Looking it up here is what stops a
  /// night from opening the workout detail — including the derived sleep rows,
  /// which have no `/activities/<id>` to fetch at all. An id the store has not
  /// seen falls through to the workout detail, which loads it and says so if
  /// the server disagrees.
  @MainActor
  static func route(forId id: String, store: HealthDataStore) -> HCCActivityRoute {
    for (day, activities) in store.hcc.activitiesByDate {
      guard let match = activities.first(where: { $0.id == id }) else { continue }
      return route(for: match, day: day)
    }
    return .workout(id: id)
  }
}

/// Resolves a route to its screen.
struct HCCActivityDestinationView: View {
  let route: HCCActivityRoute
  @ObservedObject var store: HealthDataStore

  init(route: HCCActivityRoute, store: HealthDataStore) {
    self.route = route
    self.store = store
  }

  /// The entry point for a caller that has only an id — Home's navigation path
  /// and Strain's activity rows.
  @MainActor
  init(store: HealthDataStore, activityId: String) {
    self.init(route: HCCActivityRoute.route(forId: activityId, store: store), store: store)
  }

  var body: some View {
    switch route {
    case let .workout(id):
      HCCActivityDetailView(store: store, activityId: id)
    case let .sleep(date):
      HCCSleepView(store: store, dayKey: date)
    }
  }
}

// ── Screen ───────────────────────────────────────────────────────────────────

/// One workout's detail.
///
/// The store caches the day's LIST (`HCCActivity`), which carries no zone
/// minutes, no effort and no notes — this screen needs all three. There is no
/// store action for a single detail yet (flagged in the workstream report), so
/// the read goes through `HCCPageLoad` rather than sitting in the view body:
/// the screen still never touches `URLSession`, and moving this to the store
/// later is a change of one call site.
struct HCCActivityDetailView: View {
  @ObservedObject var store: HealthDataStore
  let activityId: String

  @StateObject private var load = HCCPageLoad<HCCActivityDetail>()
  @State private var edited: HCCActivityDetail?
  @State private var showEdit = false

  init(store: HealthDataStore, activityId: String) {
    self.store = store
    self.activityId = activityId
  }

  /// The row on screen: the server's answer to the last write, if there was
  /// one, otherwise what the page loaded.
  private var detail: HCCActivityDetail? { edited ?? load.value }

  var body: some View {
    HCCScreen {
      header
      if let detail {
        hero(detail)
        HCCStat3(items: stats(detail))
        heartRateCard
        zonesCard(detail)
        factsCard(detail)
        notesCard(detail)
      } else if let errorText = load.errorText {
        HCCErrorNote(errorText)
      } else {
        HCCLoadingNote().hccCard()
      }
    }
    .task {
      await load.loadIfNeeded {
        try await HCCSession.shared.client.activity(id: activityId).activity
      }
    }
    .sheet(isPresented: $showEdit) {
      if let detail {
        HCCAddActivitySheet(store: store, editing: detail) { updated in
          edited = updated
        }
      }
    }
  }

  // ── Pieces ─────────────────────────────────────────────────────────────────

  private var header: some View {
    HCCDetailHeader(
      title: detail.map { HCCActivityCopy.title(for: $0.type) } ?? "Activity",
      subtitle: detail.map(subtitle(for:)),
      // Only a hand-logged row can be edited; a provider's row is re-created by
      // the next sync, so offering "Edit" on one would be offering a no-op.
      actionTitle: detail?.source.uppercased() == "MANUAL" ? "Edit" : nil,
      action: { showEdit = true }
    )
  }

  private func subtitle(for detail: HCCActivityDetail) -> String {
    let zone = store.hcc.instance?.timezone
    let start = HCCWallClock.clock(iso: detail.startAt, timezone: zone) ?? HCCFormat.placeholder
    let end = HCCWallClock.clock(iso: detail.endAt, timezone: zone) ?? HCCFormat.placeholder
    return "\(start) – \(end) · \(HCCCopy.sourceLabel(detail.source))"
  }

  private func hero(_ detail: HCCActivityDetail) -> some View {
    HCCRing(
      progress: (detail.strain ?? 0) / HCCTheme.strainMax,
      kind: .strain,
      size: 150,
      stroke: 10,
      ticks: true,
      // No strain from the server means no number here — never a zero standing
      // in for "we do not know".
      value: detail.strain.map { HCCFormat.decimal($0, 1) },
      sub: detail.strainEstimated ? "ESTIMATED" : "STRAIN"
    )
    .frame(maxWidth: .infinity)
    .padding(.top, 6)
    .padding(.bottom, 2)
  }

  private func stats(_ detail: HCCActivityDetail) -> [HCCStat] {
    [
      HCCStat(value: detail.avgHr.map { HCCFormat.decimal($0, 0) } ?? "—", label: "Avg HR"),
      HCCStat(value: detail.maxHr.map { HCCFormat.decimal($0, 0) } ?? "—", label: "Max HR"),
      HCCStat(value: detail.kcal.map { HCCFormat.decimal($0, 0) } ?? "—", label: "kcal"),
    ]
  }

  private var heartRateCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Heart rate")
      HCCFootnote("Heart-rate trace not available for this activity.", size: 12.5)
    }
    .hccCard()
  }

  private func zonesCard(_ detail: HCCActivityDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Time in zones")
      if detail.zoneMin.contains(where: { $0 > 0 }) {
        HCCZoneBars(minutes: detail.zoneMin)
      } else {
        HCCEmptyNote("No zone minutes recorded for this activity.")
      }
    }
    .hccCard()
  }

  private func factsCard(_ detail: HCCActivityDetail) -> some View {
    HCCKeyValueGrid(rows: [
      HCCKeyValue("Duration", HCCWallClock.duration(minutes: detail.durationMin)),
      HCCKeyValue("Distance", HCCActivityCopy.distance(detail.distanceM)),
      HCCKeyValue("Source", HCCCopy.sourceLabel(detail.source)),
      HCCKeyValue("Journal", "Logged as workout"),
    ])
    .hccCard()
  }

  @ViewBuilder
  private func notesCard(_ detail: HCCActivityDetail) -> some View {
    if let notes = detail.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Notes")
        Text(notes)
          .font(HCCTheme.Font.body(size: 12.5))
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
      }
      .hccCard()
    }
  }
}

// ── Copy ─────────────────────────────────────────────────────────────────────

/// Slug → words, and the one unit rendering this screen needs.
enum HCCActivityCopy {
  /// `assault_bike` → "Assault bike". The server's `type` is free text by
  /// design (every provider ships its own sport list), so this is a
  /// presentation rule, not a lookup that can miss.
  static func title(for type: String) -> String {
    let words = type
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return "Activity" }
    return String(first).uppercased() + words.dropFirst()
  }

  /// Metres → km, or the mockup's em dash when the server sent none.
  static func distance(_ metres: Double?) -> String {
    guard let metres, metres > 0 else { return "—" }
    return "\(HCCFormat.decimal(metres / 1000, 1)) km"
  }
}
