import SwiftUI

/// The handoff's `.fab`: a 50-pt gradient square with 16-pt corners,
/// bottom-right, floating 14 above the tab bar.
///
/// It sits in the shell rather than on a screen, exactly as the mockup has it —
/// the Coach is asked from wherever the owner already is, and the sheet it opens
/// carries the name of that screen as its `pageContext` so a question about
/// "this" resolves against what is behind the sheet.
///
/// The design review kept this button hidden until the chat actually worked, on
/// the rule that a control which does nothing must not exist. It works now: the
/// tap opens `HCCCoachSheet` over the current tab.
struct HCCCoachFAB: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "bubble.left")
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(HCCTheme.Color.fabGlyph)
        .frame(width: HCCTheme.Spacing.fabSize, height: HCCTheme.Spacing.fabSize)
        .background(
          RoundedRectangle(cornerRadius: HCCTheme.Radius.tile, style: .continuous)
            .fill(HCCTheme.Color.fabGradient)
        )
        // `0 8 20 rgba(90,169,255,.4)`; SwiftUI's radius is roughly half CSS's
        // blur, so 20 becomes 10.
        .shadow(color: HCCTheme.Color.accent.opacity(0.4), radius: 10, x: 0, y: 8)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Coach")
    .accessibilityHint("Ask your Command Center about your data")
  }
}
