import SwiftUI

/// The bottom bar from the mockup's `.tabs`: 22-pt line icons over 10.5-pt
/// labels, muted until selected, accent when selected, over a hairline top rule
/// on the flat page colour.
///
/// All five of the mockup's tabs are here from the start — Home · Health ·
/// Journal · Training · More. Journal and Training open a themed screen with
/// one line saying which phase they arrive in. That is deliberate: the bar's
/// shape is part of the design, and a page that states plainly it is not built
/// yet is honest, where a tab that appears months later is a surprise.
struct HCCTabBar: View {
  @Binding var selection: OpenVitalsAppTab
  let tabs: [OpenVitalsAppTab]

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(tabs) { tab in
        item(tab)
      }
    }
    .padding(.horizontal, 6)
    .padding(.top, 10)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity)
    .background(alignment: .top) {
      ZStack(alignment: .top) {
        HCCTheme.Color.bg
        Rectangle()
          .fill(HCCTheme.Color.line)
          .frame(height: 1)
      }
      .ignoresSafeArea(edges: .bottom)
    }
  }

  private func item(_ tab: OpenVitalsAppTab) -> some View {
    let isSelected = selection == tab
    return Button {
      selection = tab
    } label: {
      VStack(spacing: 5) {
        Image(systemName: Self.icon(for: tab))
          .font(.system(size: 19, weight: .regular))
          .frame(width: 22, height: 22)
        Text(tab.title)
          .font(HCCTheme.Font.body(size: 10.5, weight: .medium))
          .tracking(0.21)
      }
      .foregroundStyle(isSelected ? HCCTheme.Color.accent : HCCTheme.Color.muted)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
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
        .font(HCCTheme.Font.display(size: 20, weight: .medium))
        .tracking(-0.4)
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
