import SwiftUI

// HCC: the day picker — changing what a day IS, as opposed to logging what
// happened on it.
//
// REBUILT 2026-09-03 (Chris: "instead of this huge workout selection radio
// button card, let's keep it as a one-row dropdown with the selected workout").
// It used to be a full card of radio rows, one per catalog option, which on a
// phone was taller than the week strip it sat under. It is now ONE row: the day
// on the left, the workout that day currently resolves to on the right, and the
// catalog behind a menu on that value.
//
// It stays an accent-bordered card in the flow rather than a modal, which is
// what the mockup does (`.card.picker`, between the week strip and the day
// body): the strip stays visible above it, so the day being changed and the
// change are on screen together. Tapping the same day in the strip again closes
// it, which is why there is no X.
//
// The options are `HCCFiveThreeOne.dayOptionCatalog()` — derived from the same
// week template the server derives its own catalog from, so this list can never
// offer a workout the server's `PUT /api/training/plan` would reject as an
// unknown title, and never one the day body cannot render.

struct HCCTrainingPickerCard: View {
  let dayKey: String
  /// What the day currently resolves to. This is the server's resolution —
  /// an explicit pick if there is one, otherwise the same weekday of the most
  /// recent earlier week that has anything, otherwise the week template — so
  /// the value shown here IS the day's default, not a placeholder.
  let current: HCCResolvedDay?
  var isEnabled: Bool = true
  let onPick: (HCCDayChoice) -> Void

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

  /// The day's OWN title wins over the catalog's. An inherited day can carry a
  /// title the catalog no longer lists, and showing the day as it actually is
  /// beats showing nothing or the wrong option marked.
  private var selectedTitle: String {
    if let title = current?.title, !title.isEmpty { return title }
    if let key = currentKey, let choice = choices.first(where: { $0.key == key }) { return choice.title }
    return "Choose"
  }

  /// Where the shown value came from. Worth saying: "Deadlift + Press" reads
  /// the same whether the owner picked it or it was carried over, and only one
  /// of those is a decision they made.
  private var sourceNote: String {
    switch current?.source {
    case .user: "Picked for this day."
    case .inherited: "Carried over from this weekday last week."
    case .template: "From the week template."
    case .restDefault: "No workout on this weekday to carry over."
    case nil: ""
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        HCCLabel(
          "\(HCCTrainingFormat.shortDow(dayKey)) \(HCCTrainingFormat.dayNumber(dayKey)) · workout",
          size: 11
        )
        Spacer(minLength: 8)
        menu
      }

      if !sourceNote.isEmpty {
        HCCFootnote(sourceNote + " Strength days regenerate their sets from the training max.")
      }
    }
    .hccCard()
    .overlay(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
        .strokeBorder(HCCTheme.Color.accent, lineWidth: 1)
    )
    .opacity(isEnabled ? 1 : 0.5)
  }

  private var menu: some View {
    Menu {
      // `Picker` is not used here on purpose: a day can resolve to a title the
      // catalog does not list, and a Picker with a selection outside its own
      // options renders blank. A menu of buttons always shows the real value.
      ForEach(choices) { choice in
        Button {
          onPick(choice)
        } label: {
          if choice.key == currentKey {
            Label(choice.title, systemImage: "checkmark")
          } else {
            Text(choice.title)
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Text(selectedTitle)
          .font(HCCTheme.Font.body(size: 13.5, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HCCTheme.Color.card2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .disabled(!isEnabled)
    .accessibilityLabel("Workout for \(HCCTrainingFormat.shortDow(dayKey)) \(HCCTrainingFormat.dayNumber(dayKey))")
    .accessibilityValue(selectedTitle)
  }
}
