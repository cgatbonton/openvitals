import SwiftUI

/// The full insight, opened by tapping one of the Health landing's "Active
/// insights" rows.
///
/// That row shows the title and a two-line crop of the summary, which is enough
/// to know a card exists and not enough to act on it. This presents the whole
/// card — narrative, the plan, and the reasoning behind it — by reusing
/// `HCCInsightPanel`, the same renderer the Insights screen uses. Nothing here
/// re-words or re-grades the card: every string is the server's.
struct HCCInsightDetailSheet: View {
  let card: HCCInsightCard

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HCCScreen {
      // The panel carries the card's own title, so the header names the SHELF
      // the card came from rather than repeating it.
      HCCDetailHeader(
        title: "Active insight",
        subtitle: subtitle,
        showsBack: false,
        actionTitle: "Close",
        action: { dismiss() }
      )

      // Already unfolded: the tap asked for the full card, so making the
      // reasoning cost one more tap would only half-answer it.
      HCCInsightPanel(card: card, initiallyExpanded: true)

      HCCFootnote("Informational only — not medical advice.")
    }
  }

  /// "Risk · HIGH" — the two things that decide how urgently the card reads,
  /// promoted into the header because the panel's badges scroll away.
  private var subtitle: String {
    [HCCInsightPanel.kindLabel(card.kind), card.severity]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }
}
