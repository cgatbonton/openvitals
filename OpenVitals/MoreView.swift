import Foundation
import CryptoKit
import SwiftUI
import UIKit

#if canImport(HealthKit)
import HealthKit
#endif

struct MoreView: View {
  @EnvironmentObject private var model: OpenVitalsAppModel
  @EnvironmentObject private var router: AppRouter
  @ObservedObject private var healthStore: HealthDataStore
  @StateObject private var store: MoreDataStore
  @AppStorage(OnboardingStorage.firstName) private var profileFirstName = ""
  @AppStorage(OnboardingStorage.unitSystem) private var profileUnitSystemRaw = "imperial"
  @AppStorage(OnboardingStorage.heightMm) private var profileHeightMm = 0
  @AppStorage(OnboardingStorage.weightGrams) private var profileWeightGrams = 0

  @MainActor
  init(healthStore: HealthDataStore) {
    self.healthStore = healthStore
    _store = StateObject(wrappedValue: MoreDataStore())
  }

  @MainActor
  init(healthStore: HealthDataStore, store: MoreDataStore) {
    self.healthStore = healthStore
    _store = StateObject(wrappedValue: store)
  }

  var body: some View {
    // HCC: cloud mode has no band, no packet capture and no local metric store,
    // so the rows that operate on them are gone — not deleted from the app, and
    // not disabled-with-an-explanation, which would only be a dead end. It also
    // gets the Command design's glass cards rather than the system list, since
    // half of its rows are statements about this phase rather than settings.
    // Bridge mode below is upstream's screen, untouched.
    Group {
      if HCCProviderSettings.isCloud {
        HCCMoreScreen(healthStore: healthStore)
      } else {
        bridgeList
      }
    }
    .navigationTitle("More")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .navigationDestination(for: MoreRoute.self) { route in
      MoreRouteDestinationView(route: route, healthStore: healthStore, store: store) {
        router.openHealth(.algorithms)
      }
    }
    .onAppear {
      model.recordUIAction("page.opened", detail: "More")
      store.refreshBridgeStatus(model: model)
      store.refreshRecentCaptureSessions()
    }
  }

  private var bridgeList: some View {
    List {
      Section {
        NavigationLink(value: MoreRoute.profile) {
          MoreGreetingHeader(
            firstName: profileFirstName,
            profileSummary: profileSummary
          )
        }
        .accessibilityLabel("Update profile")
      }

      Section("Device") {
        routeRows(MoreRoute.deviceRoutes)
      }

      Section("App") {
        routeRows(MoreRoute.appRoutes)
      }

      Section("Settings") {
        routeRows(MoreRoute.settingsRoutes)
      }

      Section("Support") {
        routeRows(MoreRoute.supportRoutes)
      }

      Section("Developer") {
        routeRows(MoreRoute.developerRoutes)
      }
    }
    .listStyle(.insetGrouped)
    .tint(OpenVitalsTheme.accent)
    .listRowSeparatorTint(OpenVitalsTheme.separator)
    .openVitalsListBackground()
  }

  private var routeStatus: MoreRouteStatus {
    store.routeStatus(ble: model.ble, model: model)
  }

  @ViewBuilder
  private func routeRows(_ routes: [MoreRoute]) -> some View {
    ForEach(routes) { route in
      NavigationLink(value: route) {
        MoreRouteRow(route: route, status: routeStatus[keyPath: route.statusKeyPath])
      }
      .accessibilityLabel(route.title)
    }
  }

  private var profileSummary: String {
    let height = MoreProfileFormatting.heightText(millimeters: profileHeightMm, unitSystemRaw: profileUnitSystemRaw)
    let weight = MoreProfileFormatting.weightText(grams: profileWeightGrams, unitSystemRaw: profileUnitSystemRaw)
    let parts = [height, weight].filter { !$0.isEmpty }
    return parts.isEmpty ? "Update profile" : parts.joined(separator: " | ")
  }
}

struct MoreRouteDestinationView: View {
  let route: MoreRoute
  @ObservedObject var healthStore: HealthDataStore
  @ObservedObject var store: MoreDataStore
  let openHealthAlgorithms: () -> Void

  private var routeStatus: MoreRouteStatus {
    store.routeStatus(ble: model.ble, model: model)
  }

  @EnvironmentObject private var model: OpenVitalsAppModel

  var body: some View {
    destination
  }

  @ViewBuilder
  private var destination: some View {
    switch route {
    case .device:
      DeviceView()
    case .profile:
      MoreProfileView()
    case .connectionLab:
      ConnectionView()
    case .capture:
      MoreCaptureView(store: store)
    case .localStore:
      MoreLocalStoreView(store: store)
    case .healthSync:
      MoreHealthSyncView(store: store)
    case .rawExport:
      MoreRawExportView(store: store)
    case .streamProbePlan:
      MoreStreamProbePlanView(store: store)
    case .algorithms:
      MoreAlgorithmsView(store: store, healthStore: healthStore, openHealthAlgorithms: openHealthAlgorithms)
    case .debug:
      MoreDebugView(healthStore: healthStore, store: store)
    case .appearance:
      MoreAppearanceView()
    case .privacy:
      MorePrivacyView(store: store)
    case .support:
      MoreSupportView(store: store)
    case .about:
      MoreAboutView(store: store)
    case .developer:
      MoreDeveloperView(store: store, routes: MoreRoute.developerToolRoutes, routeStatus: routeStatus)
    }
  }
}
