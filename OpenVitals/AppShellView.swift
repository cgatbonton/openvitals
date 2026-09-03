import SwiftUI

struct AppShellView: View {
  @EnvironmentObject private var model: OpenVitalsAppModel
  @EnvironmentObject private var router: AppRouter
  @StateObject private var healthStore = HealthDataStore()
  @StateObject private var moreStore = MoreDataStore()
  @State private var homeSelectedDate = Date()
  // HCC: `bottomTabs` reads the provider switch. Observing the same key here is
  // what makes the tab bar redraw if the switch changes under a live shell.
  @AppStorage(HCCProviderSettings.storageKey) private var providerRaw = HealthMetricProvider.bridge.rawValue

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
  // keeps its own navigation state across a switch; the custom bar rides in a
  // bottom safe-area inset, which is what keeps a scrolling screen's last row
  // clear of it without a magic number.
  private var cloudShell: some View {
    TabView(selection: tabSelection) {
      ForEach(OpenVitalsAppTab.bottomTabs) { tab in
        tabNavigationStack(for: tab)
          .toolbar(.hidden, for: .tabBar)
          .tag(tab)
      }
    }
    .tint(HCCTheme.Color.accent)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HCCTabBar(selection: tabSelection, tabs: OpenVitalsAppTab.bottomTabs)
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
      NavigationStack {
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
    // HCC: the two reserved tabs. One themed line each — no controls, because a
    // control that does nothing is worse than an empty page.
    case .journal:
      HCCPhaseScreen(title: "Journal", note: "Journal arrives in Phase 3.")
    case .training:
      HCCPhaseScreen(title: "Training", note: "Training arrives in Phase 3.")
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
