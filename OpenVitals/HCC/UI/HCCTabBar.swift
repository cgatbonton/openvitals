import SwiftUI

/// The floating pill tab bar: 22-pt SF Symbols over 10-pt labels, muted until
/// selected, accent when selected, on `rgba(20,26,40,.92)` with a 24-pt radius.
///
/// It FLOATS — inset 16 from each side, 22 above the bottom safe-area edge —
/// and the content scrolls beneath it. Nothing here is full-bleed and there is
/// no hairline rule: a screen's last card clears the bar because its scroll view
/// leaves `HCCTheme.Spacing.tabBarClearance` below the content, not because the
/// bar occupies layout space.
///
/// All five of the mockup's tabs are here from the start — Home · Health ·
/// Journal · Training · More.
struct HCCTabBar: View {
  @Binding var selection: OpenVitalsAppTab
  let tabs: [OpenVitalsAppTab]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: HCCTheme.Radius.tabBar, style: .continuous)
    return HStack(alignment: .top, spacing: 0) {
      ForEach(tabs) { tab in
        item(tab)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background {
      shape
        .fill(HCCTheme.Color.tabBarFill)
        // `inset 0 1px 0 rgba(255,255,255,.06)` — a top highlight, faded out
        // down the sides so it reads as a lit edge rather than an outline.
        .overlay {
          shape.strokeBorder(
            LinearGradient(
              colors: [HCCTheme.Color.white(0.06), Color.clear],
              startPoint: .top,
              endPoint: .bottom
            ),
            lineWidth: 1
          )
        }
        .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 12)
    }
    .padding(.horizontal, HCCTheme.Spacing.tabBarInset)
    .padding(.bottom, HCCTheme.Spacing.tabBarBottom)
  }

  private func item(_ tab: OpenVitalsAppTab) -> some View {
    let isSelected = selection == tab
    return Button {
      selection = tab
    } label: {
      VStack(spacing: 4) {
        Image(systemName: Self.icon(for: tab))
          .font(.system(size: 20, weight: .regular))
          .frame(height: 22)
        Text(tab.title)
          .font(HCCTheme.Font.body(size: 10, weight: .semibold))
          .tracking(0.2)
      }
      .foregroundStyle(isSelected ? HCCTheme.Color.accent : HCCTheme.Color.muted)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  /// The mockup's line icons, as their SF Symbol equivalents.
  ///
  /// The mockup draws them as 1.7-pt stroked paths; SF Symbols at regular
  /// weight are the same drawing in the platform's own hand, and using them
  /// keeps one icon language across the bar and the rows.
  private static func icon(for tab: OpenVitalsAppTab) -> String {
    switch tab {
    case .home: "house"
    case .health: "heart"
    case .journal: "text.book.closed"
    case .training: "dumbbell"
    case .coach: "bubble.left"
    case .developer: "tray.and.arrow.down"
    case .more: "line.3.horizontal"
    }
  }
}

// ── Reserved tabs ────────────────────────────────────────────────────────────

/// The whole content of a tab whose feature belongs to a later phase.
///
/// One sentence, no controls. Anything else — a preview, a disabled button, a
/// "notify me" — would be a surface that does not work, which is exactly what
/// this screen exists to avoid.
struct HCCPhaseScreen: View {
  let title: String
  let note: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(HCCTheme.Font.display(size: 26, weight: .semibold))
        .tracking(-0.6)
        .foregroundStyle(HCCTheme.Color.text)
      Text(note)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.muted)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .hccBackground()
    .toolbar(.hidden, for: .navigationBar)
  }
}
