import SwiftUI

// HCC: the Journal tab's rows. Presentation only — every string these views
// draw arrives already formatted, the same rule `HCCComponents` and
// `HCCHomeSections` follow, so there is exactly one place (the screen) where a
// server number becomes text and exactly one place a missing one becomes "--".

// ── Behaviors ────────────────────────────────────────────────────────────────

/// How a yes/no behavior stands today.
///
/// Three states, not two. Conflating "unanswered" with "no" is the bug this
/// enum exists to prevent: the server deletes a cleared entry precisely so an
/// unanswered day is not counted as a "no" in the impact maths, and a row that
/// looked answered would quietly disagree with it. Each state has its own
/// rendering in `HCCBehaviorAnswerPill` — "Yes", "No", and a dash — so the
/// distinction survives on screen and not only in this type.
enum HCCBehaviorAnswer: Equatable {
  case unanswered
  case yes
  case no

  var isYes: Bool { self == .yes }
  var isAnswered: Bool { self != .unanswered }
}

/// `.toggle` — a behavior's label and the pill that says how it stands.
///
/// Tapping cycles yes → no → yes; a long press on an answered row clears it
/// back to unanswered, which is the only way to take an answer back.
///
/// The answer is a PILL rather than a switch (handoff mock `3c`), because a
/// two-position switch has nowhere to put the third state: an unanswered row
/// drew off, exactly as a "no" did, and the muted label was the only thing
/// telling them apart. The pill prints the answer — "Yes", "No", or a dash in
/// the chevron colour with no ground at all — so the three states are three
/// renderings. The label stays muted until answered as well; both say it.
struct HCCBehaviorToggleRow: View {
  let label: String
  let answer: HCCBehaviorAnswer
  var showsDivider: Bool = true
  let onTap: () -> Void
  let onClear: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(label)
          .font(HCCTheme.Font.body(size: 13))
          // Muted until answered: the pill's dash is the other half of the same
          // statement, and a normal label beside it would half-contradict it.
          .foregroundStyle(answer.isAnswered ? HCCTheme.Color.text : HCCTheme.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        HCCBehaviorAnswerPill(answer: answer)
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .onLongPressGesture { if answer.isAnswered { onClear() } }
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Clear answer") { if answer.isAnswered { onClear() } }
  }

  private var accessibilityValue: String {
    switch answer {
    case .unanswered: "Not answered"
    case .yes: "Yes"
    case .no: "No"
    }
  }
}

/// The handoff's answer pill: `Yes` on a recovery-tinted ground, `No` on plain
/// white 8 %, and an em dash for unanswered on NO ground at all.
///
/// Private to the Journal: it is not `HCCPill`. That component is a status word
/// at 9.5 pt with the tone palette; this is a 40-pt-wide answer column at 11 pt
/// whose "no" is deliberately colourless — a "no" is an answer, not a warning,
/// and tinting it red would grade a behavior the app does not grade.
private struct HCCBehaviorAnswerPill: View {
  let answer: HCCBehaviorAnswer

  var body: some View {
    Text(text)
      .font(HCCTheme.Font.data(size: 11, weight: .medium))
      .foregroundStyle(foreground)
      .multilineTextAlignment(.center)
      .frame(minWidth: 40)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Capsule().fill(background))
  }

  private var text: String {
    switch answer {
    case .unanswered: "\u{2014}"
    case .yes: "Yes"
    case .no: "No"
    }
  }

  private var foreground: Color {
    switch answer {
    case .unanswered: HCCTheme.Color.chevron
    case .yes: HCCTheme.Color.recoveryText
    case .no: HCCTheme.Color.text
    }
  }

  private var background: Color {
    switch answer {
    // No ground for an unanswered row: a pill outline there would look like a
    // control that had been set to something.
    case .unanswered: .clear
    case .yes: HCCTheme.Color.recovery.opacity(0.18)
    case .no: HCCTheme.Color.white(0.08)
    }
  }
}

/// A numeric behavior: a typed field in the behavior's own unit, with a step
/// button either side of it.
///
/// Zero is a real answer ("no drinks"), so it is not used to mean "not logged".
/// The row says which it is in words instead. TWO things clear an answer now: a
/// long press on the row, and emptying the field — a blank that saved 0 would
/// manufacture an answer the owner never gave, which is the same mistake
/// "Unanswered Is Not No" forbids on the yes/no side.
///
/// The number arrives ALREADY FORMATTED as `valueText`, and the typed string
/// goes back out raw, so every Double-to-String conversion stays on the screen
/// (see the note at the top of this file). `value` is here only so the step
/// buttons have something to enable themselves against.
struct HCCBehaviorNumberRow: View {
  /// The clamp both the steppers and a typed number are held to. Wide on
  /// purpose: the ferment ladder's own ceiling was removed 2026-09-11 and 3
  /// cups is already 48 tbsp, so a tight cap here would silently eat a real
  /// answer the moment that rung advanced.
  static let range: ClosedRange<Double> = 0...999

  let label: String
  let unit: String
  let valueText: String
  let value: Double
  let isAnswered: Bool
  var showsDivider: Bool = true
  let fieldId: String
  let focused: FocusState<String?>.Binding
  /// What is typed right now, plus the ±1 the tap asks for. Both travel
  /// together so the screen can step from the number ON SCREEN rather than from
  /// a server value a half-finished edit has already moved past.
  let onStep: (String, Double) -> Void
  /// The raw typed string, on blur. The screen answers whether it took it;
  /// `false` snaps the field back to `valueText`.
  let onCommit: (String) -> Bool
  let onClear: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(label)
            .font(HCCTheme.Font.body(size: 13))
            .foregroundStyle(isAnswered ? HCCTheme.Color.text : HCCTheme.Color.muted)
            .fixedSize(horizontal: false, vertical: true)
          if !isAnswered {
            Text("Not logged")
              .font(HCCTheme.Font.data(size: 10.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
        Spacer(minLength: 8)
        HCCBehaviorCountField(
          valueText: valueText,
          value: value,
          unit: unit,
          fieldId: fieldId,
          focused: focused,
          onStep: onStep,
          onCommit: onCommit
        )
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onLongPressGesture { if isAnswered { onClear() } }
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Clear answer") { if isAnswered { onClear() } }
  }
}

/// The count column of a numeric behavior: a typed field with a 26-pt step
/// button either side, sized and coloured to sit in the same column as the
/// yes/no pill.
///
/// Private rather than `HCCStepper` (the sheets' stepper) for two reasons the
/// handoff is explicit about: the count reads MUTED mono here, not accent — it
/// is an answer, not a control's current setting — and the controls carry a
/// fill with no hairline, which is the "Tinted" rule for every control on these
/// screens. The field takes that same fill now that the number is itself a
/// control, and tints only WHILE it is being edited, which is a state rather
/// than a resting style, so the muted rule still holds.
///
/// The field accepts DECIMALS (Chris, 2026-09-21). A waist in inches, a dose in
/// millilitres or half a cup of kraut is not a whole number, and ±1 cannot
/// reach one; before this the row also rounded whatever the server held to the
/// nearest integer and wrote that back on the next tap, so a 34.5 could not
/// survive being looked at.
///
/// Typing does not write. The value is committed when editing ENDS, the way
/// `HCCTrainingNoteField` and the web page both do, so a half-typed "3" on the
/// way to "3.5" never reaches the server.
private struct HCCBehaviorCountField: View {
  let valueText: String
  let value: Double
  let unit: String
  let fieldId: String
  let focused: FocusState<String?>.Binding
  let onStep: (String, Double) -> Void
  let onCommit: (String) -> Bool

  @State private var draft: String = ""
  /// Set for the one blur a step button causes: the tap has already handed the
  /// draft to the screen, so committing it again on the way out would write the
  /// same edit twice — once stepped, once not.
  @State private var stepIsHandlingBlur = false

  private var isEditing: Bool { focused.wrappedValue == fieldId }

  var body: some View {
    HStack(spacing: 8) {
      button("minus", enabled: value - 1 >= HCCBehaviorNumberRow.range.lowerBound) { step(-1) }
      HStack(spacing: 3) {
        // The em dash placeholder is this app's "no finding yet". An unanswered
        // count must not sit here reading 0, which is a real answer.
        TextField("\u{2014}", text: $draft)
          .font(HCCTheme.Font.data(size: 11))
          .monospacedDigit()
          .foregroundStyle(isEditing ? HCCTheme.Color.accentText : HCCTheme.Color.muted)
          .multilineTextAlignment(.trailing)
          .keyboardType(.decimalPad)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .focused(focused, equals: fieldId)
          .frame(width: 40)
          .accessibilityLabel("Count")
        if !unit.isEmpty {
          Text(unit)
            .font(HCCTheme.Font.data(size: 11))
            .foregroundStyle(HCCTheme.Color.muted)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
          .fill(HCCTheme.Color.control2)
      )
      .contentShape(Rectangle())
      // The unit sits OUTSIDE the field so the typed text parses cleanly, which
      // would leave it a dead spot — this makes the whole pill open the keypad.
      .onTapGesture { focused.wrappedValue = fieldId }
      button("plus", enabled: value + 1 <= HCCBehaviorNumberRow.range.upperBound) { step(1) }
    }
    .onAppear { draft = valueText }
    // The server's own value wins whenever the field is not being edited, so a
    // reconcile or a rolled-back write still reaches the screen.
    .onChange(of: valueText) { _, text in
      if !isEditing { draft = text }
    }
    .onChange(of: focused.wrappedValue) { previous, current in
      guard previous == fieldId, current != fieldId else { return }
      if stepIsHandlingBlur {
        stepIsHandlingBlur = false
        return
      }
      if !onCommit(draft) { draft = valueText }
    }
  }

  /// A step tap while the keypad is open carries the draft with it, so the
  /// typed number is what gets stepped and the blur that follows stays quiet.
  private func step(_ delta: Double) {
    if isEditing {
      stepIsHandlingBlur = true
      focused.wrappedValue = nil
    }
    onStep(draft, delta)
  }

  private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: HCCTheme.Radius.small, style: .continuous)
            .fill(HCCTheme.Color.control2)
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.4)
    .accessibilityLabel(symbol == "minus" ? "Decrease" : "Increase")
  }
}

// ── Doses ────────────────────────────────────────────────────────────────────

/// `.check` — one due dose: its box, the protocol it belongs to, the product it
/// draws, and the dose itself on the right.
///
/// The dose text is the server's, verbatim. `count` is present only when a day
/// owes more than one of this line, because "1/1" on every row is noise.
struct HCCDoseCheckRow: View {
  let title: String
  let subtitle: String?
  let doseText: String
  let count: String?
  let note: String?
  let isTaken: Bool
  var showsDivider: Bool = true
  let onTap: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        // The shared 22/7 box, so a dose row and a Training set row can never
        // drift into two different checkboxes.
        HCCCheckbox(isOn: isTaken, size: 22, radius: 7)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(HCCTheme.Font.body(size: 13))
            .foregroundStyle(HCCTheme.Color.text)
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle {
            Text(subtitle)
              .font(HCCTheme.Font.body(size: 11.5))
              .foregroundStyle(HCCTheme.Color.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let note {
            Text(note)
              .font(HCCTheme.Font.data(size: 10.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 2) {
          Text(doseText)
            .font(HCCTheme.Font.data(size: 11))
            .foregroundStyle(HCCTheme.Color.muted)
          if let count {
            Text(count)
              .font(HCCTheme.Font.data(size: 10.5))
              .monospacedDigit()
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    .accessibilityValue(isTaken ? "Taken, \(doseText)" : "Not taken, \(doseText)")
    .accessibilityAddTraits(isTaken ? [.isButton, .isSelected] : .isButton)
  }
}

// ── Impacts ──────────────────────────────────────────────────────────────────

/// One row of the impact grid, already reduced to three strings.
///
/// `delta` is nil for a row that has not met the server's day gate — the grid
/// draws an em dash there rather than a number, because "no finding yet" and
/// "no effect" are different answers.
struct HCCImpactGridRow: Identifiable {
  let id: String
  let label: String
  let delta: String?
  let isImprovement: Bool?
  let counts: String
}

/// `.imp` — label, delta, sample size. One grid so the three columns line up
/// across every row.
struct HCCImpactGrid: View {
  let rows: [HCCImpactGridRow]

  var body: some View {
    // The mockup's `gap:10` between the columns; the 12 between rows is its
    // `padding:6px 0` on each row, expressed as the grid's own spacing rather
    // than as padding on a row that would then stack with it.
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
      ForEach(rows) { row in
        GridRow {
          Text(row.label)
            .font(HCCTheme.Font.body(size: 12.5))
            .foregroundStyle(row.delta == nil ? HCCTheme.Color.muted : HCCTheme.Color.text)
            .fixedSize(horizontal: false, vertical: true)
            // The mockup's `1fr auto auto`: the label takes the slack so the
            // delta and the sample size stay pinned to the right edge.
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(row.delta ?? "—")
            .font(HCCTheme.Font.display(size: 15, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(deltaColor(row))
            .gridColumnAlignment(.trailing)
          Text(row.counts)
            .font(HCCTheme.Font.data(size: 10))
            .foregroundStyle(HCCTheme.Color.muted)
            .frame(minWidth: 44, alignment: .trailing)
            .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  /// Good green, watch amber, and the chevron grey for a row with no finding —
  /// the dash is furniture, not a reading, so it takes the dimmest of the three.
  private func deltaColor(_ row: HCCImpactGridRow) -> Color {
    guard let isImprovement = row.isImprovement else { return HCCTheme.Color.chevron }
    return isImprovement ? HCCTheme.Color.good : HCCTheme.Color.warn
  }
}
