import SwiftUI

// `S.live` from the approved mockup: the heart rate right now, the zone it is
// in, and what the session has added up to so far.
//
// What this screen may and may not claim:
//   * the big number is the last reading a source delivered. When the source
//     goes quiet for twenty seconds it becomes "--", because a held value under
//     a live heading is a fabricated measurement;
//   * "Strain so far" is the phone's own arithmetic over the zone time
//     accumulated here, on the same curve the server stores against — and is
//     labelled "est." for exactly that reason. The FINAL strain is the server's,
//     shown on the activity screen this hands off to;
//   * kcal is shown only when the source reported energy. Nothing here derives
//     calories from heart rate.
//
// It is presented full-screen (by `HCCLiveSetupSheet`) rather than as a sheet:
// a workout in progress must not be swipe-dismissable.

struct HCCLiveActivityView: View {
  @ObservedObject var store: HealthDataStore
  @ObservedObject var state: HCCLiveState

  @Environment(\.dismiss) private var dismiss
  @State private var isConfirmingEnd = false
  @State private var isEnding = false

  init(store: HealthDataStore) {
    self.store = store
    self.state = store.hccLive
  }

  var body: some View {
    ZStack {
      HCCBackground()
      if state.phase == .done, let activity = state.resultActivity {
        // Handing off to the stored row: from here on every number is the
        // server's, including the strain.
        HCCActivityDetailView(store: store, activityId: activity.id)
      } else {
        session
      }
    }
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    .onChange(of: state.phase) { _, phase in
      // The screen closes when the session is thrown away, and when the stored
      // row's own back button dismisses this cover.
      if phase == .idle { dismiss() }
    }
    .confirmationDialog(
      "End this activity?",
      isPresented: $isConfirmingEnd,
      titleVisibility: .visible
    ) {
      Button("End and save") { end() }
      Button("Discard", role: .destructive) {
        store.discardHCCLive()
        dismiss()
      }
      Button("Keep going", role: .cancel) {}
    } message: {
      Text(
        "Saving stores the window, the heart-rate series and the zone time. "
          + "Your Command Center computes the strain from them."
      )
    }
  }

  // ── The running screen ─────────────────────────────────────────────────────

  private var session: some View {
    HCCScreen {
      HCCDetailHeader(title: "Live activity", subtitle: subtitle, showsBack: false)

      bigNumber
      HCCStat3(items: stats)

      zonesCard
      heartRateCard

      if let error = state.lastError {
        HCCErrorNote(error, title: "Not saved")
      }

      HCCButtonRow(
        primary: HCCButtonSpec(title: "End activity", isEnabled: !isEnding) {
          isConfirmingEnd = true
        },
        secondary: HCCButtonSpec(
          title: state.isPaused ? "Resume" : "Pause",
          isEnabled: !isEnding
        ) {
          if state.isPaused { store.resumeHCCLive() } else { store.pauseHCCLive() }
        }
      )

      HCCFootnote(HCCLiveCopy.ceilingNote(state: state))
      HCCFootnote(HCCLiveCopy.sourceFootnote)
    }
  }

  /// "<type> · <source> · zone <n> goal", the mockup's subtitle.
  private var subtitle: String {
    let name = state.titleOverride ?? HCCActivityCopy.title(for: state.type)
    return "\(name) · \(state.sourceKind.label) · zone \(state.goalZone) goal"
  }

  /// `.live-hr` — the 64-pt reading and the zone chip under it.
  private var bigNumber: some View {
    VStack(spacing: 6) {
      HStack(alignment: .lastTextBaseline, spacing: 4) {
        Text(state.displayBpm.map(String.init) ?? "--")
          .font(HCCTheme.Font.display(size: 64, weight: .medium))
          .monospacedDigit()
          .tracking(-1.9)
          .foregroundStyle(HCCTheme.Color.text)
        Text("bpm")
          .font(HCCTheme.Font.body(size: 14, weight: .medium))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      zoneChip
      if state.displayBpm == nil {
        Text(state.sourceStatus ?? "Waiting for a reading from \(state.sourceKind.label).")
          .font(HCCTheme.Font.body(size: 11))
          .foregroundStyle(HCCTheme.Color.muted)
          .multilineTextAlignment(.center)
      }
      if state.isPaused {
        Text("Paused — zone time is not counting.")
          .font(HCCTheme.Font.body(size: 11))
          .foregroundStyle(HCCTheme.Color.warn)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  /// `.live-hr .z` — the zone pill, tinted with that zone's colour at 22%.
  @ViewBuilder
  private var zoneChip: some View {
    if state.displayBpm != nil, let zone = state.currentZone {
      // Server zone indices run 0…5, and index 0 is "not elevated" rather than
      // a zone the mockup names — Z1 is index 1 (50–60%). So the chip reads the
      // index straight through for 1…5 and says plainly what 0 is.
      let tint = HCCTheme.Color.zone(zone)
      let percent = HCCZones.percentLabel(zone: zone, config: state.zoneConfig) ?? "--"
      let basis = state.restingHr == nil ? "of max" : "of reserve"
      Text(zone == 0 ? "Below zone 1 · under \(state.zoneConfig.floors.count > 1 ? Int(state.zoneConfig.floors[1] * 100) : 50)% \(basis)" : "Zone \(zone) · \(percent) \(basis)")
        .font(HCCTheme.Font.body(size: 11, weight: .semibold))
        .tracking(1.32)
        .textCase(.uppercase)
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.22)))
    }
  }

  /// `.stat3` — elapsed, the running strain, and energy when there is any.
  private var stats: [HCCStat] {
    [
      HCCStat(value: Self.clock(state.elapsed), label: "Elapsed"),
      HCCStat(
        value: HealthDataStore.hccDecimalText(state.strainSoFar, fractionDigits: 1),
        label: "Strain so far (est.)"
      ),
      HCCStat(
        // Only when a source reported energy. A heart rate is not a calorie
        // count, and deriving one here would be inventing a measurement.
        value: state.kcal.map { String(Int($0.rounded())) } ?? "--",
        label: "kcal"
      ),
    ]
  }

  private var zonesCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        HCCLabel("Time in zones", size: 11)
        Spacer(minLength: 8)
        HCCChip("goal: Z\(state.goalZone)", dotColor: HCCTheme.Color.zone(state.goalZone))
      }
      .padding(.bottom, 8)

      HCCZoneBars(
        // Zone 0 is not elevated heart rate and is not one of the five the
        // mockup names, so the bars start at Z1 — the same five the activity
        // detail shows.
        minutes: Array(state.zoneMinutes.dropFirst()),
        current: state.displayBpm != nil ? state.currentZone : nil
      )
    }
    .hccCard()
  }

  private var heartRateCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        HCCLabel("Heart rate", size: 11)
        Spacer(minLength: 8)
        HCCChip("last 5 min")
      }
      .padding(.bottom, 8)

      let values = state.recentSamples.map { Double($0.bpm) }
      if values.count > 1 {
        HCCSparkline(values: values, color: HCCTheme.Color.strain, height: 72)
        HStack {
          Text("\(Int(values.min() ?? 0)) bpm")
          Spacer()
          Text("\(Int(values.max() ?? 0)) bpm")
        }
        .font(HCCTheme.Font.data(size: 9.5, weight: .medium))
        .foregroundStyle(HCCTheme.Color.muted)
        .padding(.top, 4)
      } else {
        HCCEmptyNote("The trace appears once two readings have arrived.")
      }
    }
    .hccCard()
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  private func end() {
    isEnding = true
    Task {
      _ = await store.finishHCCLive()
      isEnding = false
    }
  }

  /// mm:ss, and hh:mm:ss past an hour.
  static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds).rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
  }
}
