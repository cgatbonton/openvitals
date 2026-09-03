import Darwin
import Foundation
import SwiftUI
import UIKit

struct SleepV2OverviewPage: View {
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var store: HealthDataStore
  @ObservedObject var ble: OpenVitalsBLEClient
  @Binding var selectedDate: Date
  @Environment(\.colorScheme) private var colorScheme
  @State private var showingInsightsSheet = false
  @State private var showingAlarmSheet = false
	  @State private var showingSleepNeededSheet = false
	  @State private var showingDatePicker = false
    @State private var selectedTrend: HealthMetricSnapshot?
	  @State private var selectedPrimarySleep: PrimarySleepDetail?
	  @State private var scrollOffsetY: CGFloat = 0
    @State private var autoBandSyncRequested = false
	  private let heroHeight: CGFloat = 320
	  private let heroBackgroundHeight: CGFloat = 560
    private var autoBandSleepSyncEnabled: Bool {
      let processInfo = ProcessInfo.processInfo
      return processInfo.arguments.contains("--open-vitals-auto-band-sleep-sync")
        || processInfo.environment["OPENVITALS_AUTO_BAND_SLEEP_SYNC"] == "1"
    }

	  var body: some View {
	    let palette = SleepV2Palette(colorScheme: colorScheme)
		    ScrollViewReader { _ in
	      ZStack(alignment: .top) {
	        palette.background
	          .ignoresSafeArea()

	        SleepV2ScenicBackground(palette: palette)
	          .frame(height: heroBackgroundHeight)
	          .offset(y: min(scrollOffsetY, 0))
	          .ignoresSafeArea(edges: .top)
	          .allowsHitTesting(false)

	        ScrollView {
	          LazyVStack(alignment: .leading, spacing: 0) {
	            SleepV2ScrollOffsetProbe()

	            SleepV2Hero(
	              palette: palette,
	              title: "Sleep",
	              dateLabel: dateLabel,
	              score: sleepScore,
	              onDateTap: { showingDatePicker = true }
	            )
	            .frame(height: heroHeight)

	            VStack(alignment: .leading, spacing: 14) {
	              HStack(spacing: 12) {
                SleepV2StatCard(
                  palette: palette,
                  systemImage: "bed.double.fill",
                  label: "Time in Bed",
                  value: primarySleep?.timeInBedText ?? "No data"
                )
                SleepV2StatCard(
                  palette: palette,
                  systemImage: "clock.fill",
                  label: "Time Asleep",
                  value: primarySleep?.durationText ?? "No data"
                )
              }
              .frame(height: 96)

              SleepV2CoachingCard(palette: palette, tip: coachTip) {
                router.openCoach(prompt: coachTip.prompt)
              }

	              SleepV2ActionRow(
	                palette: palette,
	                systemImage: "sparkles",
	                title: "View insights",
	                action: { showingInsightsSheet = true }
	              )

	              SleepV2SleepWindowCard(
                palette: palette,
                onWakeTap: { showingAlarmSheet = true },
                onSleepNeeded: { showingSleepNeededSheet = true }
              )

              SleepV2BandSyncCard(store: store, ble: ble, palette: palette) {
                startBandSleepSync(automatic: false)
              }

              SleepV2SectionHeader(title: "Timeline", palette: palette)

              SleepV2TimelineRow(
                palette: palette,
                session: primarySleep,
                action: {
                  if let primarySleep {
                    selectedPrimarySleep = primarySleep
                  }
                }
              )

              SleepV2SectionHeader(title: "Trends", palette: palette)

              VStack(spacing: 14) {
                ForEach(store.trendRows(for: .sleep)) { snapshot in
                  SleepV2TrendRow(palette: palette, snapshot: snapshot) {
                    selectedTrend = snapshot
                  }
	                }
	              }
	            }
	            .padding(.horizontal, 18)
	            .padding(.bottom, 34)
	          }
	        }
	        .coordinateSpace(name: SleepV2ScrollOffsetProbe.coordinateSpaceName)
	        .onPreferenceChange(SleepV2ScrollOffsetPreferenceKey.self) { value in
	          scrollOffsetY = value
	        }
	      }
	    }
    .navigationTitle("Sleep")
    // HCC: cloud mode's numbers for a day come from one read, and a detail
    // screen can be reached directly (deep link, date picker) without Home
    // having fetched that day. Asking here makes the screen self-sufficient
    // instead of silently showing an empty day. Re-runs whenever the date
    // changes; the store coalesces overlapping reads.
    .task(id: selectedDate) {
      guard HCCProviderSettings.isCloud else { return }
      await store.refreshFromHCC(date: selectedDate)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text("Sleep")
          .font(.headline.weight(.semibold))
          .foregroundStyle(palette.text)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showingAlarmSheet = true
        } label: {
          Image(systemName: "alarm")
        }
        .accessibilityLabel("Sleep alarm settings")
      }
    }
    .onAppear {
      store.loadBridgeCatalogsIfNeeded()
      startBandSleepSyncIfReady()
    }
    .onChange(of: ble.canSyncHistorical) { _, _ in
      startBandSleepSyncIfReady()
    }
    .onChange(of: ble.historicalSyncStatus) { _, newValue in
      if newValue == "synced" {
        store.refreshSleepAfterBandSync(packetCount: ble.historicalPacketCount)
      } else if newValue == "failed" {
        store.markBandSleepSyncFailed(ble.historicalSyncStatus)
      }
    }
    .sheet(isPresented: $showingDatePicker) {
      ScoreDatePickerSheet(
        title: "Sleep",
        routes: [.sleep],
        snapshots: [store.snapshot(for: .sleep)],
        selectedDate: $selectedDate
      )
    }
	    .sheet(isPresented: $showingAlarmSheet) {
	      SleepV2AlarmSheet(ble: ble)
	    }
	    .sheet(isPresented: $showingSleepNeededSheet) {
	      SleepV2SleepNeededSheet(palette: palette)
	    }
	    .sheet(isPresented: $showingInsightsSheet) {
	      SleepV2InsightsSheet(palette: palette)
	    }
		    .sheet(item: $selectedTrend) { snapshot in
		      SleepV2BevelTrendSheet(snapshot: snapshot)
		    }
    .sheet(item: $selectedPrimarySleep) { sleep in
      PrimarySleepDetailSheet(sleep: sleep)
    }
  }

  private var selectedSnapshot: HealthMetricSnapshot {
    ScoreDateTimeline.datedSnapshot(
      from: store.snapshot(for: .sleep),
      date: selectedDate
    )
  }

  private var primarySleep: PrimarySleepDetail? {
    store.primarySleep()
  }

  private var sleepScore: Int {
    // No score is 0, not 92. A hard-coded percentage here would be a metric
    // value nobody measured, which the product rules forbid outright
    // (AGENTS.md, "Never fabricate metric values"); Recovery's hero already
    // falls back to 0 for the same reason.
    SleepV2Numbers.firstInt(in: selectedSnapshot.value)
      ?? SleepV2Numbers.firstInt(in: primarySleep?.scoreText ?? "")
      ?? 0
  }

  private var dateLabel: String {
    let suffix = selectedDate.formatted(.dateTime.day().month(.abbreviated))
    let prefix = ScoreDateTimeline.dateLabel(for: selectedDate)
    // "Today, Sep 2" reads well; "Aug 25, Aug 25" does not. Past days already
    // label themselves with the date, so there is no relative word to prepend.
    return prefix == suffix ? suffix : "\(prefix), \(suffix)"
  }

  private var coachTip: CoachInlineTip {
    CoachTipFactory.sleepTip(healthStore: store, ble: ble)
  }

  private func startBandSleepSyncIfReady() {
    guard autoBandSleepSyncEnabled else {
      if !autoBandSyncRequested {
        autoBandSyncRequested = true
        ble.record(
          source: "health.sleep",
          title: "band_sleep_sync.auto_skipped",
          body: "autoBandSleepSync=false"
        )
      }
      return
    }
    guard !autoBandSyncRequested, ble.canSyncHistorical else {
      return
    }
    autoBandSyncRequested = true
    startBandSleepSync(automatic: true)
  }

  private func startBandSleepSync(automatic: Bool) {
    store.markBandSleepSyncRequested(
      automatic: automatic,
      canSync: ble.canSyncHistorical,
      detail: ble.historicalSyncStatus
    )
    guard ble.canSyncHistorical else {
      return
    }
    ble.syncHistoricalPackets(rangeFirst: true)
  }

}

