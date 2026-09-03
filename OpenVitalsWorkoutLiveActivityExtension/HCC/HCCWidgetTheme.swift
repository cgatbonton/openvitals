import SwiftUI

// The tokens and the one drawing primitive the HCC widgets need, restated for
// the widget extension.
//
// Why restated rather than shared: `OpenVitals/HCC/UI/HCCTheme.swift` compiles
// against `HCCScoreBand` (from `HCCModels.swift`), and `HCCRing.swift` compiles
// against `HCCTheme`, so pulling either into this target would drag the app's
// whole DTO layer with it. Everything below is a verbatim copy of a value that
// lives in exactly one place in the app, with the source line cited, so the two
// can be diffed by grep:
//
//   bg           HCCTheme.swift:22  #070B14
//   card         HCCTheme.swift:26  rgba(20,28,46,.72)
//   line         HCCTheme.swift:30  #1E2A45
//   text         HCCTheme.swift:32  #E9F0FF
//   muted        HCCTheme.swift:34  #7F8FB0
//   sleep ring   HCCTheme.swift:44  #5AA9FF → #2E6BE0   (HCCRing kind .sleep)
//   strain ring  HCCTheme.swift:46  #39E0F0 → #5A8BFF   (HCCRing kind .strain)
//   orbPrimed    HCCTheme.swift:84  #39E0F0 → #8B7BFF
//   orbModerate  HCCTheme.swift:86  #FF7A45 → #39E0F0
//   orbRest      HCCTheme.swift:88  #FF4D5E → #FF7A45
//   ringMuted    HCCTheme.swift:74  #8A9BB5 → #5A6B85
//   ringTrack    HCCTheme.swift:64  rgba(139,155,181,.16)
//   ringTarget   HCCTheme.swift:68  #E8EEF7
//
// Fonts are NOT restated. The bundled families are resources of the app target
// and are not registered in this extension's process, so `HCCTheme.Font`'s own
// documented fallbacks (rounded for display, monospaced for data) are what a
// widget would resolve to anyway — asking for them by name here would just be a
// lookup that always misses.

enum HCCWidgetTheme {
  static let bg = hex(0x070B14)
  static let card = hex(0x141C2E, alpha: 0.72)
  static let line = hex(0x1E2A45)
  static let text = hex(0xE9F0FF)
  static let muted = hex(0x7F8FB0)

  static let ringTrack = hex(0x8B9BB5, alpha: 0.16)
  static let ringTarget = hex(0xE8EEF7)
  static let ringMuted = (hex(0x8A9BB5), hex(0x5A6B85))

  static let sleepRing = (hex(0x5AA9FF), hex(0x2E6BE0))
  static let strainRing = (hex(0x39E0F0), hex(0x5A8BFF))

  /// The recovery ring's colour IS part of the reading, so the band chooses it.
  /// An unknown band draws the muted pair rather than guessing a colour.
  static func recoveryRing(band: String?) -> (Color, Color) {
    switch band {
    case "primed": return (hex(0x39E0F0), hex(0x8B7BFF))
    case "moderate": return (hex(0xFF7A45), hex(0x39E0F0))
    case "rest": return (hex(0xFF4D5E), hex(0xFF7A45))
    default: return ringMuted
    }
  }

  /// "Primed" / "Moderate" / "Rest" — a readiness word, not a health claim
  /// (`HCCTheme.swift:341`).
  static func recoveryWord(_ band: String?) -> String? {
    switch band {
    case "primed": return "Primed"
    case "moderate": return "Moderate"
    case "rest": return "Rest"
    default: return nil
    }
  }

  static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
    Color(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
      opacity: alpha
    )
  }

  /// The placeholder a missing value renders as, everywhere in this app.
  static let placeholder = "--"
}

/// A minimal score ring: track, gradient arc, optional target tick, a number in
/// the middle. The app's `HCCRing` adds ticks, a glow and a sub-line; at widget
/// sizes none of those survive, so this draws only what is legible.
///
/// `value == nil` draws the muted pair and `--`, never a zeroed arc.
struct HCCWidgetRing: View {
  let progress: Double?
  let colors: (Color, Color)
  var size: CGFloat = 54
  var stroke: CGFloat = 6
  var value: String?
  var unit: String?
  /// A second mark on the same scale (the strain target).
  var target: Double?

  private var radius: CGFloat { (size / 2) - stroke / 2 - 1 }

  var body: some View {
    ZStack {
      Circle()
        .stroke(HCCWidgetTheme.ringTrack, lineWidth: stroke)
        .frame(width: radius * 2, height: radius * 2)

      Circle()
        .trim(from: 0, to: min(max(progress ?? 0.02, 0.02), 1))
        .stroke(
          LinearGradient(
            colors: value == nil ? [HCCWidgetTheme.ringMuted.0, HCCWidgetTheme.ringMuted.1]
                                 : [colors.0, colors.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          style: StrokeStyle(lineWidth: stroke, lineCap: .round)
        )
        .frame(width: radius * 2, height: radius * 2)
        .rotationEffect(.degrees(-90))

      if let target { targetTick(at: target) }

      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(value ?? HCCWidgetTheme.placeholder)
          .font(.system(size: size * 0.30, weight: .medium, design: .rounded))
          .foregroundStyle(HCCWidgetTheme.text)
        // A unit beside `--` would read as a scale for a number that is not
        // there, so it goes with the value.
        if let unit, value != nil {
          Text(unit)
            .font(.system(size: size * 0.30 * 0.42, weight: .medium, design: .rounded))
            .foregroundStyle(HCCWidgetTheme.muted)
        }
      }
      .minimumScaleFactor(0.6)
      .lineLimit(1)
    }
    .frame(width: size, height: size)
  }

  private func targetTick(at fraction: Double) -> some View {
    let angle = min(max(fraction, 0), 1) * 2 * .pi
    var path = Path()
    path.move(to: point(radius: radius - stroke / 2 - 1, angle: angle))
    path.addLine(to: point(radius: radius + stroke / 2 + 1, angle: angle))
    return path
      .stroke(HCCWidgetTheme.ringTarget, lineWidth: 2)
      .frame(width: size, height: size)
  }

  /// Angles start at 12 o'clock and run clockwise, like the arc above.
  private func point(radius: CGFloat, angle: Double) -> CGPoint {
    CGPoint(
      x: size / 2 + radius * CGFloat(sin(angle)),
      y: size / 2 - radius * CGFloat(cos(angle))
    )
  }
}
