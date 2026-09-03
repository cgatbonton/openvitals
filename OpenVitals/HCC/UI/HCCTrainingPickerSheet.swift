import SwiftUI

// HCC: the day picker — changing what a day IS, as opposed to logging what
// happened on it.
//
// Rendered as an accent-bordered card in the flow rather than a modal, which is
// what the mockup does (`.card.picker`, between the week strip and the day
// body): the strip stays visible above it, so the day being changed and the
// change are on screen together.
//
// The options are `HCCFiveThreeOne.dayOptionCatalog()` — derived from the same
// week template the server derives its own catalog from, so this list can never
// offer a workout the server's `PUT /api/training/plan` would reject as an
// unknown title, and never one the day body cannot render.

struct HCCTrainingPickerCard: View {
  let dayKey: String
  /// What the day currently resolves to, so the active row is marked.
  let current: HCCResolvedDay?
  var isEnabled: Bool = true
  let onPick: (HCCDayChoice) -> Void
  let onClose: () -> Void

  private var choices: [HCCDayChoice] { HCCFiveThreeOne.dayOptionCatalog() }

  /// The catalog key the resolved day corresponds to.
  private var currentKey: String? {
    guard let current else { return nil }
    switch current.option {
    case .strength: return "STRENGTH:\(current.lifts.map(\.rawValue).joined(separator: "+"))"
    case .conditioning: return "CONDITIONING:\(current.title)"
    case .rest: return "REST"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        HCCLabel(
          "\(HCCTrainingFormat.shortDow(dayKey)) \(HCCTrainingFormat.dayNumber(dayKey)) · workout",
          size: 11
        )
        Spacer(minLength: 8)
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
            .frame(width: 26, height: 26)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous).fill(HCCTheme.Color.card2)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close the workout picker")
      }
      .padding(.bottom, 8)

      VStack(spacing: 0) {
        ForEach(Array(choices.enumerated()), id: \.element.key) { offset, choice in
          row(choice, showsDivider: offset < choices.count - 1)
        }
      }

      HCCFootnote(
        "Strength days regenerate their sets from the training max. "
          + "Next week inherits this day's choice."
      )
      .padding(.top, 8)
    }
    .hccCard()
    .overlay(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
        .strokeBorder(HCCTheme.Color.accent, lineWidth: 1)
    )
  }

  /// `.menu .it` with a `.radio` on the right — the same row shape the rest of
  /// the app's settings lists use, with a radio instead of a value.
  private func row(_ choice: HCCDayChoice, showsDivider: Bool) -> some View {
    let isActive = choice.key == currentKey
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(choice.title)
            .font(HCCTheme.Font.body(size: 13.5))
            .foregroundStyle(HCCTheme.Color.text)
          if let subtitle = choice.subtitle, !subtitle.isEmpty {
            Text(subtitle)
              .font(HCCTheme.Font.data(size: 10.5))
              .foregroundStyle(HCCTheme.Color.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        radio(isActive: isActive)
      }
      .padding(.vertical, 11)
      .contentShape(Rectangle())
      .onTapGesture { if isEnabled { onPick(choice) } }
      if showsDivider { HCCDivider() }
    }
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
  }

  /// `.radio` / `.radio.on` — the selected state is an accent core inside a
  /// background-coloured ring inside the accent border, which is what the
  /// mockup's `box-shadow: 0 0 0 4px var(--bg) inset` draws.
  private func radio(isActive: Bool) -> some View {
    Circle()
      .fill(isActive ? HCCTheme.Color.accent : Color.clear)
      .overlay {
        if isActive { Circle().strokeBorder(HCCTheme.Color.bg, lineWidth: 4) }
      }
      .overlay(
        Circle().strokeBorder(isActive ? HCCTheme.Color.accent : HCCTheme.Color.muted, lineWidth: 1.5)
      )
      .frame(width: 18, height: 18)
  }
}
