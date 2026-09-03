import SwiftUI

// "Log a reading" — the More tab's manual measurement entry.
//
// There is no mockup screen for this one: the approved deck stops at
// `S.addActivity`, and this sheet is built from the same parts so the two
// manual-entry surfaces are recognisably one design — the field card, the
// segmented value/unit pair, the two-button footer.
//
// What it refuses to do is as important as what it does:
//
//  * **It never grades the value.** A logging form that said "that's low" would
//    be grading against a target the user is in the middle of typing a value
//    for. The catalog's `refLow`/`refHigh` are read (they arrive on the same
//    payload) and deliberately not rendered here; the biomarker screens are
//    where a value meets its optimal target.
//  * **It never converts.** The unit shown beside the field is the catalog's,
//    and the server stores the metric's canonical unit — so the field says
//    which unit it wants rather than guessing what the number meant.
//  * **The time is a wall clock in the INSTANCE's timezone**, like every other
//    time on these screens, so a reading taken at 8 a.m. lands on the day the
//    Command Center calls today.

struct HCCLogReadingSheet: View {
  @ObservedObject var store: HealthDataStore
  @ObservedObject var state: HCCLogReadingState
  /// Open straight onto the metric picker. Set only by the DEBUG launch hook,
  /// so a scripted run can screenshot the picker without a tap.
  var opensPicker = false

  @Environment(\.dismiss) private var dismiss

  @State private var slug: String?
  @State private var valueText = ""
  @State private var measuredAt = Date()
  @State private var notes = ""
  @State private var showsPicker = false
  @State private var didAppear = false

  private var zone: TimeZone {
    (store.hcc.instance?.timezone).flatMap(TimeZone.init(identifier:)) ?? HCCInstanceZone.current
  }

  private var selected: HCCMetric? { slug.flatMap(state.metric) }

  /// "80.5" → 80.5. A comma is accepted because a decimal keypad in a
  /// comma-decimal locale produces one, and refusing it would look like the
  /// field is broken.
  private var parsedValue: Double? {
    let cleaned = valueText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    guard !cleaned.isEmpty, let parsed = Double(cleaned), parsed.isFinite else { return nil }
    return parsed
  }

  private var canSave: Bool { slug != nil && parsedValue != nil && !state.isSaving }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Log a reading", subtitle: "Manual entry")

      fieldsCard

      if let line = state.lastSavedLine {
        savedCard(line)
      }

      if let errorText = state.errorText {
        HCCEmptyNote(errorText).hccCard()
      }

      HCCButtonRow(
        primary: HCCButtonSpec(title: "Save reading", isEnabled: canSave, action: save),
        secondary: HCCButtonSpec(title: "Done", isEnabled: !state.isSaving) { dismiss() }
      )

      HCCFootnote("Saved to your Command Center as a manual reading, on the same timeline as your device data.")
        .padding(.top, 10)
    }
    .sheet(isPresented: $showsPicker) {
      HCCMetricPickerSheet(state: state, selection: $slug)
    }
    .task { await store.loadReadingMetricsIfNeeded() }
    .onAppear(perform: onFirstAppear)
  }

  // ── Fields ─────────────────────────────────────────────────────────────────

  private var fieldsCard: some View {
    VStack(spacing: 0) {
      HCCFieldRow(title: "Metric") {
        Button { showsPicker = true } label: {
          HCCFieldValue("\(metricLabel) ›")
        }
        .buttonStyle(.plain)
        .disabled(state.metrics.isEmpty)
      }

      HCCFieldRow(title: "Value") {
        HStack(spacing: 6) {
          TextField(
            "",
            text: $valueText,
            prompt: Text("0").foregroundColor(HCCTheme.Color.muted)
          )
          .keyboardType(.decimalPad)
          .font(HCCTheme.Font.data(size: 12.5))
          .foregroundStyle(HCCTheme.Color.accent)
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 96)
          if let unit = selected?.unit, !unit.isEmpty {
            Text(unit)
              .font(HCCTheme.Font.data(size: 12.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
      }

      HCCFieldRow(title: "Taken at") {
        DatePicker("Taken at", selection: $measuredAt, displayedComponents: [.date, .hourAndMinute])
          .labelsHidden()
          .tint(HCCTheme.Color.accent)
          // The instance's zone, not the phone's: the server buckets this
          // reading onto ITS civil day.
          .environment(\.timeZone, zone)
      }

      HCCFieldRow(title: "Note", showsDivider: false) {
        TextField("", text: $notes, prompt: Text("Optional").foregroundColor(HCCTheme.Color.muted))
          .font(HCCTheme.Font.data(size: 12.5))
          .foregroundStyle(HCCTheme.Color.accent)
          .multilineTextAlignment(.trailing)
          .textInputAutocapitalization(.sentences)
      }
    }
    .hccCard()
  }

  private var metricLabel: String {
    if let selected {
      guard let unit = selected.unit, !unit.isEmpty else { return selected.displayName }
      return "\(selected.displayName) · \(unit)"
    }
    if state.isLoadingMetrics { return "Loading" }
    if state.metricsError != nil { return "Unavailable" }
    return "Choose"
  }

  private func savedCard(_ line: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Saved")
      Text(line)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.text)
        .fixedSize(horizontal: false, vertical: true)
    }
    .hccCard()
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  private func save() {
    guard let slug, let value = parsedValue, !state.isSaving else { return }
    let note = notes
    let when = measuredAt
    Task {
      if await store.logReading(metricSlug: slug, value: value, measuredAt: when, notes: note) {
        // The form is cleared rather than the sheet dismissed: logging two
        // readings in a row (weight, then a BP) is the common case, and the
        // confirmation line is the receipt for the one that just landed.
        valueText = ""
        notes = ""
        measuredAt = Date()
      }
    }
  }

  private func onFirstAppear() {
    guard !didAppear else { return }
    didAppear = true
    state.errorText = nil
    state.lastSavedLine = nil
    slug = state.recentSlugs.first
    if opensPicker { showsPicker = true }
    #if DEBUG
    runDebugSaveIfRequested()
    #endif
  }

  #if DEBUG
  /// Verification hook, DEBUG only. `HCC_DEBUG_SAVE=1` on the launch
  /// environment fills in a fixed weight reading and runs the SAME `save()` the
  /// button calls, so a simulator run can prove the write reaches the server
  /// with no UI automation. Compiled out of Release, and inert without the
  /// variable.
  ///
  /// It writes a REAL row to whichever instance the launch environment points
  /// at — never set it against data you are not willing to change.
  private func runDebugSaveIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SAVE"] == "1" else { return }
    Task {
      // The catalog has to be in hand first: the confirmation line names the
      // metric and its unit from the catalog, not from the slug typed here.
      await store.loadReadingMetricsIfNeeded()
      slug = "weight"
      valueText = "80.5"
      measuredAt = Date()
      save()
    }
  }
  #endif
}

// ── Metric picker ────────────────────────────────────────────────────────────

/// The catalog, searchable, with the slugs this phone logged most recently
/// pulled to the top.
///
/// 215 rows is too many to scroll for the four or five a person actually logs
/// by hand, and the server has no "recently logged" endpoint — so the shortcut
/// is what THIS phone typed, held in `UserDefaults`. It is a convenience, not a
/// claim about the account: a reading logged on the web will not appear here,
/// which is why the section is titled "Recent on this iPhone".
struct HCCMetricPickerSheet: View {
  @ObservedObject var state: HCCLogReadingState
  @Binding var selection: String?

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Metric", subtitle: "From your Command Center's catalog")

      searchCard

      if state.isLoadingMetrics, state.metrics.isEmpty {
        HCCLoadingNote().hccCard()
      } else if let error = state.metricsError, state.metrics.isEmpty {
        HCCErrorNote(error)
      }

      if !recents.isEmpty, query.isEmpty {
        section(title: "Recent on this iPhone", metrics: recents)
      }

      let all = state.matches(query)
      if all.isEmpty, !state.metrics.isEmpty {
        HCCEmptyNote("No metric matches \"\(query)\".").hccCard()
      } else if !all.isEmpty {
        section(title: query.isEmpty ? "All metrics" : "Matches", metrics: all)
      }
    }
  }

  private var recents: [HCCMetric] {
    state.recentSlugs.compactMap(state.metric)
  }

  private var searchCard: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(HCCTheme.Color.muted)
      TextField(
        "",
        text: $query,
        prompt: Text("Search the catalog").foregroundColor(HCCTheme.Color.muted)
      )
      .font(HCCTheme.Font.body(size: 13.5))
      .foregroundStyle(HCCTheme.Color.text)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      if !query.isEmpty {
        Button { query = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(HCCTheme.Color.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .hccCard()
  }

  private func section(title: String, metrics: [HCCMetric]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel(title)
      VStack(spacing: 0) {
        ForEach(Array(metrics.enumerated()), id: \.element.slug) { index, metric in
          HCCMenuRow(
            title: metric.displayName,
            detail: metric.unit?.nilIfBlankUnit,
            showsDivider: index < metrics.count - 1
          ) {
            selection = metric.slug
            dismiss()
          }
        }
      }
    }
    .hccCard()
  }
}

private extension String {
  /// File-local: a metric with no unit (a ratio, a count) shows nothing rather
  /// than an empty right-hand column.
  var nilIfBlankUnit: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
