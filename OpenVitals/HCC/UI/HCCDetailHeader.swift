import SwiftUI

/// `.hdr` — the header bar every detail and Health page opens with.
///
/// These screens hide the system navigation bar (see `HCCScreen`), so this is
/// the only back affordance. The 32-pt glass square, the 20-pt display title and
/// the 11.5-pt muted subtitle are the mockup's; the optional trailing button is
/// its `.act`.
struct HCCDetailHeader: View {
  let title: String
  var subtitle: String?
  /// A tab root has nothing to go back to, so Health passes `false`.
  var showsBack: Bool = true
  /// `.act` — a label and what it does. Absent on most screens.
  var actionTitle: String?
  var action: (() -> Void)?

  @Environment(\.dismiss) private var dismiss

  init(
    title: String,
    subtitle: String? = nil,
    showsBack: Bool = true,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.subtitle = subtitle
    self.showsBack = showsBack
    self.actionTitle = actionTitle
    self.action = action
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      if showsBack { backButton }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(HCCTheme.Font.display(size: 20, weight: .medium))
          .tracking(-0.4)
          .foregroundStyle(HCCTheme.Color.text)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(HCCTheme.Font.body(size: 11.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 8)

      if let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(HCCTheme.Font.body(size: 11, weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(glass(radius: 10))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.bottom, 12)
  }

  private var backButton: some View {
    Button { dismiss() } label: {
      Text("‹")
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 32, height: 32)
        .background(glass(radius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Back")
  }

  private func glass(radius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return shape
      .fill(HCCTheme.Color.card)
      .overlay(shape.strokeBorder(HCCTheme.Color.line, lineWidth: 1))
  }
}
