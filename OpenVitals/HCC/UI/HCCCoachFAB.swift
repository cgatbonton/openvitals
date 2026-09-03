import SwiftUI

/// The mockup's `.fab`: a 50-pt gradient circle bottom-right, above the tab bar.
///
/// In this phase the Coach has no backend, no persistence and no consent path
/// (AGENTS.md keeps it out until it does), so the button is present and says so
/// rather than being wired to nothing. A dead tap reads as a bug; this opens
/// the shared "arrives in a later phase" sheet.
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
    .accessibilityHint("Arrives in a later phase")
  }
}
