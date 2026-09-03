import SwiftUI

// HCC: the Training tab's building blocks — the week strip, the set table, the
// AMRAP bar, the day cards, the progression card and the wave controls.
//
// Same rule as `HCCComponents`: nothing here decides a number. Every weight,
// rep count and label is either a value the server sent or a value
// `HCCFiveThreeOne` computed from the server's training maxes; a card that has
// nothing to draw says so rather than filling in a plausible figure.

// ── Formatting ───────────────────────────────────────────────────────────────

/// Day-key → display. These read a civil `YYYY-MM-DD` the server already
/// assigned and format it at UTC, so no value is ever re-bucketed into the
/// device's calendar — the direction the instance-timezone rule guards against
/// is `Date → day key`, which is `HealthDataStore.hccDayKey` and is not used here.
enum HCCTrainingFormat {
  private static func date(_ dayKey: String) -> Date? {
    HCCFiveThreeOne.date(fromDayKey: dayKey)
  }

  private static func formatter(_ template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  /// "Mon".
  static func shortDow(_ dayKey: String) -> String {
    guard let day = date(dayKey) else { return dayKey }
    return formatter("EEE").string(from: day)
  }

  /// "Monday".
  static func longDow(_ dayKey: String) -> String {
    guard let day = date(dayKey) else { return dayKey }
    return formatter("EEEE").string(from: day)
  }

  /// "Aug 31".
  static func shortDate(_ dayKey: String) -> String {
    guard let day = date(dayKey) else { return dayKey }
    return formatter("MMMd").string(from: day)
  }

  /// The bare day number the strip prints under the weekday.
  static func dayNumber(_ dayKey: String) -> String {
    let parts = dayKey.split(separator: "-")
    guard parts.count == 3, let number = Int(parts[2]) else { return dayKey }
    return String(number)
  }

  /// The strip's third line — the mockup's short workout tag. The conditioning
  /// titles come from `weekTemplate`, not from free text, so a short form per
  /// known title is safe; anything else falls back to its first word.
  static func stripLabel(_ day: HCCResolvedDay) -> String {
    switch day.option {
    case .rest:
      return ""
    case .strength:
      guard !day.lifts.isEmpty else { return "Lift" }
      return day.lifts.count == 1
        ? liftShort(day.lifts[0], long: true)
        : day.lifts.map { liftShort($0, long: false) }.joined(separator: "+")
    case .conditioning:
      switch day.title {
      case "Norwegian 4×4": return "4×4"
      case "CrossFit": return "CF"
      case "Light cardio": return "Z2"
      case "Running": return "Run"
      case "Bouldering": return "Boulder"
      case "Run club": return "Run club"
      default: return String(day.title.split(separator: " ").first ?? "")
      }
    }
  }

  private static func liftShort(_ lift: HCCLiftKey, long: Bool) -> String {
    switch lift {
    case .squat: long ? "Squat" : "Sq"
    case .bench: long ? "Bench" : "Be"
    case .press: long ? "Press" : "Pr"
    case .deadlift: "DL"
    }
  }
}

// ── Week strip ───────────────────────────────────────────────────────────────

/// The mockup's week card: the week label, the ‹ this week / next week › chip,
/// the seven-day strip, and the helper line under it.
///
/// Two positions rather than free paging: the payload carries exactly this week
/// and the next one already resolved, and resolution is a server answer (it
/// depends on stored plan rows and the last week actually trained). A third week
/// would have to be guessed, and a guessed week is a wrong week.
struct HCCTrainingWeekCard: View {
  let weekStart: String
  let todayYmd: String
  let days: [HCCResolvedDay]
  let sessions: [HCCTrainingSession]
  let weekOffset: Int
  let editingDate: String?
  let helper: String
  let onShift: (Int) -> Void
  let onPickDay: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        HCCLabel("Week of \(HCCTrainingFormat.shortDate(weekStart))", size: 11)
        Spacer(minLength: 8)
        chip
      }

      HStack(spacing: 4) {
        ForEach(days) { day in
          dayTile(day)
        }
      }
      .padding(.top, 8)

      HCCFootnote(helper)
        .padding(.top, 6)
    }
    .hccCard()
  }

  /// `.chip` with the two arrow buttons the mockup puts inside it.
  private var chip: some View {
    HStack(spacing: 5) {
      arrow("‹", delta: -1, isEnabled: weekOffset > 0, label: "Previous week")
      Text(weekOffset == 0 ? "this week" : "next week")
        .font(HCCTheme.Font.data(size: 10.5, weight: .medium))
        .tracking(0.42)
        .foregroundStyle(HCCTheme.Color.muted)
      arrow("›", delta: 1, isEnabled: weekOffset < 1, label: "Next week")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .overlay(Capsule().strokeBorder(HCCTheme.Color.line, lineWidth: 1))
  }

  private func arrow(_ glyph: String, delta: Int, isEnabled: Bool, label: String) -> some View {
    Button { onShift(delta) } label: {
      Text(glyph)
        .font(HCCTheme.Font.data(size: 12, weight: .medium))
        .foregroundStyle(isEnabled ? HCCTheme.Color.text : HCCTheme.Color.muted.opacity(0.4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityLabel(label)
  }

  /// `.wk.big span` — weekday, date, short workout tag; a dot when the day has
  /// work on it, an accent border on today, an accent wash while its picker is
  /// open.
  private func dayTile(_ day: HCCResolvedDay) -> some View {
    let isToday = day.date == todayYmd
    let isEditing = day.date == editingDate
    let hasWork = day.option != .rest
    let isDone = sessions.contains { $0.dateYmd == day.date && $0.status == .done }

    return Button { onPickDay(day.date) } label: {
      VStack(spacing: 3) {
        Text(HCCTrainingFormat.shortDow(day.date))
          .font(HCCTheme.Font.data(size: 10, weight: .semibold))
          .foregroundStyle(HCCTheme.Color.text)
        Text(HCCTrainingFormat.dayNumber(day.date))
          .font(HCCTheme.Font.data(size: 10, weight: .semibold))
          .foregroundStyle(isToday ? HCCTheme.Color.text : HCCTheme.Color.muted)
        Text(HCCTrainingFormat.stripLabel(day))
          .font(HCCTheme.Font.data(size: 8.5))
          .foregroundStyle(HCCTheme.Color.accent)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          // A definite width proposal is what lets `minimumScaleFactor` shrink
          // the longest tag ("Run club") instead of letting it run past the tile.
          .frame(maxWidth: .infinity, minHeight: 9)
          .padding(.horizontal, 2)
      }
      .frame(maxWidth: .infinity)
      .padding(.top, 7)
      .padding(.bottom, 10)
      .background(alignment: .bottom) {
        // `.wk span.has::after` — the marker that says the day holds work.
        if hasWork {
          Circle()
            .fill(isDone ? HCCTheme.Color.rec : HCCTheme.Color.accent)
            .frame(width: 4, height: 4)
            .padding(.bottom, 3)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isEditing ? HCCTheme.Color.accent.opacity(0.22) : HCCTheme.Color.card2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(isToday ? HCCTheme.Color.accent : HCCTheme.Color.line, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(HCCTrainingFormat.longDow(day.date)) \(HCCTrainingFormat.dayNumber(day.date)), \(day.title)"
    )
    .accessibilityHint("Change what this day is")
  }
}

// ── Set table ────────────────────────────────────────────────────────────────

/// `.sethead` / `.setrow` — one grid, drawn identically for a logged session and
/// for a preview. `onToggle` is absent on a preview, which is what removes the
/// checkbox column's control (a box that cannot be ticked is not shown).
struct HCCTrainingSetTable: View {
  let rows: [Row]
  var isEnabled: Bool = true
  var onToggle: ((Row) -> Void)?

  struct Row: Identifiable {
    let id: String
    let prescribed: HCCPrescribedSet
    var actualReps: Int?
    /// The stored set behind this row, when there is one.
    var set: HCCTrainingSet?
  }

  private static let columns: (index: CGFloat, weight: CGFloat, reps: CGFloat, box: CGFloat) =
    (24, 56, 40, 22)

  var body: some View {
    VStack(spacing: 0) {
      header
      ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
        setRow(row)
        if offset < rows.count - 1 { HCCDivider() }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      HCCLabel("Set", size: 9.5).frame(width: Self.columns.index, alignment: .leading)
      HCCLabel("Weight", size: 9.5).frame(width: Self.columns.weight, alignment: .leading)
      HCCLabel("Plates / side", size: 9.5).frame(maxWidth: .infinity, alignment: .leading)
      HCCLabel("Reps", size: 9.5).frame(width: Self.columns.reps, alignment: .trailing)
      Color.clear.frame(width: Self.columns.box, height: 1)
    }
    .padding(.vertical, 6)
    .overlay(alignment: .bottom) { HCCDivider() }
  }

  private func setRow(_ row: Row) -> some View {
    let prescribed = row.prescribed
    let logged = row.actualReps != nil
    return HStack(spacing: 6) {
      Text(String(prescribed.setIndex))
        .font(HCCTheme.Font.data(size: 12, weight: .medium))
        .foregroundStyle(HCCTheme.Color.muted)
        .frame(width: Self.columns.index, alignment: .leading)

      Text("\(HCCFiveThreeOne.formatKg(prescribed.weightKg)) kg")
        .font(HCCTheme.Font.data(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: Self.columns.weight, alignment: .leading)

      Text(HCCFiveThreeOne.formatPlates(HCCFiveThreeOne.platesPerSide(prescribed.weightKg)))
        .font(HCCTheme.Font.data(size: 12, weight: .medium))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(repsText(row))
        .font(HCCTheme.Font.data(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(prescribed.isAmrap ? HCCTheme.Color.strain : HCCTheme.Color.text)
        .frame(width: Self.columns.reps, alignment: .trailing)

      if let onToggle {
        checkbox(isOn: logged) { onToggle(row) }
          .frame(width: Self.columns.box)
      } else {
        Color.clear.frame(width: Self.columns.box, height: 1)
      }
    }
    .padding(.vertical, 8)
  }

  /// What was done, when something was; otherwise what is prescribed.
  private func repsText(_ row: Row) -> String {
    if let actual = row.actualReps { return String(actual) }
    return "\(row.prescribed.reps)\(row.prescribed.isAmrap ? "+" : "")"
  }

  private func checkbox(isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isOn ? HCCTheme.Color.accent : Color.clear)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(isOn ? HCCTheme.Color.accent : HCCTheme.Color.muted, lineWidth: 1.5)
        )
        .overlay {
          if isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(HCCTheme.Color.bg)
          }
        }
        .frame(width: 20, height: 20)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityLabel(isOn ? "Un-log this set" : "Log this set")
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
  }
}

// ── AMRAP bar ────────────────────────────────────────────────────────────────

/// `.amrapbar` — the one number in the whole program that gets typed. The
/// stepper edits a draft; "Log" is the only thing that reaches the server, so a
/// mis-tap on − never writes.
struct HCCTrainingAmrapBar: View {
  let weightKg: Double
  let reps: Int
  let loggedReps: Int?
  var isEnabled: Bool = true
  let onStep: (Int) -> Void
  let onLog: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text("AMRAP reps")
        .font(HCCTheme.Font.body(size: 11.5, weight: .medium))
        .foregroundStyle(HCCTheme.Color.text)

      stepButton("−", delta: -1, isEnabled: isEnabled && reps > 0, label: "One fewer rep")
      Text(String(reps))
        .font(HCCTheme.Font.display(size: 18, weight: .medium))
        .monospacedDigit()
        .frame(minWidth: 22)
        .foregroundStyle(HCCTheme.Color.text)
      stepButton("+", delta: 1, isEnabled: isEnabled && reps < 100, label: "One more rep")

      Text("e1RM \(HCCFiveThreeOne.formatKg(HCCFiveThreeOne.epleyE1rm(weightKg: weightKg, reps: reps))) kg")
        .font(HCCTheme.Font.data(size: 11))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .trailing)

      Button(action: onLog) {
        Text(loggedReps == reps ? "Logged" : "Log")
          .font(HCCTheme.Font.body(size: 10.5, weight: .semibold))
          .tracking(0.84)
          .textCase(.uppercase)
          .foregroundStyle(HCCTheme.Color.bg)
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HCCTheme.Color.accent)
          )
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled || loggedReps == reps)
      .opacity(isEnabled && loggedReps != reps ? 1 : 0.45)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HCCTheme.Color.card2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
    )
    .padding(.top, 10)
  }

  private func stepButton(_ glyph: String, delta: Int, isEnabled: Bool, label: String) -> some View {
    Button { onStep(delta) } label: {
      Text(glyph)
        .font(.system(size: 14))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HCCTheme.Color.card)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityLabel(label)
  }
}

// ── Session note ─────────────────────────────────────────────────────────────

/// `.field` — the note row under a started session. Saves when editing ends, the
/// way the web page does; typing does not write.
struct HCCTrainingNoteField: View {
  let placeholder: String
  @Binding var text: String
  var isEnabled: Bool = true
  let onCommit: () -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Text("Note")
        .font(HCCTheme.Font.body(size: 12))
        .foregroundStyle(HCCTheme.Color.muted)
      TextField(placeholder, text: $text, axis: .vertical)
        .font(HCCTheme.Font.data(size: 12.5))
        .foregroundStyle(HCCTheme.Color.accent)
        .multilineTextAlignment(.trailing)
        .lineLimit(1...3)
        .focused($isFocused)
        .disabled(!isEnabled)
        .submitLabel(.done)
        .onSubmit { onCommit() }
    }
    .padding(.top, 8)
    .onChange(of: isFocused) { _, focused in
      if !focused { onCommit() }
    }
  }
}

// ── Day cards ────────────────────────────────────────────────────────────────

/// One lift of a strength day. The same card draws a started lift (checkboxes,
/// AMRAP bar) and an unstarted one (targets only, "Start session"), because they
/// are the same prescription seen at two moments.
struct HCCTrainingLiftCard<Footer: View>: View {
  let lift: HCCLiftKey
  let trainingMaxKg: Double
  let week: Int
  let pillText: String
  let isPreview: Bool
  let rows: [HCCTrainingSetTable.Row]
  var isEnabled: Bool = true
  var onToggle: ((HCCTrainingSetTable.Row) -> Void)?
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(lift.label)
            .font(HCCTheme.Font.display(size: 16, weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
          Text(
            "Training max \(HCCFiveThreeOne.formatKg(trainingMaxKg)) kg · week \(week) · "
              + HCCFiveThreeOne.weekLabel(week)
          )
          .font(HCCTheme.Font.data(size: 11))
          .foregroundStyle(HCCTheme.Color.muted)
        }
        Spacer(minLength: 8)
        HCCPill(pillText, tone: isPreview ? .muted : .accent)
      }

      HCCTrainingSetTable(rows: rows, isEnabled: isEnabled, onToggle: onToggle)
        .padding(.top, 4)

      footer()
    }
    .hccCard()
  }
}

extension HCCTrainingLiftCard where Footer == EmptyView {
  init(
    lift: HCCLiftKey,
    trainingMaxKg: Double,
    week: Int,
    pillText: String,
    isPreview: Bool,
    rows: [HCCTrainingSetTable.Row],
    isEnabled: Bool = true,
    onToggle: ((HCCTrainingSetTable.Row) -> Void)? = nil
  ) {
    self.init(
      lift: lift,
      trainingMaxKg: trainingMaxKg,
      week: week,
      pillText: pillText,
      isPreview: isPreview,
      rows: rows,
      isEnabled: isEnabled,
      onToggle: onToggle,
      footer: { EmptyView() }
    )
  }
}

/// A conditioning day: what it is, what it asks for, and whether it has been
/// logged. "Start live activity" is not rendered — the live screen belongs to a
/// later workstream, and a control that cannot do anything is not shown.
struct HCCTrainingConditioningCard: View {
  let title: String
  let subtitle: String
  let pillText: String
  let isPreview: Bool
  let isDone: Bool
  let isOptional: Bool
  var isEnabled: Bool = true
  /// Absent on a preview day: only the day on screen can be logged.
  var onMark: (() -> Void)?
  /// Rendered only when the live-activity screen exists (see
  /// `HCCTrainingView.liveActivityIsAvailable`).
  var onStartLive: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(title)
              .font(HCCTheme.Font.display(size: 16, weight: .medium))
              .foregroundStyle(HCCTheme.Color.text)
            if isOptional { HCCPill("optional", tone: .muted) }
          }
          Text(subtitle)
            .font(HCCTheme.Font.data(size: 11))
            .foregroundStyle(HCCTheme.Color.muted)
        }
        Spacer(minLength: 8)
        HCCPill(pillText, tone: isPreview ? .muted : .accent)
      }

      if let onMark {
        HCCButtonRow(
          primary: onStartLive.map { HCCButtonSpec(title: "Start live activity", isEnabled: isEnabled, action: $0) },
          secondary: HCCButtonSpec(title: isDone ? "Undo" : "Mark done", isEnabled: isEnabled, action: onMark)
        )
        .padding(.top, 6)
      }
    }
    .hccCard()
  }
}

// ── Progression ──────────────────────────────────────────────────────────────

/// One lift's trajectory. The three numbers and the trend line come entirely
/// from AMRAP sets — the only sets in 5/3/1 that measure rather than prescribe —
/// so a lift with no AMRAP behind it shows "--" and says why, instead of
/// borrowing the training max as a stand-in.
struct HCCTrainingProgressionCard: View {
  let lift: HCCLiftKey
  let trainingMaxKg: Double
  let history: HCCLiftHistory?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCLabel("Progression · \(lift.label)", size: 11)

      HCCStat3(items: [
        HCCStat(value: HCCFiveThreeOne.formatKg(trainingMaxKg), label: "Training max"),
        HCCStat(value: lastAmrapText, label: "Last AMRAP"),
        HCCStat(value: bestText, label: "Best e1RM"),
      ])

      if points.count > 1 {
        HCCSparkline(values: points, color: HCCTheme.Color.strain, height: 40)
          .padding(.bottom, 2)
      }

      HCCFootnote(footnote)
        .padding(.top, 6)
    }
    .hccCard()
  }

  private var points: [Double] { history?.points.map(\.e1rmKg) ?? [] }

  private var lastAmrapText: String {
    guard let amrap = history?.lastAmrap else { return HCCFormat.placeholder }
    return "\(HCCFiveThreeOne.formatKg(amrap.weightKg))×\(amrap.reps)"
  }

  private var bestText: String {
    guard let best = history?.bestE1rmKg else { return HCCFormat.placeholder }
    return HCCFiveThreeOne.formatKg(best)
  }

  private var footnote: String {
    "AMRAP history builds the trend line. Next cycle: TM "
      + "\(HCCFiveThreeOne.formatKg(HCCFiveThreeOne.nextTm(lift, currentKg: trainingMaxKg))) kg."
  }
}

// ── Wave controls ────────────────────────────────────────────────────────────

/// The `.btns` row for the week controls.
///
/// `HCCButtonRow` is the design system's button row and is used everywhere else,
/// but it models exactly one primary and one secondary; these controls are one
/// to three equal-weight actions (the mockup draws "Start next cycle" and "Skip
/// deload" as two plain buttons side by side). Rather than promote an arbitrary
/// one to accent-filled, this lays out the same button the mockup's `.btns
/// button` rule describes, two to a row.
struct HCCTrainingButtons: View {
  let specs: [HCCButtonSpec]

  var body: some View {
    // Indices, not a chunked array of specs: `HCCButtonSpec` carries a closure
    // and is neither Equatable nor Identifiable, and a `ForEach` over
    // re-computed arrays of them dropped the second row outright. The indices
    // are stable and `Self.rows(for:)` is pure, so what is laid out here is
    // exactly what `weekControls` returned.
    // A lone button on the last row fills that row, which is what the mockup's
    // `.btns button{flex:1}` does with a single child.
    VStack(spacing: 8) {
      ForEach(Self.rows(for: specs.count), id: \.self) { row in
        HStack(spacing: 8) {
          ForEach(row, id: \.self) { index in
            button(specs[index])
          }
        }
      }
    }
    .padding(.top, 4)
  }

  /// Button indices, two to a row.
  static func rows(for count: Int) -> [[Int]] {
    var out: [[Int]] = []
    var index = 0
    while index < count {
      out.append(Array(index..<min(index + 2, count)))
      index += 2
    }
    return out
  }

  private func button(_ spec: HCCButtonSpec) -> some View {
    Button(action: spec.action) {
      Text(spec.title)
        .font(HCCTheme.Font.body(size: 11, weight: .semibold))
        .tracking(0.88)
        .textCase(.uppercase)
        .multilineTextAlignment(.center)
        .foregroundStyle(HCCTheme.Color.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HCCTheme.Color.card2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .disabled(!spec.isEnabled)
    .opacity(spec.isEnabled ? 1 : 0.45)
  }
}
