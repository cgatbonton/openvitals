import SwiftUI

/// More → App → "Widgets". What exists, how to place one, and whether the app
/// and the widgets are actually reading the same file.
///
/// The last line is the one that earns the sheet: widgets fail silently. A
/// home-screen widget showing "--" looks identical whether the server has no
/// score, the app has never refreshed, or the shared container is missing —
/// so this says which of the three it is instead of leaving the owner guessing.
struct HCCWidgetsSheet: View {
  @State private var summary: HCCWidgetSummary?

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Widgets", subtitle: "Home screen and lock screen")

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("What you can add")
        VStack(spacing: 0) {
          HCCMenuRow(title: "Command Center", detail: "Home screen · small, medium")
          HCCMenuRow(title: "Recovery", detail: "Lock screen · circular")
          HCCMenuRow(title: "Scores", detail: "Lock screen · rectangular", showsDivider: false)
        }
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("How to add one")
        Text(
          """
          Touch and hold the Home Screen, tap ＋, then search for OpenVitals.
          For the lock screen, touch and hold the lock screen, tap Customize, \
          then add a widget under the clock.
          """
        )
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.text)
        .fixedSize(horizontal: false, vertical: true)
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Last summary")
        VStack(spacing: 0) {
          HCCMenuRow(title: "Written", detail: writtenDetail)
          HCCMenuRow(title: "Day", detail: summary?.day ?? "--")
          HCCMenuRow(title: "Shared container", detail: containerDetail, showsDivider: false)
        }
        if let reason = summary?.reason, !reason.isEmpty {
          HCCFootnote(reason)
        }
      }
      .hccCard()

      HCCFootnote(
        "Widgets read the last reading this app loaded. They do not fetch on their own, so a widget is as fresh as your last refresh or background wake."
      )
    }
    .onAppear { summary = HCCWidgetStore.read() }
  }

  private var writtenDetail: String {
    guard let updatedAt = summary?.updatedAt else { return "Never" }
    return HCCPushClock.time(updatedAt)
  }

  /// The honest answer, not a reassuring one: without the App Group the app and
  /// the widget each read their own copy and the widget will never update.
  private var containerDetail: String {
    HCCWidgetStore.usesAppGroup ? "Shared" : "Unavailable"
  }
}
