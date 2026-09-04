import SwiftUI

struct AppShellView: View {
  @EnvironmentObject private var model: OpenVitalsAppModel
  @EnvironmentObject private var router: AppRouter
  @StateObject private var healthStore = HealthDataStore()
  @StateObject private var moreStore = MoreDataStore()
  @State private var homeSelectedDate = Date()
  // HCC: the Health tab's stack is bound so tapping the Health tab while inside
  // Biomarkers/Insights/Genetics/Protocols can pop back to the landing. It is
  // shell `@State` rather than router state on purpose — nothing outside a tap
  // pushes onto this stack (a tapped notification uses a cover; see
  // `HCCHealthView`), and putting it on the router would invite that.
  @State private var hccHealthPath: [HCCHealthView.Page] = []
  // HCC: `bottomTabs` reads the provider switch. Observing the same key here is
  // what makes the tab bar redraw if the switch changes under a live shell.
  @AppStorage(HCCProviderSettings.storageKey) private var providerRaw = HealthMetricProvider.bridge.rawValue
  // HCC: the Coach is one sheet over the whole cloud shell, not a tab and not a
  // per-screen object — the mockup's FAB lives in the phone chrome, and a model
  // owned per tab would lose the thread every time the owner switched tabs.
  @StateObject private var coach = HCCCoachChatModel()
  @State private var isCoachPresented = false

  var body: some View {
    // HCC: cloud mode wears the "C · Command" chrome — the system tab bar is
    // hidden and `HCCTabBar` is drawn in its place. Bridge mode is upstream's
    // shell, untouched.
    Group {
      if HCCProviderSettings.isCloud {
        cloudShell
      } else {
        bridgeShell
      }
    }
    .onChange(of: model.ble.historicalSyncStatus) { _, newValue in
      handleHistoricalSyncStatusChange(newValue)
    }
    .onAppear(perform: selectDebugLaunchTabIfRequested)
  }

  // HCC: `HCC_DEBUG_OPEN_TAB=<tab>` selects a tab on launch, so a tab that is
  // not Home can be screenshotted without UI automation — `simctl` cannot tap.
  // DEBUG only and a no-op without the variable, exactly like the existing
  // `HCC_DEBUG_OPEN_ROUTE` hook.
  private func selectDebugLaunchTabIfRequested() {
    #if DEBUG
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_TAB"],
          let tab = OpenVitalsAppTab(rawValue: raw),
          OpenVitalsAppTab.bottomTabs.contains(tab)
    else {
      return
    }
    router.selectedTab = tab
    #endif
  }

  private var bridgeShell: some View {
    TabView(selection: tabSelection) {
      ForEach(OpenVitalsAppTab.bottomTabs) { tab in
        tabNavigationStack(for: tab)
        .tabItem {
          Label(tab.title, systemImage: tab.systemImage)
        }
        .tag(tab)
      }
    }
    .tint(OpenVitalsTheme.accent)
  }

  // HCC: the system bar is hidden per stack rather than removed, so each tab
  // keeps its own navigation state across a switch; the custom bar is laid out
  // under each stack (see the note inside), which is what keeps a scrolling
  // screen's last row clear of it without a magic number.
  private var cloudShell: some View {
    TabView(selection: tabSelection) {
      ForEach(OpenVitalsAppTab.bottomTabs) { tab in
        // The bar is laid out UNDER each tab's stack rather than as a
        // safe-area inset: an inset on the TabView (or on the stack) never
        // reached the ScrollViews inside the per-tab NavigationStacks, and every
        // scrolling screen's last card ended up clamped under the bar by exactly
        // its height. A plain VStack bounds the stack above the bar for certain.
        VStack(spacing: 0) {
          // HCC: the Coach FAB overlays the STACK, not the VStack, so it sits
          // above the tab bar by construction rather than by a magic offset —
          // the same reasoning as the bar's own layout above.
          tabNavigationStack(for: tab)
            .overlay(alignment: .bottomTrailing) { coachFAB }
          HCCTabBar(selection: tabSelection, tabs: OpenVitalsAppTab.bottomTabs)
        }
        .toolbar(.hidden, for: .tabBar)
        .tag(tab)
      }
    }
    .tint(HCCTheme.Color.accent)
    .sheet(isPresented: $isCoachPresented) {
      HCCCoachSheet(model: coach, pageContext: coachPageContext)
    }
    // HCC: `AppRouter.openCoach` (and the server's deep links through it) ask
    // for the Coach by bumping this counter — the shell owns the sheet, so this
    // is where the request is honoured.
    .onChange(of: router.hccCoachRequested) { _, _ in presentCoach() }
    .onChange(of: router.hccPopToRootRequestID) { _, _ in popSelectedTabToRoot() }
    .onAppear(perform: presentCoachOnLaunchIfRequested)
  }

  /// Only the tab that is on screen pops — `reselect` fires for the tab the
  /// owner tapped, which is by definition the selected one, and the other tabs
  /// keep the stacks they were left in.
  ///
  /// Home is absent here because it owns its own path inside `HCCHomeView`,
  /// which watches the same counter. Journal and Training push nothing.
  private func popSelectedTabToRoot() {
    switch router.selectedTab {
    case .health: hccHealthPath.removeAll()
    case .more: router.morePath.removeAll()
    default: break
    }
  }

  // HCC: hidden while the sheet is up — the mockup hides the FAB behind its own
  // sheet, and a button that opens what is already open is noise.
  @ViewBuilder
  private var coachFAB: some View {
    if !isCoachPresented {
      HCCCoachFAB { presentCoach() }
        .padding(.trailing, 14)
        .padding(.bottom, 14)
    }
  }

  private func presentCoach() {
    // A prefilled prompt from a deep link becomes the draft; it is never sent
    // for the owner — they still press send.
    let prompt = router.coachPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !prompt.isEmpty {
      coach.draft = prompt
      router.coachPromptDraft = ""
    }
    isCoachPresented = true
  }

  // HCC: `HCC_DEBUG_OPEN_COACH=1` opens the sheet on launch. `simctl` cannot tap,
  // so without this hook no scripted run could screenshot the Coach at all.
  // DEBUG only and a no-op without the variable.
  private func presentCoachOnLaunchIfRequested() {
    #if DEBUG
    guard HCCProviderSettings.isCloud, HCCCoachChatModel.debugWantsSheet else { return }
    isCoachPresented = true
    #endif
  }

  /// The short label the Coach sends as `pageContext` — which screen the
  /// question was asked from, and for Home which civil day is on screen. The day
  /// is the INSTANCE's, never the device's.
  private var coachPageContext: String {
    switch router.selectedTab {
    case .home:
      "mobile:home \(HealthDataStore.hccDayKey(homeSelectedDate))"
    case .health:
      "mobile:health"
    case .journal:
      "mobile:journal"
    case .training:
      "mobile:training"
    case .more:
      "mobile:more"
    case .coach:
      "mobile:coach"
    case .developer:
      "mobile:collect"
    }
  }

  private var tabSelection: Binding<OpenVitalsAppTab> {
    Binding {
      OpenVitalsAppTab.bottomTabs.contains(router.selectedTab) ? router.selectedTab : .home
    } set: { newTab in
      if newTab == router.selectedTab {
        router.reselect(newTab)
        return
      }
      router.selectedTab = newTab
      model.recordUIAction("tab.selected", detail: newTab.title)
    }
  }

  @ViewBuilder
  private func tabNavigationStack(for tab: OpenVitalsAppTab) -> some View {
    if tab == .home {
      // HCC: cloud Home is `HCCHomeView`, which owns its own `NavigationStack`
      // over `HCCHomeRoute` — the ring details and the activity detail are its
      // routes, not the bridge's `HealthRoute` deep links. Wrapping it again
      // here would nest two stacks.
      if HCCProviderSettings.isCloud {
        tabContent(for: tab)
      } else {
        NavigationStack(path: $router.healthPath) {
          tabContent(for: tab)
            .navigationDestination(for: HealthRoute.self) { route in
              HealthRouteDestinationView(route: route, store: healthStore, selectedDate: $homeSelectedDate)
            }
        }
      }
    } else if tab == .health {
      // HCC: cloud mode shows Home and Health at once. Two live stacks cannot
      // share `router.healthPath` — the deep-link pushes belong to Home, which
      // is the stack that registers the `HealthRoute` destinations — so this
      // one keeps its own.
      NavigationStack(path: $hccHealthPath) {
        tabContent(for: tab)
      }
    } else if tab == .developer {
      NavigationStack {
        tabContent(for: tab)
          .navigationDestination(for: MoreRoute.self) { route in
            MoreRouteDestinationView(route: route, healthStore: healthStore, store: moreStore) {
              router.openHealth(.algorithms)
            }
          }
      }
    } else if tab == .more {
      NavigationStack(path: $router.morePath) {
        tabContent(for: tab)
      }
    } else {
      NavigationStack {
        tabContent(for: tab)
      }
    }
  }

  @ViewBuilder
  private func tabContent(for tab: OpenVitalsAppTab) -> some View {
    switch tab {
    case .home:
      // HCC: one guarded branch, so the DEBUG design-system gallery has a way
      // in without a route. Everything else about this case is unchanged.
      homeTabContent
    case .health:
      // HCC: INTEGRATION — cloud mode's Health tab is `HCCHealthView(store:)`
      // (the Biomarkers / Insights / Genetics / Protocols pages). It registers
      // its own navigation destinations inside the stack this tab already has,
      // so no second stack is introduced. Bridge mode keeps the shared shell.
      if HCCProviderSettings.isCloud {
        HCCHealthView(store: healthStore)
      } else {
        HealthView(store: healthStore)
      }
    // HCC: the Journal and Training tabs are cloud-only screens; each owns its
    // own root file so the two can evolve without touching the shell again.
    case .journal:
      HCCJournalView(store: healthStore)
    case .training:
      HCCTrainingView(store: healthStore)
    case .coach:
      CoachView(healthStore: healthStore)
    case .developer:
      MoreDeveloperView(store: moreStore, routes: MoreRoute.developerToolRoutes, routeStatus: moreRouteStatus)
        .onAppear {
          model.recordUIAction("page.opened", detail: "Developer")
          moreStore.refreshBridgeStatus(model: model)
          moreStore.refreshRecentCaptureSessions()
        }
    case .more:
      MoreView(healthStore: healthStore, store: moreStore)
    }
  }

  // HCC: `HCC_DEBUG_OPEN_SCREEN=gallery` on the launch environment opens the
  // component gallery instead of Home, so the design system can be
  // screenshotted before the screens that use it exist. DEBUG only — the whole
  // branch is compiled out of Release.
  @ViewBuilder
  private var homeTabContent: some View {
    #if DEBUG
    if HCCComponentGallery.isRequested {
      HCCComponentGallery()
    } else {
      providerHome
    }
    #else
    providerHome
    #endif
  }

  // HCC: cloud mode replaces Home wholesale with the "C · Command" screen.
  // Bridge mode keeps `HomeDashboardView` exactly as upstream has it.
  @ViewBuilder
  private var providerHome: some View {
    if HCCProviderSettings.isCloud {
      HCCHomeView(store: healthStore, selectedDate: $homeSelectedDate)
    } else {
      homeDashboard
    }
  }

  private var homeDashboard: some View {
    HomeDashboardView(
      healthStore: healthStore,
      selectedDate: $homeSelectedDate,
      openHealthRoute: openHomeHealthRoute
    )
  }

  private var moreRouteStatus: MoreRouteStatus {
    moreStore.routeStatus(ble: model.ble, model: model)
  }

  private func openHomeHealthRoute(_ route: HealthRoute) {
    router.openHealth(route)
  }

  private func handleHistoricalSyncStatusChange(_ status: String) {
    guard status == "synced" || status == "failed" else {
      return
    }

    let captureSource = model.activeHealthPacketCapture?.source
    if captureSource == OpenVitalsAppModel.dailyMetricSyncCaptureSource {
      model.finishDailyMetricSyncCaptureIfNeeded {
        if status == "synced" {
          refreshMetricsAfterHistoricalSync()
        }
      }
      return
    }

    if captureSource == OpenVitalsAppModel.automaticHistoricalSyncCaptureSource {
      model.finishAutomaticHistoricalSyncCaptureIfNeeded {
        if status == "synced" {
          refreshMetricsAfterHistoricalSync()
        }
      }
      return
    }

    if status == "synced" {
      refreshMetricsAfterHistoricalSync()
    }
  }

  private func refreshMetricsAfterHistoricalSync() {
    healthStore.loadBridgeCatalogsIfNeeded()
    healthStore.refreshHealthMetrics(for: homeSelectedDate)
  }
}

enum OpenVitalsAppTab: String, CaseIterable, Identifiable {
  case home
  case health
  // HCC: cloud mode's bar is the mockup's five tabs. Journal and Training are
  // shown from the start with a one-line "arrives in Phase 3" screen rather
  // than being hidden — the bar's shape is part of the design, and an honest
  // empty screen is clearer than a tab that appears later without warning.
  case journal
  case training
  case coach
  case developer
  case more

  var id: String { rawValue }

  // HCC: cloud mode has no band to collect from, so the BLE capture tab goes
  // and Health — which upstream keeps commented out until the local metric
  // surfaces land — takes its place. Bridge mode is upstream's list untouched.
  // Coach stays out of both until it has a backend and a consent path.
  static var bottomTabs: [OpenVitalsAppTab] {
    if HCCProviderSettings.isCloud {
      return [.home, .health, .journal, .training, .more]
    }
    return [
      .home,
      // .health,
      // .coach,
      .developer,
      .more,
    ]
  }

  var title: String {
    switch self {
    case .home: "Home"
    case .health: "Health"
    case .journal: "Journal"
    case .training: "Training"
    case .coach: "Coach"
    case .developer: "Collect"
    case .more: "More"
    }
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .health: "heart.text.square"
    case .journal: "text.book.closed"
    case .training: "dumbbell"
    case .coach: "sparkles"
    case .developer: "tray.and.arrow.down"
    case .more: "ellipsis.circle"
    }
  }

}
