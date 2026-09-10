import SwiftUI
import UIKit

// The "C · Command" design tokens, in one place.
//
// Every number and colour here is copied from the approved design handoff
// (`design_handoff_hcc_tinted/README.md`, direction "Tinted", mock `2b`).
// Nothing downstream hardcodes a hex value, a corner radius or a font name: a
// screen that needs a colour asks `HCCTheme.Color`, and a screen that needs type
// asks `HCCTheme.Font`. That is what makes a token change a one-file edit rather
// than a sweep.
//
// This file is cloud-mode only. `OpenVitalsTheme` still owns the bridge path's
// look; the two never mix on one screen.

enum HCCTheme {
  // ── Colour ─────────────────────────────────────────────────────────────────

  /// The handoff's colour tokens. Names match the handoff's own names so a token
  /// can be traced back to the spec by grep.
  enum Color {
    // ── Ground ───────────────────────────────────────────────────────────────

    /// `#06080F` — the page base, and the flat colour below 45 %.
    static let bg = hex(0x06080F)
    /// `#0A1020` — the top of the page's vertical gradient.
    static let bgTop = hex(0x0A1020)

    // ── Surfaces ─────────────────────────────────────────────────────────────

    /// `rgba(255,255,255,.045)` — the neutral card fill. No border, no material.
    static let card = white(0.045)
    /// `rgba(255,255,255,.05)` — the raised fill inside a card (tiles, rows).
    static let card2 = white(0.05)
    /// `rgba(255,255,255,.06)` — icon buttons, the day pill, utility buttons.
    static let control = white(0.06)
    /// `rgba(255,255,255,.07)` — chips, secondary buttons, menu controls.
    static let control2 = white(0.07)
    /// `rgba(255,255,255,.06)` — row dividers and empty tracks.
    static let line = white(0.06)

    // ── Text ─────────────────────────────────────────────────────────────────

    /// `#EEF2FA` — primary text.
    static let text = hex(0xEEF2FA)
    /// `#D5DEF0` — body copy on a card (the Home insight card).
    static let textBody = hex(0xD5DEF0)
    /// `#C7D2EA` — secondary body (insight summaries).
    static let textSecondary = hex(0xC7D2EA)
    /// `#8A97B5` — labels, axes, meta.
    static let muted = hex(0x8A97B5)
    /// `#6E7C9C` — footnotes and tertiary lines.
    static let muted2 = hex(0x6E7C9C)
    /// `#55627F` — row chevrons and the unanswered dash.
    static let chevron = hex(0x55627F)

    // ── Accent and metric colours ────────────────────────────────────────────

    /// `#5AA9FF`.
    static let accent = hex(0x5AA9FF)
    /// `#8CC4FF` — accent text on a dark tint.
    static let accentText = hex(0x8CC4FF)

    /// `#5AA9FF` — sleep.
    static let sleep = hex(0x5AA9FF)
    /// `#8CC4FF` — sleep's light tint, for text on a sleep-tinted ground.
    static let sleepText = hex(0x8CC4FF)
    /// `#39E0F0` — recovery.
    static let recovery = hex(0x39E0F0)
    /// `#7BEAF5` — recovery's light tint.
    static let recoveryText = hex(0x7BEAF5)
    /// `#5A8BFF` — strain (indigo). NOTE this is not the strain RING's leading
    /// colour: the ring gradient is cyan → indigo and keeps its own tokens
    /// below, so changing the strain surface colour cannot silently repaint the
    /// ring.
    static let strain = hex(0x5A8BFF)
    /// `#9DB4FF` — strain's light tint.
    static let strainText = hex(0x9DB4FF)

    /// `#3DF0B0` — the generic "good" green.
    static let rec = hex(0x3DF0B0)
    /// `#3DF0B0`, same token under the name the status vocabulary uses.
    static let good = rec
    /// `#7DF5C8` — good's light tint.
    static let goodText = hex(0x7DF5C8)

    /// `#F5C44B` — watch.
    static let warn = hex(0xF5C44B)
    /// `#FF5C7A` — alert.
    static let bad = hex(0xFF5C7A)
    /// `#FFD166` — the middle recovery band on the strain/recovery chart.
    static let yellow = hex(0xFFD166)

    /// `rgba(61,240,176,.22)` — the shaded optimal window on a band strip.
    static let band = hex(0x3DF0B0, alpha: 0.22)

    // ── Chrome ───────────────────────────────────────────────────────────────

    /// `rgba(20,26,40,.92)` — the floating tab bar's fill.
    static let tabBarFill = hex(0x141A28, alpha: 0.92)
    /// `#070B14` — text and glyphs on the CTA gradient.
    static let ctaText = hex(0x070B14)
    /// `#07131F` — the Coach FAB's glyph.
    static let fabGlyph = hex(0x07131F)
    /// `#3A4560` — an unchecked checkbox's 1-px stroke.
    static let checkboxStroke = hex(0x3A4560)

    // ── Ring furniture (web `src/components/ScoreRings.tsx`) ────────────────
    //
    // Named rather than inlined so a ring never carries a literal hex.

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

    /// The sleep ring's trailing colour, `#2E6BE0`.
    static let ringSleepEnd = hex(0x2E6BE0)
    /// The strain ring's pair, `#39E0F0 → #5A8BFF`. Unchanged by the restyle:
    /// the ring keeps the cyan lead even though the strain SURFACE colour moved
    /// to indigo, which is why these are their own tokens.
    static let ringStrainStart = hex(0x39E0F0)
    static let ringStrainEnd = hex(0x5A8BFF)

    // ── Recovery orb (web `src/components/BiometricOrb.tsx`) ────────────────
    //
    // Recovery is the one score whose gradient depends on its BAND, so the
    // colour itself carries the reading.

    /// ≥ nominal — #39E0F0 → #8B7BFF.
    static let orbPrimed = (hex(0x39E0F0), hex(0x8B7BFF))
    /// Between watch and nominal — #FF7A45 → #39E0F0.
    static let orbModerate = (hex(0xFF7A45), hex(0x39E0F0))
    /// Below watch — #FF4D5E → #FF7A45.
    static let orbRest = (hex(0xFF4D5E), hex(0xFF7A45))
    /// No band to show — the muted ring pair.
    static let orbUnknown = (ringMutedStart, ringMutedEnd)

    /// Heart-rate zone colours, Z1…Z5.
    static let zones: [SwiftUI.Color] = [
      hex(0x7F8FB0), hex(0x5AA9FF), hex(0x39E0F0), hex(0xFFD166), hex(0xFF5C7A),
    ]

    /// Zone colour for a 1-based zone number, clamped.
    static func zone(_ number: Int) -> SwiftUI.Color {
      zones[min(max(number - 1, 0), zones.count - 1)]
    }

    // ── Gradients ────────────────────────────────────────────────────────────

    /// `linear-gradient(135deg, #5AA9FF, #39E0F0)` — the primary CTA.
    static let ctaGradient = LinearGradient(
      colors: [hex(0x5AA9FF), hex(0x39E0F0)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    /// `linear-gradient(135deg, #5AA9FF, #3DF0B0)` — the Coach FAB.
    static let fabGradient = LinearGradient(
      colors: [hex(0x5AA9FF), hex(0x3DF0B0)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    /// `linear-gradient(135deg, rgba(57,224,240,.14), rgba(139,123,255,.10))` —
    /// the Home insight card, the one card that also carries a border.
    static let insightGradient = LinearGradient(
      colors: [hex(0x39E0F0, alpha: 0.14), hex(0x8B7BFF, alpha: 0.10)],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )

    /// The metric tint: a vertical wash of one metric's colour, used instead of
    /// the neutral card fill on a card that belongs to that metric.
    ///
    /// `linear-gradient(180deg, rgba(metric, top), rgba(metric, bottom))`.
    static func tint(_ color: SwiftUI.Color, top: Double = 0.15, bottom: Double = 0.035) -> LinearGradient {
      LinearGradient(
        colors: [color.opacity(top), color.opacity(bottom)],
        startPoint: .top,
        endPoint: .bottom
      )
    }

    /// A flat colour as a gradient, for the `fill:` entry point of `hccCard`.
    static func flat(_ color: SwiftUI.Color) -> LinearGradient {
      LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
    }

    // ── Primitives ───────────────────────────────────────────────────────────

    /// `rgba(255,255,255,alpha)` — the handoff writes every surface this way.
    static func white(_ alpha: Double) -> SwiftUI.Color {
      SwiftUI.Color(.sRGB, red: 1, green: 1, blue: 1, opacity: alpha)
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
    /// Cards.
    static let card: CGFloat = 20
    /// Dashboard tiles and the Health page grid.
    static let tile: CGFloat = 16
    /// Activity rows.
    static let row: CGFloat = 14
    /// Primary/secondary buttons.
    static let button: CGFloat = 14
    /// Icon buttons, the day pill, utility buttons, menu controls.
    static let control: CGFloat = 12
    /// The smallest controls — icon tiles inside a card, dropdowns.
    static let small: CGFloat = 10
    /// The floating tab bar.
    static let tabBar: CGFloat = 24
    /// Sheets.
    static let sheet: CGFloat = 22
    /// Pills and chips (CSS 999px).
    static let pill: CGFloat = 999
  }

  // ── Spacing ────────────────────────────────────────────────────────────────

  /// The handoff's chrome geometry, in one place so the tab bar, the Coach FAB
  /// and every scroll view's bottom inset are derived from the same numbers
  /// rather than three magic constants that drift apart.
  enum Spacing {
    /// The bar is inset this far from each side.
    static let tabBarInset: CGFloat = 16
    /// …and floats this far above the bottom safe-area edge.
    static let tabBarBottom: CGFloat = 22
    /// The bar's own height: 8 pt of container padding each side over a 44-pt
    /// item (6 + 22 glyph + 4 gap + ~12 label + 6).
    static let tabBarHeight: CGFloat = 60
    /// What a scrolling screen must leave below its last card so the card
    /// clears the floating bar: the bar's box plus a breathing gap.
    static let tabBarClearance: CGFloat = 90
    /// The Coach FAB's own box, and how far it sits above the bar.
    static let fabSize: CGFloat = 50
    static let fabGap: CGFloat = 14
    /// The FAB's distance from the bottom safe-area edge.
    static var fabBottom: CGFloat { tabBarBottom + tabBarHeight + fabGap }
    /// A screen with no floating chrome under it (a sheet) still wants a little
    /// air below the last card.
    static let sheetBottom: CGFloat = 18
  }

  // ── Type ───────────────────────────────────────────────────────────────────

  /// The three families the design uses, resolved once.
  ///
  /// Outfit's DEFAULT instance is Thin, so every display call must carry a
  /// weight — `.display(size:)` without one would silently render hairline.
  /// The handoff moved the display face to 600, which is the default here.
  enum Font {
    /// Titles and big numbers — Outfit.
    static func display(size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
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

/// The screen ground: a vertical wash from `#0A1020` at the top to `#06080F` at
/// 45 %, flat below.
///
/// (The radial navy glow of the first design is gone — the "Tinted" direction
/// puts the colour on the cards instead of behind them.)
struct HCCBackground: View {
  var body: some View {
    LinearGradient(
      stops: [
        .init(color: HCCTheme.Color.bgTop, location: 0),
        .init(color: HCCTheme.Color.bg, location: 0.45),
        .init(color: HCCTheme.Color.bg, location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

/// The card: a fill and 20-pt corners. No stroke, no material — the "Tinted"
/// direction carries separation by fill alone, and the ONE card with a border
/// (Home's insight card) asks for it explicitly through the `fill:` entry point.
private struct HCCCardModifier: ViewModifier {
  let fill: LinearGradient
  let border: Color?
  let radius: CGFloat
  let padding: EdgeInsets?

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return content
      // The handoff's card padding: 14 vertical × 16 horizontal.
      .padding(padding ?? EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(shape.fill(fill))
      .overlay {
        if let border {
          shape.strokeBorder(border, lineWidth: 1)
        }
      }
      .clipShape(shape)
  }
}

extension View {
  /// The cloud-mode screen ground. Apply once per screen, behind the content.
  func hccBackground() -> some View {
    background(HCCBackground())
  }

  /// The handoff's `.card`.
  ///
  /// - `secondary` swaps the neutral fill for the raised `card2`.
  /// - `tint` swaps it for that metric's vertical wash — the "card that belongs
  ///   to a metric carries the metric's colour" rule. `tintTop`/`tintBottom` are
  ///   the two alphas; the handoff uses 0.14–0.16 → 0.03–0.04 and a few cards
  ///   ask for a lighter pair (Genetics 0.08 → 0.02).
  func hccCard(
    secondary: Bool = false,
    tint: Color? = nil,
    tintTop: Double = 0.15,
    tintBottom: Double = 0.035,
    radius: CGFloat = HCCTheme.Radius.card,
    padding: EdgeInsets? = nil
  ) -> some View {
    let fill: LinearGradient = {
      if let tint { return HCCTheme.Color.tint(tint, top: tintTop, bottom: tintBottom) }
      return HCCTheme.Color.flat(secondary ? HCCTheme.Color.card2 : HCCTheme.Color.card)
    }()
    return modifier(HCCCardModifier(fill: fill, border: nil, radius: radius, padding: padding))
  }

  /// The card with an arbitrary fill and an optional 1-px border — the escape
  /// hatch for Home's insight card, which is the one card in the design that is
  /// neither neutral nor a single metric's tint.
  func hccCard(
    fill: LinearGradient,
    border: Color? = nil,
    radius: CGFloat = HCCTheme.Radius.card,
    padding: EdgeInsets? = nil
  ) -> some View {
    modifier(HCCCardModifier(fill: fill, border: border, radius: radius, padding: padding))
  }

  /// The micro-label treatment, for a label that is already a `Text`:
  /// Plex Sans 700, uppercase, tracking 0.9 at 10 pt.
  func hccLabelStyle(size: CGFloat = 10, color: SwiftUI.Color = HCCTheme.Color.muted) -> some View {
    font(HCCTheme.Font.body(size: size, weight: .bold))
      .tracking(size * 0.09)
      .textCase(.uppercase)
      .foregroundStyle(color)
  }
}

// ── Label ────────────────────────────────────────────────────────────────────

/// The uppercase, letter-spaced micro-label over every group: Plex Sans 700,
/// 10 pt, tracking 0.9, muted `#8A97B5`.
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

/// Where a recovery score sits, and what the design calls it.
///
/// The cutoffs (67 / 34) are the server's own published bands — they arrive on
/// `/instance` as `scoreBands.recovery` — and are duplicated here only as the
/// fallback for a screen that has not loaded `/instance` yet. Prefer
/// `band(for:bands:)` so the server stays the authority.
enum HCCRecoveryBand {
  case primed
  case moderate
  case rest

  /// Fallback cutoffs.
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
  static func debugResolutionReport() -> [String] {
    [
      report(role: "display", family: "Outfit", weight: .semibold),
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
