import ActivityKit
import SwiftUI
import WidgetKit

// The strain Live Activity's presentation: a lock-screen banner and the two
// Dynamic Island states.
//
// Copy rule: "Strain" and "target" only — no manufacturer name appears here,
// and none can, because the state carries numbers rather than a source label.
// A nil strain draws `--` and the server's reason; the bar stays empty rather
// than sitting at zero.

struct HCCStrainLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: HCCStrainActivityAttributes.self) { context in
      HCCStrainLockScreenView(state: context.state)
        .activityBackgroundTint(HCCWidgetTheme.bg)
        .activitySystemActionForegroundColor(HCCWidgetTheme.text)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text("Strain")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(HCCWidgetTheme.muted)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(HCCStrainCopy.strain(context.state.strain))
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(HCCWidgetTheme.strainRing.0)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HCCStrainBar(state: context.state)
        }
      } compactLeading: {
        Text("S")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(HCCWidgetTheme.strainRing.0)
      } compactTrailing: {
        Text(HCCStrainCopy.strain(context.state.strain))
          .font(.system(size: 13, weight: .medium, design: .monospaced))
          .foregroundStyle(HCCWidgetTheme.strainRing.0)
      } minimal: {
        Text(HCCStrainCopy.strain(context.state.strain))
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(HCCWidgetTheme.strainRing.0)
      }
    }
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

enum HCCStrainCopy {
  /// One decimal, no unit — strain is a 0–21 scale, not a percentage.
  static func strain(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? HCCWidgetTheme.placeholder
  }

  static func target(_ value: Double?) -> String {
    value.map { "target \(String(format: "%.1f", $0))" } ?? "no target yet"
  }
}

private struct HCCStrainLockScreenView: View {
  let state: HCCStrainActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Strain")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(HCCWidgetTheme.muted)
        Text(HCCStrainCopy.strain(state.strain))
          .font(.system(size: 28, weight: .medium, design: .rounded))
          .foregroundStyle(HCCWidgetTheme.text)
        Spacer(minLength: 6)
        if let recovery = state.recovery {
          Text("Recovery \(recovery)%")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(HCCWidgetTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(HCCWidgetTheme.card))
        }
      }

      HCCStrainBar(state: state)

      if let reason = state.reason, !reason.isEmpty, state.strain == nil {
        Text(reason)
          .font(.system(size: 11))
          .foregroundStyle(HCCWidgetTheme.muted)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }
}

/// Strain against today's target, on the 0–21 scale. The target is a tick, not
/// the end of the bar: a strain past target is a real thing and must be visible.
private struct HCCStrainBar: View {
  let state: HCCStrainActivityAttributes.ContentState

  private static let scale: Double = 21

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule()
            .fill(HCCWidgetTheme.ringTrack)
          if let strain = state.strain {
            Capsule()
              .fill(
                LinearGradient(
                  colors: [HCCWidgetTheme.strainRing.0, HCCWidgetTheme.strainRing.1],
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: width * fraction(strain))
          }
          if let target = state.target {
            Rectangle()
              .fill(HCCWidgetTheme.ringTarget)
              .frame(width: 2)
              .offset(x: width * fraction(target) - 1)
          }
        }
      }
      .frame(height: 8)

      Text(HCCStrainCopy.target(state.target))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(HCCWidgetTheme.muted)
    }
  }

  private func fraction(_ value: Double) -> Double {
    min(max(value / Self.scale, 0), 1)
  }
}
