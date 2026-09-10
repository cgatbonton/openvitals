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
  /// The day the tab is showing. Its tile carries the accent wash.
  let selectedDate: String?
  let helper: String
  let onShift: (Int) -> Void
  let onSelectDay: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        HCCLabel("Week of \(HCCTrainingFormat.shortDate(weekStart))")
        Spacer(minLength: 8)
        chip
      }
      // The mockup's `padding-bottom:10px` on the card's label row. Inside a
      // card, so it is not the between-cards rhythm the stack owns.
      .padding(.bottom, 10)

      HStack(spacing: 4) {
        ForEach(days) { day in
          dayTile(day)
        }
      }

      HCCFootnote(helper)
        .padding(.top, 8)
    }
    .hccCard()
  }

  /// `.chip` with the two arrow buttons the mockup puts inside it.
  private var chip: some View {
    HStack(spacing: 5) {
      arrow("‹", delta: -1, isEnabled: weekOffset > 0, label: "Previous week")
      Text(weekOffset == 0 ? "this week" : "next week")
        .font(HCCTheme.Font.data(size: 10, weight: .medium))
        .tracking(0.4)
        .foregroundStyle(HCCTheme.Color.muted)
      arrow("›", delta: 1, isEnabled: weekOffset < 1, label: "Next week")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    // The handoff's chip: a `control2` fill and nothing else. The "Tinted"
    // direction separates by fill, so the old hairline is gone.
    .background(Capsule().fill(HCCTheme.Color.control2))
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
  /// work on it, an accent border on today, an accent wash on the selected day
  /// (the one the card below is showing).
  private func dayTile(_ day: HCCResolvedDay) -> some View {
    let isToday = day.date == todayYmd
    let isSelected = day.date == selectedDate
    let hasWork = day.option != .rest
    let isDone = sessions.contains { $0.dateYmd == day.date && $0.status == .done }

    return Button { onSelectDay(day.date) } label: {
      VStack(spacing: 3) {
        Text(HCCTrainingFormat.shortDow(day.date))
          .font(HCCTheme.Font.data(size: 10, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
        Text(HCCTrainingFormat.dayNumber(day.date))
          .font(HCCTheme.Font.data(size: 10))
          .foregroundStyle(HCCTheme.Color.muted)
        Text(HCCTrainingFormat.stripLabel(day))
          .font(HCCTheme.Font.body(size: 8.5))
          .foregroundStyle(HCCTheme.Color.accentText)
          .lineLimit(1)
          .truncationMode(.tail)
          // A definite width proposal is what keeps the longest tag ("Run club")
          // ellipsised inside the tile instead of running past it.
          .frame(maxWidth: .infinity, minHeight: 9)
          .padding(.horizontal, 2)
      }
      .frame(maxWidth: .infinity)
      // The handoff's tile box: 7 above, 2 at the sides, 10 below.
      .padding(.top, 7)
      .padding(.horizontal, 2)
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
        RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
          .fill(isSelected ? HCCTheme.Color.accent.opacity(0.22) : HCCTheme.Color.card2)
      )
      // The only borders left on this screen, and both are in the handoff: the
      // selected tile and today. Every other hairline is gone — the "Tinted"
      // direction separates by fill.
      .overlay {
        if isSelected || isToday {
          RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
            .strokeBorder(HCCTheme.Color.accent, lineWidth: 1)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityLabel(
      "\(HCCTrainingFormat.longDow(day.date)) \(HCCTrainingFormat.dayNumber(day.date)), \(day.title)"
    )
    .accessibilityHint("Show this day")
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

  /// The handoff's grid, `28 64 1fr 40 22` at gap 8. Fixed widths rather than a
  /// `Grid`, because the header and each row are separate views and only a
  /// shared column table makes them line up.
  private static let columns: (index: CGFloat, weight: CGFloat, reps: CGFloat, box: CGFloat) =
    (28, 64, 40, 22)
  private static let gap: CGFloat = 8

  var body: some View {
    VStack(spacing: 0) {
      header
      ForEach(rows) { row in
        setRow(row)
      }
    }
  }

  private var header: some View {
    HStack(spacing: Self.gap) {
      HCCLabel("Set").frame(width: Self.columns.index, alignment: .leading)
      HCCLabel("Weight").frame(width: Self.columns.weight, alignment: .leading)
      HCCLabel("Plates / side").frame(maxWidth: .infinity, alignment: .leading)
      HCCLabel("Reps").frame(width: Self.columns.reps, alignment: .trailing)
      Color.clear.frame(width: Self.columns.box, height: 1)
    }
    .padding(.bottom, 4)
  }

  /// Each row carries its own top rule, which is what gives the header its
  /// separator too — the handoff's `border-top` on `.setrow`, not a divider
  /// between rows.
  private func setRow(_ row: Row) -> some View {
    let prescribed = row.prescribed
    let logged = row.actualReps != nil
    return VStack(spacing: 0) {
      HCCDivider()
      HStack(spacing: Self.gap) {
        Text(String(prescribed.setIndex))
          .font(HCCTheme.Font.data(size: 11))
          .foregroundStyle(HCCTheme.Color.muted)
          .frame(width: Self.columns.index, alignment: .leading)

        Text("\(HCCFiveThreeOne.formatKg(prescribed.weightKg)) kg")
          .font(HCCTheme.Font.display(size: 14, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(HCCTheme.Color.text)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: Self.columns.weight, alignment: .leading)

        Text(HCCFiveThreeOne.formatPlates(HCCFiveThreeOne.platesPerSide(prescribed.weightKg)))
          .font(HCCTheme.Font.data(size: 10.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(maxWidth: .infinity, alignment: .leading)

        // Muted until the set is logged, primary once it is: the column reads
        // as a checklist rather than as four identical numbers.
        Text(repsText(row))
          .font(HCCTheme.Font.data(size: 12))
          .monospacedDigit()
          .foregroundStyle(logged ? HCCTheme.Color.text : HCCTheme.Color.muted)
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
  }

  /// What was done, when something was; otherwise what is prescribed.
  private func repsText(_ row: Row) -> String {
    if let actual = row.actualReps { return String(actual) }
    return "\(row.prescribed.reps)\(row.prescribed.isAmrap ? "+" : "")"
  }

  private func checkbox(isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      // The shared box at the handoff's set-row size, so a set and a dose can
      // never drift into two different checkboxes.
      HCCCheckbox(isOn: isOn, size: 20, radius: 6)
        .contentShape(Rectangle())
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
    // The handoff's AMRAP line: a plain row under the set table, not a boxed
    // sub-card. The stepper and the Log button are unchanged — only the box,
    // its hairline and the type moved.
    HStack(spacing: 8) {
      Text("AMRAP reps")
        .font(HCCTheme.Font.body(size: 11))
        .foregroundStyle(HCCTheme.Color.muted)

      stepButton("−", delta: -1, isEnabled: isEnabled && reps > 0, label: "One fewer rep")
      Text(String(reps))
        .font(HCCTheme.Font.display(size: 16, weight: .semibold))
        .monospacedDigit()
        .frame(minWidth: 22)
        .foregroundStyle(HCCTheme.Color.text)
      stepButton("+", delta: 1, isEnabled: isEnabled && reps < 100, label: "One more rep")

      Text("e1RM \(HCCFiveThreeOne.formatKg(HCCFiveThreeOne.epleyE1rm(weightKg: weightKg, reps: reps))) kg")
        .font(HCCTheme.Font.data(size: 10.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .trailing)

      Button(action: onLog) {
        Text(loggedReps == reps ? "Logged" : "Log")
          .font(HCCTheme.Font.body(size: 10.5, weight: .semibold))
          .tracking(0.84)
          .textCase(.uppercase)
          .foregroundStyle(HCCTheme.Color.ctaText)
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HCCTheme.Color.ctaGradient)
          )
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled || loggedReps == reps)
      .opacity(isEnabled && loggedReps != reps ? 1 : 0.45)
    }
    .padding(.top, 10)
  }

  private func stepButton(_ glyph: String, delta: Int, isEnabled: Bool, label: String) -> some View {
    Button { onStep(delta) } label: {
      Text(glyph)
        .font(.system(size: 14))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HCCTheme.Color.control2)
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
            .font(HCCTheme.Font.display(size: 17, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(HCCTheme.Color.text)
          Text(
            "Training max \(HCCFiveThreeOne.formatKg(trainingMaxKg)) kg · week \(week) · "
              + HCCFiveThreeOne.weekLabel(week)
          )
          .font(HCCTheme.Font.data(size: 10.5))
          .foregroundStyle(HCCTheme.Color.muted)
        }
        Spacer(minLength: 8)
        HCCPill(pillText, tone: isPreview ? .muted : .accent)
      }
      .padding(.bottom, 10)

      HCCTrainingSetTable(rows: rows, isEnabled: isEnabled, onToggle: onToggle)

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
              .font(HCCTheme.Font.display(size: 17, weight: .semibold))
              .tracking(-0.3)
              .foregroundStyle(HCCTheme.Color.text)
            if isOptional { HCCPill("optional", tone: .muted) }
          }
          Text(subtitle)
            .font(HCCTheme.Font.data(size: 10.5))
            .foregroundStyle(HCCTheme.Color.muted)
        }
        Spacer(minLength: 8)
        HCCPill(pillText, tone: isPreview ? .muted : .accent)
      }

      if let onMark {
        HCCButtonRow(
          primary: onStartLive.map {
            HCCButtonSpec(
              title: "Start live activity",
              isEnabled: isEnabled,
              systemImage: "play.fill",
              action: $0
            )
          },
          secondary: HCCButtonSpec(title: isDone ? "Undo" : "Mark done", isEnabled: isEnabled, action: onMark)
        )
        .padding(.top, 10)
      }
    }
    // The card that belongs to the day's conditioning work carries the sleep
    // tint, the handoff's "a card that belongs to a metric wears its colour".
    .hccCard(tint: HCCTheme.Color.sleep)
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
/// These controls are one to three EQUAL-weight actions, which is why they use
/// `HCCButtonRow`'s `.utility` style: in that style the row's two slots render
/// identically (`control` fill, radius 12, uppercase 11 pt), so nothing here
/// promotes an arbitrary control to the accent CTA. The slots are filled
/// secondary-first because that is the order `HCCButtonRow` lays them out in,
/// which keeps `weekControls`' order on screen.
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
        HCCButtonRow(
          primary: row.count > 1 ? specs[row[1]] : nil,
          secondary: specs[row[0]],
          style: .utility
        )
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
}

