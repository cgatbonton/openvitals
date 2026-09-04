import SwiftUI

// `S.addActivity` from the approved mockup, in both of its modes: logging a new
// activity by hand, and editing one that was logged that way.
//
// Nothing here computes a strain. The sheet sends type, window, effort and
// notes; the server estimates the strain and hands the stored row back, and the
// activity screen shows what came back. A client-side preview of the number
// would be a second implementation of the estimate, free to disagree with the
// one that is actually stored.

struct HCCAddActivitySheet: View {
  @ObservedObject var store: HealthDataStore

  /// Non-nil puts the sheet in edit mode.
  var editing: HCCActivityDetail?
  /// Handed the server's stored row after a successful edit, so the screen
  /// underneath can show it without refetching.
  var onSaved: ((HCCActivityDetail) -> Void)?

  @Environment(\.dismiss) private var dismiss

  @State private var type: String = HCCSportCatalog.slugs.first ?? "other"
  @State private var start = Date().addingTimeInterval(-30 * 60)
  @State private var end = Date()
  @State private var effort: Int = HCCPerceivedEffort.moderate.value
  @State private var notes = ""
  @State private var isSaving = false
  @State private var errorText: String?
  @State private var didPrefill = false

  private var isEditing: Bool { editing != nil }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(
        title: isEditing ? "Edit activity" : "Add activity",
        subtitle: isEditing ? "Manual entry" : "Manual entry, saved to today"
      )

      fields
      strainCard

      if let errorText {
        HCCEmptyNote(errorText)
          .hccCard()
      }

      HCCButtonRow(
        primary: HCCButtonSpec(
          title: isEditing ? "Save changes" : "Save activity",
          isEnabled: !isSaving && end > start,
          action: save
        ),
        secondary: HCCButtonSpec(title: "Cancel", isEnabled: !isSaving) { dismiss() }
      )

      if end <= start {
        HCCFootnote("The end time has to be after the start time.")
          .padding(.top, 8)
      }
    }
    .onAppear(perform: prefillIfNeeded)
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  private var fields: some View {
    VStack(spacing: 0) {
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

      HCCFieldRow(title: "Start") {
        DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .tint(HCCTheme.Color.accent)
      }

      HCCFieldRow(title: "End") {
        DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .tint(HCCTheme.Color.accent)
      }

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

  private var strainCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Strain")
      // The mockup's sentence offers a heart-rate computation. This server has
      // no intraday heart-rate store, so a hand-logged activity is ALWAYS an
      // estimate — see `estimateStrain` in src/lib/activities/zones.ts. Saying
      // otherwise would promise a measurement that never happens.
      Text("Estimated on the server from type, effort and duration, and marked as an estimate. A hand-logged activity is never computed from a heart-rate trace.")
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .hccCard()
  }

  // ── State ──────────────────────────────────────────────────────────────────

  private func prefillIfNeeded() {
    guard !didPrefill, let editing else { return }
    didPrefill = true
    type = editing.type
    if let parsed = HCCTime.instant(editing.startAt) { start = parsed }
    if let parsed = HCCTime.instant(editing.endAt) { end = parsed }
    if let stored = editing.effort { effort = Int(stored.rounded()) }
    notes = editing.notes ?? ""
  }

  private func save() {
    guard !isSaving, end > start else { return }
    isSaving = true
    errorText = nil

    let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      if let editing {
        let patch = HCCActivityPatch(
          type: type,
          startAt: HCCTime.isoInstant(start),
          endAt: HCCTime.isoInstant(end),
          effort: effort,
          notes: trimmed
        )
        if let saved = await store.updateActivity(id: editing.id, patch) {
          onSaved?(saved)
          isSaving = false
          dismiss()
          return
        }
      } else {
        let draft = HCCActivityCreate(
          type: type,
          startAt: HCCTime.isoInstant(start),
          endAt: HCCTime.isoInstant(end),
          effort: effort,
          notes: trimmed.isEmpty ? nil : trimmed,
          trainingSessionId: nil
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
