import SwiftUI

// `S.addActivity` from the approved mockup, in all of its modes: logging a new
// workout, night or nap by hand, editing one that was logged that way, and
// editing or deleting a row a device recorded (the mockup's activity screen
// offers "Edit" on a device's row, and `S.activity` is what this sheet is
// opened from; the sleep screen opens it for the night).
//
// Nothing here computes a strain or a sleep score. For a workout the sheet
// sends type, window, effort and notes; the server estimates the strain and
// hands the stored row back, and the activity screen shows what came back. A
// client-side preview of the number would be a second implementation of the
// estimate, free to disagree with the one that is actually stored. A device's
// row is different only in what the server does with the write: it keeps the
// new type and window across the next sync and leaves the measured strain
// alone — so the sheet neither offers an effort for it nor promises a re-score.
//
// A sleep is the other half. The sheet sends the window and the TIME ASLEEP,
// and the server lays the owner's figure over the device's for that night,
// re-grades it and every debt-dependent night after it, and the night screen
// shows what came back. A nap goes the same way and is read by the sleep
// model's nap term instead — it shortens tonight's need and pays debt, and it
// never stands in for the night.

/// What the sheet is logging. Chosen with the segmented control when adding;
/// fixed when editing, because a row does not change kind.
enum HCCActivityEntry: String, CaseIterable, Identifiable, Hashable {
  case workout
  case sleep
  case nap

  var id: String { rawValue }

  var isSleep: Bool { self != .workout }

  var title: String {
    switch self {
    case .workout: "Workout"
    case .sleep: "Sleep"
    case .nap: "Nap"
    }
  }

  /// The server's `type` for the two sleep entries; a workout's is its sport.
  var sleepType: String { rawValue }

  static func of(_ detail: HCCActivityDetail) -> HCCActivityEntry {
    guard detail.kind.uppercased() == "SLEEP" else { return .workout }
    return detail.type.lowercased() == HCCActivityRoute.napType ? .nap : .sleep
  }
}

struct HCCAddActivitySheet: View {
  @ObservedObject var store: HealthDataStore

  /// Non-nil puts the sheet in edit mode.
  var editing: HCCActivityDetail?
  /// The entry to open on when adding. Ignored when editing.
  var initialEntry: HCCActivityEntry = .workout
  /// When adding a night from the sleep screen: the wake day it belongs to,
  /// so the default window is THAT night rather than last night.
  var nightOf: String?
  /// Handed the server's stored row after a successful edit, so the screen
  /// underneath can show it without refetching.
  var onSaved: ((HCCActivityDetail) -> Void)?
  /// Called once the server has confirmed the delete, before the sheet
  /// dismisses — the screen underneath has nothing left to show.
  var onDeleted: (() -> Void)?

  @Environment(\.dismiss) private var dismiss

  @State private var entry: HCCActivityEntry = .workout
  @State private var type: String = HCCSportCatalog.slugs.first ?? "other"
  @State private var start = Date().addingTimeInterval(-30 * 60)
  @State private var end = Date()
  @State private var effort: Int = HCCPerceivedEffort.moderate.value
  /// Sleep entries: minutes asleep inside the window.
  @State private var asleepMin: Int = 0
  @State private var notes = ""
  @State private var isSaving = false
  @State private var isDeleting = false
  @State private var confirmingDelete = false
  @State private var errorText: String?
  @State private var didPrefill = false

  private var isEditing: Bool { editing != nil }
  /// A row a device recorded, as opposed to one logged by hand.
  private var isProviderRow: Bool {
    guard let editing else { return false }
    return editing.source.uppercased() != "MANUAL"
  }
  private var isBusy: Bool { isSaving || isDeleting }
  private var windowMin: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
  private var windowIsValid: Bool { end > start && (!entry.isSleep || windowMin <= 24 * 60) }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: title, subtitle: subtitle)

      fields
      infoCard

      if let errorText {
        HCCEmptyNote(errorText)
          .hccCard()
      }

      HCCButtonRow(
        primary: HCCButtonSpec(
          title: isEditing ? "Save changes" : "Save \(entry.title.lowercased())",
          isEnabled: !isBusy && windowIsValid,
          action: save
        ),
        secondary: HCCButtonSpec(title: "Cancel", isEnabled: !isBusy) { dismiss() }
      )

      if end <= start {
        HCCFootnote("The end time has to be after the start time.")
          .padding(.top, 8)
      } else if entry.isSleep, windowMin > 24 * 60 {
        HCCFootnote("A sleep cannot be longer than a day.")
          .padding(.top, 8)
      }

      if isEditing {
        HCCButtonRow(
          secondary: HCCButtonSpec(title: "Delete \(entry.title.lowercased())", isEnabled: !isBusy, isDestructive: true) {
            confirmingDelete = true
          }
        )
      }
    }
    .onAppear(perform: prefillIfNeeded)
    .onChange(of: entry) { _, next in
      if !isEditing { applyDefaults(for: next) }
    }
    // The figure cannot exceed the window it sits in; a shorter window pulls
    // it down rather than leaving a claim the server will refuse.
    .onChange(of: start) { _, _ in asleepMin = min(asleepMin, windowMin) }
    .onChange(of: end) { _, _ in asleepMin = min(asleepMin, windowMin) }
    .confirmationDialog("Delete this \(entry.title.lowercased())?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete \(entry.title.lowercased())", role: .destructive, action: deleteActivity)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(deleteMessage)
    }
  }

  // ── Copy ───────────────────────────────────────────────────────────────────

  private var title: String {
    isEditing ? "Edit \(entry.title.lowercased())" : "Add activity"
  }

  private var subtitle: String {
    if isEditing {
      return isProviderRow ? "Recorded by \(HCCCopy.sourceLabel(editing?.source))" : "Manual entry"
    }
    switch entry {
    case .workout, .nap:
      return "Manual entry, saved to today"
    case .sleep:
      let day = nightOf ?? HealthDataStore.hccDayKey(Date())
      return "Manual entry, the night ending \(HealthDataStore.hccDayLabel(day).lowercased())"
    }
  }

  private var deleteMessage: String {
    switch entry {
    case .workout:
      return isProviderRow
        ? "It comes off every device's record of this time, and the next sync will not bring it back."
        : "This cannot be undone."
    case .sleep:
      return "This night will read as no sleep on record, and the next sync will not bring it back."
    case .nap:
      return isProviderRow
        ? "It comes off tonight's need, and the next sync will not bring it back."
        : "It comes off tonight's need. This cannot be undone."
    }
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  private var fields: some View {
    VStack(spacing: 0) {
      if !isEditing {
        HCCSegmentedControl(
          options: HCCActivityEntry.allCases.map { .init(value: $0, title: $0.title) },
          selection: $entry
        )
      }

      if !entry.isSleep {
        HCCFieldRow(title: "Type") {
          Menu {
            Picker("Type", selection: $type) {
              ForEach(HCCSportCatalog.slugs, id: \.self) { slug in
                Text(HCCActivityCopy.title(for: slug)).tag(slug)
              }
            }
            .labelsHidden()
          } label: {
            HCCFieldValue("\(HCCActivityCopy.title(for: type)) ›")
          }
        }
      }

      HCCFieldRow(title: entry.isSleep ? "Fell asleep" : "Start") {
        DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .tint(HCCTheme.Color.accent)
      }

      HCCFieldRow(title: entry.isSleep ? "Woke up" : "End") {
        DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .tint(HCCTheme.Color.accent)
      }

      // The figure the sleep model reads. In-bed minus awake, which a device
      // knows and a hand does not — so it defaults to the whole window and the
      // owner takes the awake time off.
      if entry.isSleep {
        HCCFieldRow(title: "Time asleep") {
          HCCStepper(
            value: $asleepMin,
            range: 0...max(windowMin, 0),
            step: 5,
            label: { HCCWallClock.duration(minutes: Double($0)) }
          )
        }
      }

      // Effort is the input to the hand-logged estimate. A device's row has a
      // measured strain that no effort would change, so the row is not offered.
      if !entry.isSleep && !isProviderRow {
        HCCFieldRow(title: "Perceived effort") {
          Menu {
            Picker("Perceived effort", selection: $effort) {
              ForEach(HCCPerceivedEffort.allCases) { level in
                Text("\(level.title) · \(level.value)/10").tag(level.value)
              }
            }
            .labelsHidden()
          } label: {
            HCCFieldValue("\(HCCPerceivedEffort.title(for: effort)) ›")
          }
        }
      }

      HCCFieldRow(title: "Notes", showsDivider: false) {
        TextField("", text: $notes, prompt: Text("Optional").foregroundColor(HCCTheme.Color.muted))
          .font(HCCTheme.Font.data(size: 12.5))
          .foregroundStyle(HCCTheme.Color.accent)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.sentences)
      }
    }
    .hccCard()
  }

  private var infoCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel(entry.isSleep ? "Sleep" : "Strain")
      Text(infoText)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .hccCard()
  }

  /// What the server will do with the write — said plainly, so the sheet never
  /// promises a computation that does not happen or hides one that does.
  private var infoText: String {
    switch entry {
    case .workout:
      // The mockup's sentence offers a heart-rate computation. This server has
      // no intraday heart-rate store, so a hand-logged activity is ALWAYS an
      // estimate — see `estimateStrain` in src/lib/activities/zones.ts — and a
      // device's row is never re-scored by an edit.
      return isProviderRow
        ? "Strain, heart rate and zones stay as the device measured them. Changing the type or the window relabels the activity; it does not re-score it."
        : "Estimated on the server from type, effort and duration, and marked as an estimate. A hand-logged activity is never computed from a heart-rate trace."
    case .sleep:
      return isProviderRow
        ? "Your time asleep replaces the device's for this night's score, sleep debt and tonight's need, and the next sync keeps it. Stages stay as the device measured them; moving the window keeps its awake time and moves the sleep with it."
        : "Time asleep is what this night is scored on; the window is what the list shows. Saving re-grades the night and every night after it that carries its debt."
    case .nap:
      return "A nap lowers tonight's sleep need and pays down sleep debt. It counts toward tomorrow's recovery, never today's, and never stands in for a night."
    }
  }

  // ── State ──────────────────────────────────────────────────────────────────

  private static var instanceCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = HealthDataStore.hccInstanceTimeZone
    return calendar
  }

  private func prefillIfNeeded() {
    guard !didPrefill else { return }
    didPrefill = true
    guard let editing else {
      entry = initialEntry
      applyDefaults(for: initialEntry)
      return
    }
    entry = HCCActivityEntry.of(editing)
    type = editing.type
    if let parsed = HCCTime.instant(editing.startAt) { start = parsed }
    if let parsed = HCCTime.instant(editing.endAt) { end = parsed }
    if let stored = editing.effort { effort = Int(stored.rounded()) }
    notes = editing.notes ?? ""
    if entry.isSleep { asleepMin = prefilledAsleepMin(editing) }
  }

  /// The row's own figure when it has one. A device's night usually does not
  /// carry it on the row, but the night screen has the device's awake time,
  /// so the same arithmetic the server uses (window minus awake) runs here;
  /// failing both, the whole window.
  private func prefilledAsleepMin(_ editing: HCCActivityDetail) -> Int {
    if let stored = editing.asleepMin { return Int(stored.rounded()) }
    let window = Int(editing.durationMin.rounded())
    guard entry == .sleep,
          let night = store.hcc.sleep,
          let wake = HCCTime.instant(editing.endAt),
          night.date == HealthDataStore.hccDayKey(wake),
          let awake = night.stages.awakeH
    else {
      return window
    }
    return max(0, min(window, window - Int((awake * 60).rounded())))
  }

  /// A fresh entry's window: the last half hour for a workout or a nap, last
  /// night (23:00–07:00 in the instance's zone) for a sleep — or the night
  /// ending on `nightOf` when the sleep screen asked for a specific day.
  private func applyDefaults(for entry: HCCActivityEntry) {
    let now = Date()
    switch entry {
    case .workout, .nap:
      start = now.addingTimeInterval(-30 * 60)
      end = now
    case .sleep:
      let calendar = Self.instanceCalendar
      let wakeDay = nightOf.flatMap(HealthDataStore.hccLocalDate(fromDayKey:)) ?? now
      let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: wakeDay) ?? now
      end = wake
      start = calendar.date(byAdding: .hour, value: -8, to: wake) ?? wake.addingTimeInterval(-8 * 3600)
    }
    asleepMin = windowMin
  }

  private func deleteActivity() {
    guard !isBusy, let editing else { return }
    isDeleting = true
    errorText = nil
    Task {
      if await store.deleteActivity(id: editing.id) {
        isDeleting = false
        onDeleted?()
        dismiss()
        return
      }
      errorText = store.hcc.lastError ?? "That did not delete. Nothing was changed."
      isDeleting = false
    }
  }

  private func save() {
    guard !isBusy, windowIsValid else { return }
    isSaving = true
    errorText = nil

    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      if let editing {
        var patch = HCCActivityPatch()
        patch.startAt = HCCTime.isoInstant(start)
        patch.endAt = HCCTime.isoInstant(end)
        patch.notes = trimmed
        if entry.isSleep {
          patch.asleepMin = asleepMin
        } else {
          patch.type = type
          // No effort for a device's row: it was never offered, and sending the
          // default would write a number nobody chose.
          patch.effort = isProviderRow ? nil : effort
        }
        if let saved = await store.updateActivity(id: editing.id, patch) {
          onSaved?(saved)
          isSaving = false
          dismiss()
          return
        }
      } else {
        let draft = HCCActivityCreate(
          kind: entry.isSleep ? "SLEEP" : "WORKOUT",
          type: entry.isSleep ? entry.sleepType : type,
          startAt: HCCTime.isoInstant(start),
          endAt: HCCTime.isoInstant(end),
          effort: entry.isSleep ? nil : effort,
          notes: trimmed.isEmpty ? nil : trimmed,
          trainingSessionId: nil,
          asleepMin: entry.isSleep ? asleepMin : nil
        )
        if let saved = await store.addActivity(draft) {
          onSaved?(saved)
          isSaving = false
          dismiss()
          return
        }
      }
      // The store puts the server's own message here on a failure. Surfacing it
      // rather than a generic line is what stops a write that did not happen
      // from looking like one that did.
      errorText = store.hcc.lastError ?? "That did not save. Nothing was changed."
      isSaving = false
    }
  }
}

// ── Vocabulary ───────────────────────────────────────────────────────────────

/// The sport slugs the picker offers.
///
/// `Activity.type` is free text on the server on purpose, so this list is the
/// PHONE's shortlist, not a schema. Every slug here is one the server's
/// intensity table recognises (`TYPE_INTENSITY` in src/lib/activities/zones.ts);
/// `other` deliberately falls through to that table's moderate default.
enum HCCSportCatalog {
  static let slugs = [
    "walking",
    "running",
    "cycling",
    "assault_bike",
    "strength",
    "crossfit",
    "rowing",
    "swimming",
    "hiking",
    "bouldering",
    "brazilian_jiu_jitsu",
    "other",
  ]
}

/// The four words the sheet offers, and the 1–10 the server stores.
enum HCCPerceivedEffort: CaseIterable, Identifiable {
  case light
  case moderate
  case hard
  case allOut

  var id: Int { value }

  var title: String {
    switch self {
    case .light: "Light"
    case .moderate: "Moderate"
    case .hard: "Hard"
    case .allOut: "All-out"
    }
  }

  var value: Int {
    switch self {
    case .light: 3
    case .moderate: 5
    case .hard: 8
    case .allOut: 10
    }
  }

  /// A stored effort that is not one of the four (an older client, or a value
  /// the web app wrote) is shown as its own number rather than snapped to the
  /// nearest word — the row should say what is stored.
  static func title(for value: Int) -> String {
    allCases.first { $0.value == value }?.title ?? "\(value)/10"
  }
}
