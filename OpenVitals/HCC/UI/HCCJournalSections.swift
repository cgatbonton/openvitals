import SwiftUI

// HCC: the Journal tab's rows. Presentation only — every string these views
// draw arrives already formatted, the same rule `HCCComponents` and
// `HCCHomeSections` follow, so there is exactly one place (the screen) where a
// server number becomes text and exactly one place a missing one becomes "--".

// ── Behaviors ────────────────────────────────────────────────────────────────

/// How a yes/no behavior stands today.
///
/// Three states, not two. "Unanswered" and "no" both draw the switch off, and
/// conflating them is the bug this enum exists to prevent: the server deletes a
/// cleared entry precisely so an unanswered day is not counted as a "no" in the
/// impact maths, and a row that looked answered would quietly disagree with it.
enum HCCBehaviorAnswer: Equatable {
  case unanswered
  case yes
  case no

  var isYes: Bool { self == .yes }
  var isAnswered: Bool { self != .unanswered }
}

/// `.toggle` — a behavior's label and its switch.
///
/// Tapping cycles yes → no → yes; a long press on an answered row clears it
/// back to unanswered, which is the only way to take an answer back.
struct HCCBehaviorToggleRow: View {
  let label: String
  let answer: HCCBehaviorAnswer
  var showsDivider: Bool = true
  let onTap: () -> Void
  let onClear: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(label)
          .font(HCCTheme.Font.body(size: 13))
          // Muted until answered: the switch alone cannot say "no answer yet".
          .foregroundStyle(answer.isAnswered ? HCCTheme.Color.text : HCCTheme.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        HCCSwitch(isOn: .constant(answer.isYes))
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
      HStack(spacing: 10) {
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
        HCCStepper(
          value: Binding(get: { value }, set: onChange),
          range: range,
          suffix: unit
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
      HStack(spacing: 10) {
        box
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

  private var box: some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isTaken ? HCCTheme.Color.accent : Color.clear)
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(isTaken ? HCCTheme.Color.accent : HCCTheme.Color.muted, lineWidth: 1.5)
      )
      .overlay {
        if isTaken {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(HCCTheme.Color.bg)
        }
      }
      .frame(width: 20, height: 20)
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
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
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
            .font(HCCTheme.Font.data(size: 12.5))
            .monospacedDigit()
            .foregroundStyle(deltaColor(row))
            .gridColumnAlignment(.trailing)
          Text(row.counts)
            .font(HCCTheme.Font.data(size: 10.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func deltaColor(_ row: HCCImpactGridRow) -> Color {
    guard let isImprovement = row.isImprovement else { return HCCTheme.Color.muted }
    return isImprovement ? HCCTheme.Color.good : HCCTheme.Color.warn
  }
}
