import SwiftUI

/// The mockup's `.fab`: a 50-pt gradient circle bottom-right, above the tab bar.
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
        .font(.system(size: 21, weight: .regular))
        .foregroundStyle(HCCTheme.Color.hex(0x07131F))
        .frame(width: 50, height: 50)
        .background(
          Circle().fill(
            LinearGradient(
              colors: [HCCTheme.Color.hex(0x5AA9FF), HCCTheme.Color.hex(0x3DF0B0)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        )
        .shadow(color: HCCTheme.Color.accent.opacity(0.7), radius: 12, x: 0, y: 8)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Coach")
    .accessibilityHint("Ask your Command Center about your data")
  }
}
