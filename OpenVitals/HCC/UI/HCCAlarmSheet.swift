import SwiftUI

// `S.alarm` from the approved mockup: the wake target, and the bedtime the
// server derives from it.
//
// Two things this screen is careful about:
//
//  * The alarm time is a WALL CLOCK in the instance's timezone, not an instant.
//    The server stores `HH:MM` for exactly that reason (a wake time is a local
//    promise, wrong the moment it is stored as UTC), so the wheel below is
//    driven in UTC and read back as `HH:MM` — the device's own timezone never
//    enters the arithmetic.
//  * Nothing here schedules an alarm. AlarmKit is Phase 3; this row is the
//    record of INTENT that both this app and the web app read, and the footer
//    says so rather than letting the switch imply the phone will ring.

struct HCCAlarmSheet: View {
  @ObservedObject var store: HealthDataStore
  @Environment(\.dismiss) private var dismiss

  @State private var minutesFromMidnight = 0
  @State private var mode = "exact"
  @State private var isOn = true
  @State private var watchHaptic = true
  @State private var smartWindowMin = 30
  @State private var showsWheel = false
  @State private var isSaving = false
  @State private var errorText: String?
  @State private var didPrefill = false

  /// A reference day the wheel's `Date` proxy hangs off. Only its time of day
  /// is ever read back.
  private static let referenceDay = Date(timeIntervalSince1970: 0)
  private static let utc = TimeZone(identifier: "UTC") ?? .gmt

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Alarm", subtitle: "Tonight")
      settingsCard
      bedtimeCard

      if let errorText {
        HCCEmptyNote(errorText).hccCard()
      }

      HCCButtonRow(
        primary: HCCButtonSpec(title: "Save alarm", isEnabled: !isSaving, action: save),
        secondary: HCCButtonSpec(title: "Cancel", isEnabled: !isSaving) { dismiss() }
      )

      HCCFootnote("The phone alarm is scheduled once the alarm feature ships. For now this saves the wake time your Command Center reasons about.")
        .padding(.top, 10)
    }
    .onAppear(perform: prefillIfNeeded)
    // The alarm may still be in flight when this sheet opens. `didPrefill` is
    // only set once a row actually arrives, so this fills the fields the moment
    // it does — and never overwrites an edit in progress.
    .onChange(of: store.hcc.alarm) { _, _ in prefillIfNeeded() }
  }

  // ── Settings ───────────────────────────────────────────────────────────────

  private var settingsCard: some View {
    VStack(spacing: 0) {
      timePicker

      HCCSegmentedControl(
        options: [
          .init(value: "exact", title: "Exact time"),
          .init(value: "goal", title: "By sleep goal"),
        ],
        selection: $mode
      )

      HCCToggleRow(title: "Alarm on", isOn: $isOn)
      HCCToggleRow(title: "Haptic on Apple Watch", isOn: $watchHaptic)

      HCCFieldRow(title: "Smart wake window", showsDivider: false) {
        HCCStepper(value: $smartWindowMin, range: 0...60, step: 5, suffix: "min")
      }
    }
    .hccCard()
  }

  private var timePicker: some View {
    VStack(spacing: 0) {
      Button {
        showsWheel.toggle()
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          let split = HCCWallClock.split(wallClock)
          Text(split?.time ?? "--")
            .font(HCCTheme.Font.display(size: 44, weight: .medium))
            .monospacedDigit()
            .tracking(-0.88)
            .foregroundStyle(HCCTheme.Color.text)
          Text(split?.suffix ?? "")
            .font(HCCTheme.Font.body(size: 14, weight: .medium))
            .foregroundStyle(HCCTheme.Color.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Alarm time")
      .accessibilityValue(wallClock)
      .accessibilityHint("Opens the time wheel")

      if showsWheel {
        DatePicker("", selection: wheelBinding, displayedComponents: [.hourAndMinute])
          .datePickerStyle(.wheel)
          .labelsHidden()
          // The wheel is a proxy for a wall clock, so it is read in UTC and the
          // device's own zone is kept out of the conversion entirely.
          .environment(\.timeZone, Self.utc)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var wallClock: String { HCCWallClock.hhmm(fromMinutes: minutesFromMidnight) }

  private var wheelBinding: Binding<Date> {
    Binding {
      Self.referenceDay.addingTimeInterval(TimeInterval(minutesFromMidnight * 60))
    } set: { newValue in
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = Self.utc
      let parts = calendar.dateComponents([.hour, .minute], from: newValue)
      minutesFromMidnight = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
  }

  // ── Bedtime ────────────────────────────────────────────────────────────────

  private var bedtimeCard: some View {
    let plan = store.hcc.sleepPlan
    let zone = store.hcc.instance?.timezone
    let bedtime = plan?.recommendedBedtime.flatMap { HCCWallClock.clock(iso: $0, timezone: zone) }

    return VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Recommended bedtime")
      HStack(alignment: .top, spacing: 10) {
        Text(bedtime ?? "--")
          .font(HCCTheme.Font.display(size: 26, weight: .medium))
          .monospacedDigit()
          .tracking(-0.52)
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        Text(bedtimeExplanation(plan: plan, hasBedtime: bedtime != nil))
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .multilineTextAlignment(.trailing)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 176, alignment: .trailing)
      }
      if isDirty {
        HCCFootnote("This is the plan for the saved alarm. Save to have it re-sized.")
          .padding(.top, 4)
      }
    }
    .hccCard()
  }

  /// The mode-specific sentence, or the reason there is no bedtime to show.
  private func bedtimeExplanation(plan: HCCSleepPlan?, hasBedtime: Bool) -> String {
    guard let plan, hasBedtime else {
      return "No bedtime yet — the server needs some sleep history to size tonight."
    }
    if mode == "exact" {
      guard let need = plan.needH else {
        return "To meet tonight's need before the alarm."
      }
      return "To meet tonight's \(HCCWallClock.duration(minutes: need * 60)) need before the alarm."
    }
    return "Aims for 100% of need; the alarm shifts inside the window."
  }

  // ── State ──────────────────────────────────────────────────────────────────

  private var stored: HCCAlarm? { store.hcc.alarm }

  private var edited: HCCAlarm {
    HCCAlarm(
      time: wallClock,
      mode: mode,
      on: isOn,
      smartWindowMin: smartWindowMin,
      watchHaptic: watchHaptic
    )
  }

  private var isDirty: Bool { stored.map { $0 != edited } ?? true }

  private func prefillIfNeeded() {
    guard !didPrefill, let stored else { return }
    didPrefill = true
    minutesFromMidnight = HCCWallClock.minutes(from: stored.time) ?? 0
    mode = stored.mode
    isOn = stored.on
    watchHaptic = stored.watchHaptic
    smartWindowMin = stored.smartWindowMin
    #if DEBUG
    runDebugSaveIfRequested()
    #endif
  }

  #if DEBUG
  /// Verification hook, DEBUG only. `HCC_DEBUG_SAVE=1` on the launch
  /// environment nudges the wake time and flips the mode, then runs the SAME
  /// `save()` the button calls — so a simulator run without UI automation can
  /// still prove the write reaches the server. The whole method is compiled out
  /// of Release, and it does nothing unless that variable is set.
  private func runDebugSaveIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SAVE"] == "1" else { return }
    minutesFromMidnight += 5
    mode = mode == "exact" ? "goal" : "exact"
    save()
  }
  #endif

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    errorText = nil
    let alarm = edited
    Task {
      if await store.saveAlarm(alarm) {
        isSaving = false
        dismiss()
        return
      }
      errorText = store.hcc.lastError ?? "That did not save. The alarm is unchanged."
      isSaving = false
    }
  }
}
