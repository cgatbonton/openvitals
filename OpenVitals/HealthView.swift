import Darwin
import Foundation
import SwiftUI
import UIKit

struct HealthView: View {
  @EnvironmentObject private var model: OpenVitalsAppModel
  @ObservedObject var store: HealthDataStore

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        HealthDashboardStatusHeader(
          catalogStatus: store.catalogStatus,
          packetInputStatus: store.packetInputStatus,
          packetScoreStatus: store.packetScoreStatus,
          refreshStatus: store.healthMetricRefreshStatus,
          isRefreshing: store.healthMetricWorkIsRunning,
          usesSampleData: store.usesSampleData
        )

        HealthActivityOverviewSection(
          // HCC: the heart-rate card reads the live BLE stream, which cloud
          // mode never opens.
          showsLiveHeartRate: !HCCProviderSettings.isCloud,
          steps: store.healthDashboardStepsText,
          activeEnergy: store.healthDashboardActiveEnergyText,
          stepsFreshness: store.healthDashboardStepsStatus,
          stepsSource: store.healthDashboardStepsSource,
          activeEnergyFreshness: store.healthDashboardActiveEnergyStatus,
          activeEnergySource: store.healthDashboardActiveEnergySource,
          heartRateValue: liveHeartRateValue,
          heartRateStatus: liveHeartRateStatus,
          heartRateSource: liveHeartRateSource
        )

        HealthVitalsPreviewSection(snapshots: store.healthDashboardVitalSnapshots)

        HealthRouteShortcutSection(
          title: "Explore Health",
          snapshots: store.healthDashboardExploreSnapshots
        )

        // HCC: empty in cloud mode — there is no local packet pipeline to
        // inspect, so the section is not drawn at all.
        if !store.healthDashboardAlgorithmSnapshots.isEmpty {
          HealthRouteShortcutSection(
            title: "Data & Algorithms",
            snapshots: store.healthDashboardAlgorithmSnapshots
          )
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .openVitalsScreenBackground()
    .navigationTitle("Health")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .navigationDestination(for: HealthRoute.self) { route in
      HealthRouteContentView(route: route, store: store)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          refreshDashboard()
        } label: {
          if store.healthMetricWorkIsRunning {
            ProgressView()
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .accessibilityLabel("Refresh Health")
        .disabled(store.healthMetricWorkIsRunning)
      }
    }
    .onAppear {
      model.recordUIAction("page.opened", detail: "Health")
      store.refreshHealthDashboardSnapshots()
      store.loadBridgeCatalogsIfNeeded()
      store.loadPersistedPacketScoresIfNeeded()
      // HCC: the heart-rate timeline is a local BLE sample-store read.
      if !HCCProviderSettings.isCloud {
        store.refreshHeartRateTimeline()
      }
    }
  }

  private var liveHeartRateValue: String {
    guard let bpm = model.ble.liveHeartRateBPM else {
      return "--"
    }
    return "\(bpm) bpm"
  }

  private var liveHeartRateStatus: String {
    guard model.ble.liveHeartRateBPM != nil else {
      return store.heartRateTimelineStatus
    }
    return HealthDataStore.relativeText(for: model.ble.liveHeartRateUpdatedAt) ?? "Live"
  }

  private var liveHeartRateSource: HealthDataSource {
    model.ble.liveHeartRateBPM == nil
      ? .unavailable("BLE heart-rate stream waiting")
      : .live(model.ble.liveHeartRateSource)
  }

  @MainActor
  private func refreshDashboard() {
    store.refreshHealthMetrics()
  }
}
