import SwiftUI

// HCC: what a live session needs before it can start — what is being recorded,
// where the heart rate comes from, and which zone it is aiming at.
//
// The mockup has no setup screen: `S.live` opens already running. It needs one
// anyway, because the three things above cannot be guessed. A source in
// particular is a real choice with real consequences (a watch session has to be
// started ON the watch; a strap has to be found first), and picking one for the
// wearer would mean a screen that sits at "--" with no way to say why.
//
// This sheet also owns the presentation of the running screen: it opens
// `HCCLiveActivityView` as a full-screen cover, so a workout in progress cannot
// be swiped away, and closes itself when that screen is done.

struct HCCLiveSetupSheet: View {
  @ObservedObject var store: HealthDataStore
  @ObservedObject var state: HCCLiveState

  /// Set when the sheet was opened from a Training conditioning day: the stored
  /// activity is named after that day rather than a generic slug.
  var titleOverride: String?

  @Environment(\.dismiss) private var dismiss
  @State private var isStarting = false
  @State private var isLive = false

  init(store: HealthDataStore, titleOverride: String? = nil) {
    self.store = store
    self.state = store.hccLive
    self.titleOverride = titleOverride
  }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(
        title: "Start activity",
        subtitle: titleOverride ?? "Records heart rate while you train"
      )

      livePreview
      fields
      if let note = HCCLiveCopy.selectedDeviceNote(state: state) {
        HCCFootnote(note)
      }
      if state.sourceKind == .bluetooth { deviceCard }
      goalCard

      if let status = state.sourceStatus {
        HCCFootnote(status)
      }
      if let error = state.lastError {
        HCCErrorNote(error, title: "Not started")
      }

      HCCButtonRow(
        primary: HCCButtonSpec(title: "Start", isEnabled: !isStarting, action: start),
        secondary: HCCButtonSpec(title: "Cancel", isEnabled: !isStarting) {
          store.discardHCCLive()
          dismiss()
        }
      )

      HCCFootnote(HCCLiveCopy.sourceFootnote)
    }
    .onAppear {
      store.prepareHCCLive(titleOverride: titleOverride)
      #if DEBUG
      // The ported zone/strain arithmetic and the watch wire format, printed
      // for the run that checks them against `src/lib/activities/zones.ts`.
      // Off unless the matching environment variable is set.
      HCCZonesSelfCheck.runIfRequested()
      HCCWatchMirrorSelfCheck.runIfRequested()
      runDebugLaunchHookIfRequested()
      #endif
    }
    .onChange(of: state.sourceKind) { _, kind in
      if kind != .bluetooth { state.stopBluetoothScan() }
      state.startPreview()
    }
    .fullScreenCover(isPresented: $isLive, onDismiss: closeIfFinished) {
      HCCLiveActivityView(store: store)
    }
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  /// The reading, before anything is being recorded.
  ///
  /// This is the screen's answer to "is the right device actually on my wrist
  /// and talking to this phone" — the question a source picker alone cannot
  /// settle. A dash and the source's own sentence while it is still looking;
  /// never a number that is not currently arriving.
  private var livePreview: some View {
    VStack(spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(state.previewBpm.map(String.init) ?? "--")
          .font(HCCTheme.Font.display(size: 44, weight: .medium))
          .foregroundStyle(state.previewBpm == nil ? HCCTheme.Color.muted : HCCTheme.Color.text)
          .monospacedDigit()
        Text("bpm")
          .font(HCCTheme.Font.body(size: 13, weight: .medium))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      Text(previewStatus)
        .font(HCCTheme.Font.body(size: 11.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .hccCard()
  }

  /// What the reading is doing. A source that has said something for itself
  /// says it; otherwise this reports whether readings are arriving, which is
  /// the one thing the number alone cannot say once it has gone stale.
  private var previewStatus: String {
    if let status = state.sourceStatus { return status }
    return state.previewBpm == nil
      ? "Looking for \(state.sourceKind.label)..."
      : "Live from \(state.sourceKind.label)."
  }

  private var fields: some View {
    VStack(spacing: 0) {
      HCCFieldRow(title: "Type") {
        if let titleOverride {
          // The Training day named it; changing that here would store a row
          // under a name that day never had.
          HCCFieldValue(titleOverride)
        } else {
          Menu {
            Picker("Type", selection: $state.type) {
              ForEach(HCCSportCatalog.slugs, id: \.self) { slug in
                Text(HCCActivityCopy.title(for: slug)).tag(slug)
              }
            }
            .labelsHidden()
          } label: {
            HCCFieldValue("\(HCCActivityCopy.title(for: state.type)) ›")
          }
        }
      }

      HCCFieldRow(title: "Heart rate from", showsDivider: false) {
        Menu {
          Picker("Heart rate from", selection: $state.sourceKind) {
            ForEach(HCCLiveSourceKind.offered) { kind in
              Text(kind.label).tag(kind)
            }
          }
          .labelsHidden()
        } label: {
          HCCFieldValue("\(state.sourceKind.label) ›")
        }
      }
    }
    .hccCard()
  }

  private var deviceCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        HCCLabel("Devices found", size: 11)
        Spacer(minLength: 8)
        HCCChip("\(state.bleDevices.count)")
      }
      .padding(.bottom, 8)

      if state.bleDevices.isEmpty {
        HCCEmptyNote(
          "No heart-rate device yet. Put the strap on and keep this screen open — "
            + "it appears as soon as it starts broadcasting."
        )
      } else {
        VStack(spacing: 0) {
          ForEach(state.bleDevices) { device in
            HCCMenuRow(
              title: state.chosenDeviceId == device.id ? "✓ \(device.name)" : device.name,
              detail: "signal \(device.rssi) dBm",
              showsDivider: device.id != state.bleDevices.last?.id
            ) {
              state.chosenDeviceId = device.id
            }
          }
        }
      }
    }
    .hccCard()
  }

  private var goalCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCLabel("Zone goal", size: 11)
      HCCSegmentedControl(
        options: (1...5).map { .init(value: $0, title: "Z\($0)") },
        selection: $state.goalZone
      )
      HCCFootnote(HCCLiveCopy.goalFootnote(zone: state.goalZone, state: state))
    }
    .hccCard()
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  private func start() {
    isStarting = true
    Task {
      let started = await store.startHCCLive()
      isStarting = false
      if started { isLive = true }
    }
  }

  /// The running screen closed. If it stored something, this sheet has nothing
  /// left to do; if the wearer backed out of it, setup stays open.
  private func closeIfFinished() {
    guard state.phase == .done || state.phase == .idle else { return }
    store.discardHCCLive()
    dismiss()
  }

  #if DEBUG
  /// Drives one session from launch, because the simulator here has no way to
  /// tap: `simctl` can set environment variables and take screenshots, nothing
  /// more. Only meaningful together with `HCC_DEBUG_FAKE_HR=1`, the only source
  /// a simulator has.
  ///
  ///   `HCC_DEBUG_LIVE=start`              start as soon as the sheet appears
  ///   `HCC_DEBUG_LIVE_PAUSE_AFTER=<s>`    pause that many seconds after the start
  ///   `HCC_DEBUG_LIVE_END_AFTER=<s>`      end and save that many seconds after
  ///                                       the pause (or after the start if
  ///                                       there was none)
  ///
  /// The end path WRITES an activity to whatever backend the run points at, so
  /// it belongs against a local test instance only.
  private func runDebugLaunchHookIfRequested() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["HCC_DEBUG_LIVE"] == "start" else { return }
    Task {
      // One beat for `/instance` and `/home` to land, so the session starts
      // with the instance's own cuts rather than the fallback.
      try? await Task.sleep(for: .seconds(2))
      start()
      if let raw = environment["HCC_DEBUG_LIVE_PAUSE_AFTER"], let seconds = Double(raw) {
        try? await Task.sleep(for: .seconds(seconds))
        store.pauseHCCLive()
      }
      if let raw = environment["HCC_DEBUG_LIVE_END_AFTER"], let seconds = Double(raw) {
        try? await Task.sleep(for: .seconds(seconds))
        _ = await store.finishHCCLive()
      }
    }
  }
  #endif
}

/// What Training hands the sheet: the conditioning day's own title, so the
/// stored activity is named after that day rather than a generic slug.
/// `Identifiable` because it is what `.sheet(item:)` is keyed on.
struct HCCTrainingLiveStart: Identifiable, Hashable {
  let title: String
  var id: String { title }
}

// ── Copy ─────────────────────────────────────────────────────────────────────

/// The sentences this feature says, in one place.
///
/// Main-actor isolated because two of them read the live state to name the
/// ceiling the zones were cut against — the whole point of those sentences.
@MainActor
enum HCCLiveCopy {
  /// The mockup's footnote, verbatim apart from the manufacturer rule: the
  /// band's own name is not written, and "the band" is the app's word for it.
  static let sourceFootnote =
    "Live heart rate needs a streaming source: Apple Watch through the companion "
      + "Watch app, the band's Bluetooth broadcast, or a chest strap. The Fitbit "
      + "Air syncs after the fact."

  /// What the device pill means here, when it means anything.
  ///
  /// The pill picks which device's STORED readings drive the rings. A live
  /// number is a radio stream, so the two only line up for a device that can
  /// broadcast. When they do line up this says so; when they cannot it says
  /// which device is being used instead, rather than letting the screen wait
  /// on a reading that is never coming.
  static func selectedDeviceNote(state: HCCLiveState) -> String? {
    guard let device = state.selectedDeviceLabel else { return nil }
    if !state.selectedDeviceCanStream {
      return "\(device) drives your rings, but it has no live feed — it syncs "
        + "after the session. This reading comes from the source above instead."
    }
    if state.sourceKind == .bluetooth {
      return "\(device) drives your rings and can broadcast live heart rate. "
        + "Switch its broadcast on in its own app and it appears below."
    }
    return "\(device) drives your rings and streams live through the companion app."
  }

  static func goalFootnote(zone: Int, state: HCCLiveState) -> String {
    let config = state.zoneConfig
    let percent = HCCZones.percentLabel(zone: zone, config: config) ?? "--"
    let basis = state.restingHr == nil ? "of max heart rate" : "of heart-rate reserve"
    guard let range = HCCZones.range(zone: zone, config: config, restingHr: state.restingHr) else {
      return "Zone \(zone) is \(percent) \(basis)."
    }
    return "Zone \(zone) is \(percent) \(basis) — about \(range.lowerBound)–\(range.upperBound) bpm "
      + "against the \(Int(config.maxHr.rounded())) bpm ceiling your Command Center publishes."
  }

  /// Where the ceiling came from. Shown on the running screen, because every
  /// zone number on it moves with this one value.
  static func ceilingNote(state: HCCLiveState) -> String {
    let maxHr = Int(state.zoneConfig.maxHr.rounded())
    let source = state.zoneConfigIsFromServer
      ? "your Command Center's published"
      : "the default"
    let rest = state.restingHr.map { " and a resting heart rate of \(Int($0.rounded())) bpm" } ?? ""
    return "Zones are cut against \(source) ceiling of \(maxHr) bpm\(rest). "
      + "Every zone figure here moves with that ceiling."
  }
}
