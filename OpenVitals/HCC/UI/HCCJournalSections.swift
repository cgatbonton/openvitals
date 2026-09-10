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

/// A numeric behavior: a stepper in the behavior's own unit.
///
/// Zero is a real answer ("no drinks"), so it is not used to mean "not logged".
/// The row says which it is in words instead, and a long press clears it.
struct HCCBehaviorNumberRow: View {
  let label: String
  let unit: String
  let value: Int
  let isAnswered: Bool
  var range: ClosedRange<Int> = 0...50
  var showsDivider: Bool = true
  let onChange: (Int) -> Void
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
        HCCBehaviorCountStepper(
          value: value,
          unit: unit,
          range: range,
          onChange: onChange
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

/// The count column of a numeric behavior: two 26-pt controls around the number
/// itself, sized and coloured to sit in the same column as the yes/no pill.
///
/// Private rather than `HCCStepper` (the sheets' stepper) for two reasons the
/// handoff is explicit about: the count reads MUTED mono here, not accent — it
/// is an answer, not a control's current setting — and the buttons carry a fill
/// with no hairline, which is the "Tinted" rule for every control on these
/// screens. Behaviour is `HCCStepper`'s, unchanged: ±1, clamped to `range`, and
/// the same `onChange` a tap on the sheet's stepper makes.
private struct HCCBehaviorCountStepper: View {
  let value: Int
  let unit: String
  let range: ClosedRange<Int>
  let onChange: (Int) -> Void

  var body: some View {
    HStack(spacing: 8) {
      button("minus", enabled: value - 1 >= range.lowerBound) {
        onChange(max(range.lowerBound, value - 1))
      }
      Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
        .font(HCCTheme.Font.data(size: 11))
        .monospacedDigit()
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
        .frame(minWidth: 40, alignment: .trailing)
      button("plus", enabled: value + 1 <= range.upperBound) {
        onChange(min(range.upperBound, value + 1))
      }
    }
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
