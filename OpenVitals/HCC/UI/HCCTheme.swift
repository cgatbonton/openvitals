import SwiftUI
import UIKit

// The "C · Command" design tokens, in one place.
//
// Every number and colour here is copied from the approved interactive mockup's
// `.phone` custom-property block. Nothing downstream hardcodes a hex value, a
// corner radius or a font name: a screen that needs a colour asks
// `HCCTheme.Color`, and a screen that needs type asks `HCCTheme.Font`. That is
// what makes a token change a one-file edit rather than a sweep.
//
// This file is cloud-mode only. `OpenVitalsTheme` still owns the bridge path's
// look; the two never mix on one screen.

enum HCCTheme {
  // ── Colour ─────────────────────────────────────────────────────────────────

  /// The mockup's CSS custom properties. Names match the CSS variable names so
  /// a token can be traced back to the mockup by grep.
  enum Color {
    /// `--bg` #070B14 — the page under the radial gradient.
    static let bg = hex(0x070B14)
    /// The radial gradient's hot centre, #14213D.
    static let bgGlow = hex(0x14213D)
    /// `--card` rgba(20,28,46,.72) — glass panel fill.
    static let card = hex(0x141C2E, alpha: 0.72)
    /// `--card2` rgba(28,38,62,.8) — the raised fill inside a card.
    static let card2 = hex(0x1C263E, alpha: 0.80)
    /// `--line` #1E2A45 — every hairline border and empty track.
    static let line = hex(0x1E2A45)
    /// `--text` #E9F0FF.
    static let text = hex(0xE9F0FF)
    /// `--muted` #7F8FB0 — labels, axes, secondary copy.
    static let muted = hex(0x7F8FB0)
    /// `--accent` #5AA9FF.
    static let accent = hex(0x5AA9FF)

    /// `--rec` #3DF0B0.
    static let rec = hex(0x3DF0B0)
    /// `--sleep` #5AA9FF.
    static let sleep = hex(0x5AA9FF)
    /// `--strain` #39E0F0.
    static let strain = hex(0x39E0F0)
    /// `--band` #1F3A5C — the shaded optimal window on a band strip.
    static let band = hex(0x1F3A5C)

    /// `--good` #3DF0B0.
    static let good = hex(0x3DF0B0)
    /// `--warn` #FF9A62.
    static let warn = hex(0xFF9A62)
    /// `--bad` #FF5C7A.
    static let bad = hex(0xFF5C7A)
    /// `--yellow` #FFD166 — the middle recovery band.
    static let yellow = hex(0xFFD166)

    // ── Ring furniture (web `src/components/ScoreRings.tsx`) ────────────────
    //
    // The mockup and the web app disagreed on these; the web wins. They are
    // named rather than inlined so a ring never carries a literal hex.

    /// The empty track behind a progress arc, rgba(139,155,181,0.16).
    static let ringTrack = hex(0x8B9BB5, alpha: 0.16)
    /// The 60 tick marks outside a ticked ring, rgba(139,155,181,0.22).
    static let ringTick = hex(0x8B9BB5, alpha: 0.22)
    /// The target mark crossing the track, #E8EEF7.
    static let ringTarget = hex(0xE8EEF7)
    /// The gradient a ring uses when there is no value to draw — calibrating,
    /// or a score the server never produced. Deliberately colourless: a `--`
    /// ring must not look like a reading.
    static let ringMutedStart = hex(0x8A9BB5)
    static let ringMutedEnd = hex(0x5A6B85)

    // ── Recovery orb (web `src/components/BiometricOrb.tsx`) ────────────────
    //
    // Recovery is the one score whose gradient depends on its BAND, so the
    // colour itself carries the reading. These are the web's pairs; the flat
    // `rec` green above stays for everything that is not a recovery band (the
    // `good` tone, a positive delta, and so on).

    /// ≥ nominal — #39E0F0 → #8B7BFF.
    static let orbPrimed = (hex(0x39E0F0), hex(0x8B7BFF))
    /// Between watch and nominal — #FF7A45 → #39E0F0.
    static let orbModerate = (hex(0xFF7A45), hex(0x39E0F0))
    /// Below watch — #FF4D5E → #FF7A45.
    static let orbRest = (hex(0xFF4D5E), hex(0xFF7A45))
    /// No band to show — the muted ring pair.
    static let orbUnknown = (ringMutedStart, ringMutedEnd)

    /// Heart-rate zone colours, Z1…Z5 (mockup `ZONES`).
    static let zones: [SwiftUI.Color] = [
      hex(0x7F8FB0), hex(0x5AA9FF), hex(0x39E0F0), hex(0xFFD166), hex(0xFF5C7A),
    ]

    /// Zone colour for a 1-based zone number, clamped.
    static func zone(_ number: Int) -> SwiftUI.Color {
      zones[min(max(number - 1, 0), zones.count - 1)]
    }

    static func hex(_ value: UInt32, alpha: Double = 1) -> SwiftUI.Color {
      SwiftUI.Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255,
        opacity: alpha
      )
    }
  }

  // ── Radius ─────────────────────────────────────────────────────────────────

  enum Radius {
    /// `--radius` — cards, tiles, hero panels.
    static let card: CGFloat = 14
    /// Activity rows, buttons, small controls.
    static let small: CGFloat = 12
    /// Sheets.
    static let sheet: CGFloat = 22
    /// Pills and chips (CSS 999px).
    static let pill: CGFloat = 999
  }

  // ── Type ───────────────────────────────────────────────────────────────────

  /// The three families the mockup uses, resolved once.
  ///
  /// The font files are not bundled yet. Rather than scatter `.custom("Outfit")`
  /// through the screens — which silently falls back to the system font per call
  /// site and is invisible to review — every text style goes through here. When
  /// the families are added to the target this file is the only edit, and until
  /// then the fallbacks are chosen to keep the *shape* of the design: a rounded
  /// display face for titles and big numbers, and a monospaced face wherever the
  /// mockup wants tabular digits.
  enum Font {
    /// Titles and big numbers — Outfit 500 in the mockup.
    static func display(size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
      resolve(Resolved.display, size: size, weight: weight, fallbackDesign: .rounded)
    }

    /// Body copy and labels — IBM Plex Sans.
    static func body(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
      resolve(Resolved.body, size: size, weight: weight, fallbackDesign: .default)
    }

    /// Numbers, chips, sources, axes — IBM Plex Mono.
    static func data(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
      resolve(Resolved.data, size: size, weight: weight, fallbackDesign: .monospaced)
    }

    private static func resolve(
      _ family: String?,
      size: CGFloat,
      weight: SwiftUI.Font.Weight,
      fallbackDesign: SwiftUI.Font.Design
    ) -> SwiftUI.Font {
      guard let family else {
        return .system(size: size, weight: weight, design: fallbackDesign)
      }
      return .custom(family, size: size).weight(weight)
    }

    /// Family lookup, done once per launch. `UIFont.familyNames` is the honest
    /// question — "is this face actually installed in this process" — rather
    /// than trusting that a build phase copied a file in.
    private enum Resolved {
      static let display = family("Outfit")
      static let body = family("IBM Plex Sans")
      static let data = family("IBM Plex Mono")

      private static func family(_ name: String) -> String? {
        UIFont.familyNames.contains(name) ? name : nil
      }
    }
  }

  // ── Metric scales ──────────────────────────────────────────────────────────

  /// The strain scale is 0–21 everywhere, server-side and here.
  static let strainMax: Double = 21
}

// ── Background ───────────────────────────────────────────────────────────────

/// The screen ground: a wide, shallow navy glow at the top over near-black.
///
/// The CSS is `radial-gradient(120% 60% at 50% -10%, #14213D 0%, #070B14 60%)`,
/// an ELLIPSE — wider than it is tall and centred above the top edge. SwiftUI's
/// `RadialGradient` is circular, so the ellipse is built by drawing the circular
/// gradient at the vertical radius and stretching it horizontally.
struct HCCBackground: View {
  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let height = max(proxy.size.height, 1)
      // The CSS percentages are of the box, and `at 50% -10%` is the centre.
      let verticalRadius = height * 0.6
      let horizontalRadius = width * 1.2

      HCCTheme.Color.bg
        .overlay(alignment: .topLeading) {
          RadialGradient(
            gradient: Gradient(stops: [
              .init(color: HCCTheme.Color.bgGlow, location: 0),
              .init(color: HCCTheme.Color.bg, location: 1),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: verticalRadius
          )
          .frame(width: verticalRadius * 2, height: verticalRadius * 2)
          .scaleEffect(x: horizontalRadius / verticalRadius, y: 1, anchor: .center)
          .position(x: width / 2, y: -0.1 * height)
        }
        .clipped()
    }
    .ignoresSafeArea()
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

/// The glass panel: translucent navy fill over an 8-pt blur, one hairline
/// border, 14-pt corners.
private struct HCCCardModifier: ViewModifier {
  let secondary: Bool
  let radius: CGFloat
  let padding: EdgeInsets?

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return content
      .padding(padding ?? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        shape
          // `backdrop-filter: blur(8px)` — the material is the blur, the fill
          // on top is the card's own colour.
          .fill(.ultraThinMaterial)
          .overlay(shape.fill(secondary ? HCCTheme.Color.card2 : HCCTheme.Color.card))
      }
      .overlay(shape.strokeBorder(HCCTheme.Color.line, lineWidth: 1))
      .clipShape(shape)
  }
}

extension View {
  /// The cloud-mode screen ground. Apply once per screen, behind the content.
  func hccBackground() -> some View {
    background(HCCBackground())
  }

  /// The mockup's `.card` (or `.card2` when `secondary`).
  func hccCard(
    secondary: Bool = false,
    radius: CGFloat = HCCTheme.Radius.card,
    padding: EdgeInsets? = nil
  ) -> some View {
    modifier(HCCCardModifier(secondary: secondary, radius: radius, padding: padding))
  }

  /// The small-caps treatment, for a label that is already a `Text`.
  func hccLabelStyle(size: CGFloat = 10, color: SwiftUI.Color = HCCTheme.Color.muted) -> some View {
    font(HCCTheme.Font.body(size: size, weight: .semibold))
      .tracking(size * 0.12)
      .textCase(.uppercase)
      .foregroundStyle(color)
  }
}

// ── Label ────────────────────────────────────────────────────────────────────

/// The uppercase, letter-spaced micro-label the mockup puts over every group
/// (`.ringwrap .lbl`, `.card h4`, `.stat3 .l`): 10–11 pt, weight 600,
/// letter-spacing 0.12em, muted.
struct HCCLabel: View {
  let text: String
  var size: CGFloat = 10
  var color: SwiftUI.Color = HCCTheme.Color.muted

  init(_ text: String, size: CGFloat = 10, color: SwiftUI.Color = HCCTheme.Color.muted) {
    self.text = text
    self.size = size
    self.color = color
  }

  var body: some View {
    Text(text)
      .hccLabelStyle(size: size, color: color)
  }
}

// ── Recovery bands ───────────────────────────────────────────────────────────

/// Where a recovery score sits, and what the mockup calls it.
///
/// The cutoffs (67 / 34) are the server's own published bands — they arrive on
/// `/instance` as `scoreBands.recovery` — and are duplicated here only as the
/// fallback for a screen that has not loaded `/instance` yet. Prefer
/// `band(for:bands:)` so the server stays the authority.
enum HCCRecoveryBand {
  case primed
  case moderate
  case rest

  /// Fallback cutoffs, matching the mockup's `recBand`.
  static let defaultNominal: Double = 67
  static let defaultWatch: Double = 34

  static func band(for value: Double, bands: HCCScoreBand? = nil) -> HCCRecoveryBand {
    let nominal = bands?.nominal ?? defaultNominal
    let watch = bands?.watch ?? defaultWatch
    if value >= nominal { return .primed }
    if value >= watch { return .moderate }
    return .rest
  }

  /// The pair the recovery ring fills with. Band-dependent on purpose: on the
  /// web the orb's colour IS part of the reading, so a screen that drew every
  /// recovery ring green would be dropping information the number carries.
  var gradient: (SwiftUI.Color, SwiftUI.Color) {
    switch self {
    case .primed: HCCTheme.Color.orbPrimed
    case .moderate: HCCTheme.Color.orbModerate
    case .rest: HCCTheme.Color.orbRest
    }
  }

  /// The band's own colour — the LEADING colour of its orb gradient, so a pill,
  /// a chip, a word and the ring beside them never disagree.
  ///
  /// Note this is not `HCCTheme.Color.rec`: that flat green stays for the
  /// places the design uses "good" generically, outside the recovery bands.
  var color: SwiftUI.Color { gradient.0 }

  /// "Primed" / "Moderate" / "Rest" — a readiness word, not a health claim.
  var word: String {
    switch self {
    case .primed: "Primed"
    case .moderate: "Moderate"
    case .rest: "Rest"
    }
  }
}

// ── Font resolution report ───────────────────────────────────────────────────

#if DEBUG
extension HCCTheme.Font {
  /// What the three families actually resolved to in this process.
  ///
  /// The fallback path is silent by design — a missing family quietly becomes a
  /// system face — which is exactly what makes a bundling mistake invisible.
  /// This says out loud whether the real face is installed, which faces the
  /// family exposes, and which concrete face a weight request lands on.
  ///
  /// Variable fonts matter here: Outfit and IBM Plex Sans ship as single
  /// variable files, and iOS registers their named instances as separate faces
  /// within the family. That is what makes `.weight(.medium)` resolvable rather
  /// than always returning the default instance.
  static func debugResolutionReport() -> [String] {
    [
      report(role: "display", family: "Outfit", weight: .medium),
      report(role: "body", family: "IBM Plex Sans", weight: .regular),
      report(role: "data", family: "IBM Plex Mono", weight: .regular),
    ]
  }

  private static func report(role: String, family: String, weight: UIFont.Weight) -> String {
    guard UIFont.familyNames.contains(family) else {
      return "\(role) family=\"\(family)\" MISSING -> system fallback"
    }
    let faces = UIFont.fontNames(forFamilyName: family)
    let descriptor = UIFontDescriptor(fontAttributes: [
      .family: family,
      .traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    let resolved = UIFont(descriptor: descriptor, size: 20).fontName
    return "\(role) family=\"\(family)\" OK faces=\(faces.count) resolved=\(resolved)"
  }
}
#endif
