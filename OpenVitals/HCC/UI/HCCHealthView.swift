import SwiftUI

/// `S.health` — the Health tab root.
///
/// A thin switch, so that the DEBUG screen host below can render the landing
/// itself without recursing back into this switch. Everything the screen
/// actually does lives in `HCCHealthLanding`, and it lives in its own struct for
/// a concrete reason: a `@StateObject` is only installed when the view that
/// declares it is in the hierarchy, so reaching into another instance for a
/// sub-view left its loaders unobserved and the cards stuck on "Loading…".
struct HCCHealthView: View {
  @ObservedObject var store: HealthDataStore
  // HCC: a tapped push notification lands here — see `pushDestination` below.
  @EnvironmentObject private var router: AppRouter
  @State private var pushDestination: HCCDeepLinkTarget?

  init(store: HealthDataStore) {
    self.store = store
  }

  /// One of the four reference pages, as a navigation value.
  enum Page: Hashable {
    case biomarkers
    case insights
    case genetics
    case protocols
  }

  var body: some View {
    content
      // HCC: presented rather than pushed. The Health tab's `NavigationStack`
      // is built by the shell with no path binding (AppShellView.swift:113-117),
      // so nothing outside a tap can push onto it, and a second stack nested
      // inside it swallows the landing's own `navigationDestination`s. A cover
      // reaches the same screen with the same header and the same `dismiss()`
      // back button; the only visible difference is that it slides up.
      .fullScreenCover(item: $pushDestination) { target in
        HCCPushDestinationView(target: target, store: store)
      }
      .onAppear(perform: consumePushDestination)
      .onChange(of: router.hccPendingHealthDestination) { _, _ in
        consumePushDestination()
      }
  }

  @ViewBuilder
  private var content: some View {
    #if DEBUG
    // HCC: `HCC_DEBUG_OPEN_SCREEN=recovery|sleep|strain|health|biomarkers|
    // insights|genetics|protocols` opens one screen straight from the launch
    // environment, so each can be screenshotted against the mockup without UI
    // automation (`simctl` cannot tap). `HCC_DEBUG_OPEN_DATE` picks the day for
    // the three detail screens. DEBUG only — compiled out of Release, so a
    // shipping build has no environment path into a screen.
    if let screen = HCCDebugScreen.requested {
      HCCDebugScreenHost(screen: screen, store: store)
    } else {
      HCCHealthLanding(store: store)
    }
    #else
    HCCHealthLanding(store: store)
    #endif
  }

  /// Take the pending destination and clear it, so the same notification tapped
  /// twice opens the screen twice rather than the second tap doing nothing.
  private func consumePushDestination() {
    guard let target = router.hccPendingHealthDestination else { return }
    router.hccPendingHealthDestination = nil
    // `settings` is routed to More by the router itself and never arrives here.
    guard target != .settings else { return }
    pushDestination = target
  }
}

/// Where a tapped notification lands: the detail for TODAY, or the Insights
/// page. The day is today's on purpose — a push is about now, and the detail
/// screens resolve `nil` to the current civil day in the instance's zone.
private struct HCCPushDestinationView: View {
  let target: HCCDeepLinkTarget
  @ObservedObject var store: HealthDataStore

  var body: some View {
    Group {
      switch target {
      case .recovery: HCCRecoveryView(store: store, dayKey: nil)
      case .sleep: HCCSleepView(store: store, dayKey: nil)
      case .strain: HCCStrainView(store: store, dayKey: nil)
      case .insights, .settings: HCCInsightsView(store: store)
      }
    }
    // A push can arrive on a cold launch, before any screen has read anything.
    .task {
      guard store.hcc.homeByDate.isEmpty else { return }
      await store.refreshFromHCC()
    }
  }
}

/// The landing itself: four cards into the reference pages, and the wearable
/// monitor strip.
///
/// It deliberately does NOT own a `NavigationStack`: the app shell already wraps
/// the Health tab in one, and a second stack inside it would swallow the pushes.
/// The four pages are registered as destinations here instead, so putting this
/// screen in the shell is a one-line swap.
///
/// The band strip under each vital shows where the latest value sits inside the
/// OPTIMAL band the server published for that stream. Where the server has no
/// two-sided band there is nothing honest to place a marker inside, so the strip
/// renders flat and the marker sits centred rather than implying a position.
struct HCCHealthLanding: View {
  @ObservedObject var store: HealthDataStore

  @StateObject private var biomarkers = HCCPageLoad<HCCBiomarkerPanels>()
  @StateObject private var insights = HCCPageLoad<HCCInsightsResponse>()
  @StateObject private var weekly = HCCPageLoad<HCCWeeklyInsightsResponse>()
  @StateObject private var genetics = HCCPageLoad<HCCGenetics>()
  @StateObject private var protocolList = HCCPageLoad<HCCProtocolsResponse>()

  init(store: HealthDataStore) {
    self.store = store
  }

  typealias Page = HCCHealthView.Page

  // ── Landing ────────────────────────────────────────────────────────────────

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Health", showsBack: false)
      grid
      monitor
    }
    .navigationDestination(for: Page.self) { page in
      switch page {
      case .biomarkers: HCCBiomarkersView(store: store)
      case .insights: HCCInsightsView(store: store)
      case .genetics: HCCGeneticsView(store: store)
      case .protocols: HCCProtocolsView(store: store)
      }
    }
    // Two tasks, not one: the four cards' counts and the monitor's streams come
    // from different places, and making the card reads wait behind a full store
    // refresh left every card saying "Loading…" long after its own payload had
    // arrived.
    .task { await loadSummaries() }
    .task { await loadVitalsIfNeeded() }
  }

  private var grid: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
      HealthCard(page: .biomarkers, icon: "🧪", title: "Biomarkers", subtitle: biomarkersSubtitle)
      HealthCard(page: .insights, icon: "✦", title: "Insights", subtitle: insightsSubtitle)
      HealthCard(page: .genetics, icon: "🧬", title: "Genetics", subtitle: geneticsSubtitle)
      HealthCard(page: .protocols, icon: "◈", title: "Protocols", subtitle: protocolsSubtitle)
    }
  }

  // ── Card subtitles ─────────────────────────────────────────────────────────

  private var biomarkersSubtitle: String {
    guard let panels = biomarkers.value else { return pendingText(biomarkers.isPending) }
    let rows = panels.panels.flatMap(\.metrics)
    let flagged = rows.filter { $0.status == "watch" || $0.status == "alert" }.count
    guard let newest = rows.map(\.lastTestedISO).max(), let date = HCCTime.instant(newest) else {
      return "\(flagged) flagged"
    }
    return "Last panel \(date.formatted(.dateTime.month(.abbreviated).day())) · \(flagged) flagged"
  }

  private var insightsSubtitle: String {
    guard let response = insights.value else { return pendingText(insights.isPending) }
    let open = "\(response.openCount) open"
    return weekly.value?.latest != nil ? "\(open) · weekly ready" : open
  }

  private var geneticsSubtitle: String {
    guard genetics.value != nil else { return pendingText(genetics.isPending) }
    return "Curated variants"
  }

  private var protocolsSubtitle: String {
    guard let response = protocolList.value else { return pendingText(protocolList.isPending) }
    let active = response.protocols.filter { $0.status == "ACTIVE" }.count
    let planned = response.protocols.filter { $0.status == "PLANNED" }.count
    return "\(active) active · \(planned) planned"
  }

  /// "Loading" and "not loaded" are different answers; neither is a count.
  private func pendingText(_ isPending: Bool) -> String {
    isPending ? "Loading…" : "Not loaded"
  }

  // ── Health monitor ─────────────────────────────────────────────────────────

  private var monitorSeries: [HCCVitalSeries] {
    HCCVitalSlug.monitorOrder.compactMap { slug in
      store.hcc.vitals.first { $0.slug == slug }
    }
  }

  private var monitor: some View {
    VStack(alignment: .leading, spacing: 6) {
      HCCLabel("Health monitor", size: 11)
      if monitorSeries.isEmpty {
        HCCEmptyNote("No wearable vitals on record yet.")
      } else {
        ForEach(monitorSeries) { series in
          MonitorRow(series: series)
        }
        HCCFootnote("Marker vs the optimal band from your metric targets.")
          .padding(.top, 8)
      }
    }
    .hccCard()
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  /// The Health tab can be the first screen a launch reaches, so the wearable
  /// streams the monitor draws are pulled if Home has not already.
  private func loadVitalsIfNeeded() async {
    guard store.hcc.vitals.isEmpty else { return }
    await store.refreshFromHCC()
  }

  private func loadSummaries() async {
    await biomarkers.loadIfNeeded { try await HCCSession.shared.client.biomarkers() }
    await insights.loadIfNeeded { try await HCCSession.shared.client.insights(status: "open") }
    await weekly.loadIfNeeded { try await HCCSession.shared.client.weeklyInsights(limit: 1) }
    await genetics.loadIfNeeded { try await HCCSession.shared.client.genetics() }
    await protocolList.loadIfNeeded { try await HCCSession.shared.client.protocols() }
  }
}

// ── Cards ────────────────────────────────────────────────────────────────────

/// `.hcard` — icon, title, and a data-font line at the bottom.
private struct HealthCard: View {
  let page: HCCHealthView.Page
  let icon: String
  let title: String
  let subtitle: String

  var body: some View {
    NavigationLink(value: page) {
      VStack(alignment: .leading, spacing: 8) {
        Text(icon)
          .font(.system(size: 18))
        Text(title)
          .font(HCCTheme.Font.display(size: 16, weight: .medium))
          .tracking(-0.16)
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 4)
        Text(subtitle)
          .font(HCCTheme.Font.data(size: 11))
          .foregroundStyle(HCCTheme.Color.muted)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .fill(HCCTheme.Color.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }
}

// ── Monitor row ──────────────────────────────────────────────────────────────

/// A vital's latest value over the band strip that says where it sits.
private struct MonitorRow: View {
  let series: HCCVitalSeries

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(HCCVitalSlug.label(series))
          .font(HCCTheme.Font.body(size: 12.5))
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        Text(valueText)
          .font(HCCTheme.Font.data(size: 12.5))
          .monospacedDigit()
          .foregroundStyle(HCCTheme.Color.text)
      }
      .padding(.top, 6)

      if let placement {
        HCCBand(position: placement)
      } else {
        // No two-sided optimal band: the shaded window collapses, so the strip
        // is a flat rail and the centred marker is plainly not a reading of
        // "middle of your target".
        HCCBand(position: 0.5, low: 0, high: 0)
      }
    }
  }

  /// The value shown — and the one the marker is placed by, so the two can
  /// never disagree.
  private var displayValue: Double? {
    if series.slug == HCCVitalSlug.wristTemp {
      return series.deltaVsBaseline ?? series.latest?.deltaVsBaseline ?? series.latest?.value
    }
    return series.latest?.value
  }

  private var valueText: String {
    guard let value = displayValue else { return HCCFormat.placeholder }
    let digits = HCCVitalSlug.fractionDigits(series.slug)
    if series.slug == HCCVitalSlug.wristTemp {
      let unit = series.unit.map { $0 == "%" ? "%" : " \($0)" } ?? ""
      return HealthDataStore.hccSignedText(value, fractionDigits: digits) + unit
    }
    return HCCFormat.measurement(value, unit: series.unit, fractionDigits: digits)
  }

  /// Where the value sits in the strip. The `.band` CSS shades 30%–72% of the
  /// rail as the optimal window, so the band's own low and high map onto those
  /// two fractions and everything outside is clamped to the visible rail.
  private var placement: Double? {
    guard let value = displayValue,
          let optimal = series.optimal,
          let low = optimal.low,
          let high = optimal.high,
          high > low
    else {
      return nil
    }
    let fraction = (value - low) / (high - low)
    return min(max(0.30 + fraction * 0.42, 0.02), 0.98)
  }
}

// ── DEBUG screen switch ──────────────────────────────────────────────────────

#if DEBUG
/// The eight screens this workstream owns, addressable from the launch
/// environment. See the comment on `HCCHealthView.body`.
enum HCCDebugScreen: String {
  case recovery
  case sleep
  case strain
  case health
  case biomarkers
  case insights
  case genetics
  case protocols
  // HCC: P3-H — the Apple Watch upload sheet lives on the More screen, which
  // this workstream does not own; this makes it reachable for verification.
  case watchUpload

  static var requested: HCCDebugScreen? {
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_SCREEN"] else { return nil }
    return HCCDebugScreen(rawValue: raw)
  }

  /// `HCC_DEBUG_OPEN_DATE=YYYY-MM-DD` — the day the three detail screens open
  /// on. Absent means today.
  static var requestedDayKey: String? {
    ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_DATE"].flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Renders one requested screen, inside a stack so its header's back button and
/// any pushes behave exactly as they do in the app.
struct HCCDebugScreenHost: View {
  let screen: HCCDebugScreen
  @ObservedObject var store: HealthDataStore

  var body: some View {
    NavigationStack {
      content
    }
    .task {
      // The detail screens load their own day; the Health pages need the store
      // populated for the monitor strip.
      await store.refreshFromHCC(date: HCCDebugScreen.requestedDayKey.flatMap(HealthDataStore.hccLocalDate(fromDayKey:)))
    }
  }

  @ViewBuilder
  private var content: some View {
    let day = HCCDebugScreen.requestedDayKey
    switch screen {
    case .recovery: HCCRecoveryView(store: store, dayKey: day)
    case .sleep: HCCSleepView(store: store, dayKey: day)
    case .strain: HCCStrainView(store: store, dayKey: day)
    case .health: HCCHealthLanding(store: store)
    case .biomarkers: HCCBiomarkersView(store: store)
    case .insights: HCCInsightsView(store: store)
    case .genetics: HCCGeneticsView(store: store)
    case .protocols: HCCProtocolsView(store: store)
    // HCC: P3-H
    case .watchUpload: HCCWatchUploadSheet(uploader: HCCHealthKitUploader.shared)
    }
  }
}
#endif
