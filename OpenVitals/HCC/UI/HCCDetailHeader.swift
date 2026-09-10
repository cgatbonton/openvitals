import SwiftUI

/// `.hdr` — the header bar every detail and Health page opens with.
///
/// These screens hide the system navigation bar (see `HCCScreen`), so this is
/// the only back affordance. The handoff's numbers: a 34×34 control-fill back
/// square with a `chevron.left`, a 26-pt Outfit 600 title (24 on a sub-page)
/// over a Plex Mono uppercase subtitle, gap 4.
///
/// `trailing` is a view slot rather than a title/action pair so a screen can put
/// its own control there — Journal's day-nav pill, Home-like screens a refresh
/// button — without a second header type. `actionTitle`/`action` remain for the
/// screens that just want a labelled pill.
struct HCCDetailHeader<Trailing: View>: View {
  let title: String
  var subtitle: String?
  /// The handoff's two title scales: 26 for a tab root, 24 for a sub-page.
  var size: CGFloat = 26
  /// A tab root has nothing to go back to, so Health passes `false`.
  var showsBack: Bool = true
  /// `.act` — a label and what it does. Absent on most screens.
  var actionTitle: String?
  var action: (() -> Void)?
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    subtitle: String? = nil,
    size: CGFloat = 26,
    showsBack: Bool = true,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.size = size
    self.showsBack = showsBack
    self.actionTitle = actionTitle
    self.action = action
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      if showsBack { backButton }

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(HCCTheme.Font.display(size: size, weight: .semibold))
          .tracking(-0.6)
          .foregroundStyle(HCCTheme.Color.text)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(HCCTheme.Font.data(size: 10.5))
            // The handoff allows +0.4–0.6; the low end, because the subtitle is
            // ONE line in every mock and Biomarkers' ("LAST PANEL … · GRADED VS
            // OPTIMAL TARGETS") only fits beside the back button at 0.4. A
            // longer string shrinks a little rather than wrapping.
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(HCCTheme.Color.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
      }

      Spacer(minLength: 8)

      if let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(HCCTheme.Font.body(size: 11, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(control(radius: HCCTheme.Radius.control))
        }
        .buttonStyle(.plain)
      }

      trailing()
    }
    // The remainder of the mockup's `.hdr{margin-bottom:12px}`, minus the 10 its
    // container already supplies. Every stack that holds a header uses
    // spacing 10 — see "Card Spacing Is Stack Spacing".
    .padding(.bottom, 2)
  }

  private var backButton: some View {
    Button { dismiss() } label: {
      Image(systemName: "chevron.left")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 34, height: 34)
        .background(control(radius: HCCTheme.Radius.control))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Back")
  }

  /// No border: the "Tinted" direction's controls are a fill and nothing else.
  private func control(radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(HCCTheme.Color.control)
  }
}

extension HCCDetailHeader where Trailing == EmptyView {
  init(
    title: String,
    subtitle: String? = nil,
    size: CGFloat = 26,
    showsBack: Bool = true,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      size: size,
      showsBack: showsBack,
      actionTitle: actionTitle,
      action: action
    ) { EmptyView() }
  }
}
