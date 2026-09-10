import SwiftUI

/// Which score a ring is drawing. Only the gradient changes.
enum HCCRingKind {
  case rec
  case sleep
  case strain

  /// Gradient start / end.
  ///
  /// Sleep and strain are fixed. Recovery is NOT: on the web it is the
  /// biometric orb, whose colour depends on the band, so the ring's colour is
  /// part of the reading rather than decoration. Pass the band; `nil` means
  /// there is no band to show and the muted pair is used.
  ///
  /// (The mockup drew recovery a flat green. Where the mockup and the web
  /// differ, the web wins — the flat green stays available as
  /// `HCCTheme.Color.rec` for the generic "good" tone.)
  func colors(recoveryBand band: HCCRecoveryBand?) -> (Color, Color) {
    switch self {
    case .rec: band?.gradient ?? HCCTheme.Color.orbUnknown
    case .sleep: (HCCTheme.Color.sleep, HCCTheme.Color.ringSleepEnd)
    // The strain RING stays cyan → indigo even though the strain SURFACE colour
    // is now the indigo end. Its own tokens, so a change to one cannot silently
    // repaint the other.
    case .strain: (HCCTheme.Color.ringStrainStart, HCCTheme.Color.ringStrainEnd)
    }
  }

  /// The band-less pair. Kept so existing call sites compile; a recovery ring
  /// should call `colors(recoveryBand:)` so it gets its own band's orb.
  var colors: (Color, Color) { colors(recoveryBand: nil) }

  var accessibilityName: String {
    switch self {
    case .rec: "Recovery"
    case .sleep: "Sleep"
    case .strain: "Strain"
    }
  }
}

/// The score ring, a direct port of `ring()` in the approved mockup.
///
/// Geometry notes, because they are not arbitrary:
///
///  * The drawing radius is `size/2 - stroke/2 - (ticks ? 12 : 2)`, so a ticked
///    ring keeps its tick ring INSIDE the frame rather than clipping it.
///  * Progress is floored at 0.02 so a zero-valued ring still shows the round
///    cap as a dot. That dot is a rendering of "0", never a stand-in for a value
///    the server did not send — a missing value passes `value: nil` and the
///    centre reads `--`.
///  * The progress arc is drawn twice: once blurred (the CSS `blur(3)` glow
///    filter) and once sharp on top.
struct HCCRing: View {
  let progress: Double
  let kind: HCCRingKind
  var size: CGFloat = 120
  var stroke: CGFloat = 9
  var ticks: Bool = false
  /// The number in the middle. `nil` renders `--` — never a fabricated value.
  var value: String?
  var unit: String?
  /// The small data-font line under the value ("PRIMED", "TARGET 13.5", "84 · 51").
  var sub: String?
  /// A second mark on the track, as a fraction of the same scale (the strain
  /// target). `nil` draws none.
  var target: Double?
  /// Recovery only: which band this score is in, which chooses the orb
  /// gradient. `nil` on a recovery ring means "no band to show" and draws the
  /// muted pair — the same thing a missing value does.
  var band: HCCRecoveryBand?
  /// How long the fill waits before it runs. Home staggers its three rings by
  /// 0.1 s (0 / 0.1 / 0.2), which is the design's own timing.
  var animationDelay: Double = 0

  /// How far the arc is drawn right now. Starts at zero and animates up to
  /// `clampedProgress` on appear, and again whenever the value changes.
  @State private var drawn: Double = 0

  init(
    progress: Double,
    kind: HCCRingKind,
    size: CGFloat = 120,
    stroke: CGFloat = 9,
    ticks: Bool = false,
    value: String?,
    unit: String? = nil,
    sub: String? = nil,
    target: Double? = nil,
    band: HCCRecoveryBand? = nil,
    animationDelay: Double = 0
  ) {
    self.progress = progress
    self.kind = kind
    self.size = size
    self.stroke = stroke
    self.ticks = ticks
    self.value = value
    self.unit = unit
    self.sub = sub
    self.target = target
    self.band = band
    self.animationDelay = animationDelay
  }

  // ── Geometry ───────────────────────────────────────────────────────────────

  private var radius: CGFloat { (size / 2) - stroke / 2 - (ticks ? 12 : 2) }
  private var center: CGPoint { CGPoint(x: size / 2, y: size / 2) }
  private var clampedProgress: Double { min(max(progress, 0.02), 1) }
  /// 28 pt at the handoff's 100-pt ring, kept size-relative so the detail
  /// screens' larger rings scale with it.
  private var valueFontSize: CGFloat { size * 0.28 }
  /// 11 pt at 28.
  private var unitFontSize: CGFloat { valueFontSize * 0.393 }
  private var subFontSize: CGFloat { max(7.5, size * 0.075) }

  /// SVG places text by BASELINE; SwiftUI places it by the centre of its line
  /// box. For the system faces the ascent/descent split puts the visual centre
  /// about 0.28em above the baseline, so every `y` from the mockup is converted
  /// once, here, rather than nudged per call site.
  private static let baselineToCenter: CGFloat = 0.28

  var body: some View {
    ZStack {
      if ticks { tickMarks }
      track
      progressArc
      if let target { targetTick(at: target) }
      centreText
    }
    .frame(width: size, height: size)
    // The fill runs once on appear and again if the value changes under it —
    // a re-scored night must not leave a stale arc on screen.
    .onAppear { runFill() }
    .onChange(of: clampedProgress) { _, _ in runFill() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.accessibilityName)
    .accessibilityValue(accessibilityValue)
  }

  /// ~1.1 s ease-out, after `animationDelay`.
  private func runFill() {
    withAnimation(.easeOut(duration: 1.1).delay(animationDelay)) {
      drawn = clampedProgress
    }
  }

  private var accessibilityValue: String {
    guard let value else { return "Not available" }
    return [value, unit, sub].compactMap { $0 }.joined(separator: " ")
  }

  // ── Layers ─────────────────────────────────────────────────────────────────

  /// 60 marks outside the track, every 6°, longer and thicker every fifth.
  private var tickMarks: some View {
    ZStack {
      tickPath(major: true).stroke(HCCTheme.Color.ringTick, lineWidth: 1.4)
      tickPath(major: false).stroke(HCCTheme.Color.ringTick, lineWidth: 0.7)
    }
    .frame(width: size, height: size)
  }

  private func tickPath(major: Bool) -> Path {
    var path = Path()
    for index in 0..<60 where (index % 5 == 0) == major {
      let angle = Double(index) * 6 * .pi / 180
      let inner = radius + 6
      let outer = radius + (major ? 11 : 9)
      path.move(to: point(radius: inner, angle: angle))
      path.addLine(to: point(radius: outer, angle: angle))
    }
    return path
  }

  /// True when there is nothing to colour: no value, or a recovery ring with no
  /// band. Both draw the muted pair, so a `--` ring never wears a score's
  /// colour.
  private var isMuted: Bool {
    value == nil || (kind == .rec && band == nil)
  }

  private var track: some View {
    Circle()
      .stroke(HCCTheme.Color.ringTrack, lineWidth: stroke)
      .frame(width: radius * 2, height: radius * 2)
  }

  private var progressArc: some View {
    let pair = isMuted ? (HCCTheme.Color.ringMutedStart, HCCTheme.Color.ringMutedEnd)
                       : kind.colors(recoveryBand: band)
    let gradient = LinearGradient(
      colors: [pair.0, pair.1],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    let shape = Circle()
      .trim(from: 0, to: drawn)
      .stroke(gradient, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
      .frame(width: radius * 2, height: radius * 2)
      .rotationEffect(.degrees(-90))

    return ZStack {
      // The glow says "this is live". A muted ring has no reading behind it, so
      // it gets the arc without the halo.
      if !isMuted { shape.blur(radius: 3) }
      shape
    }
  }

  /// The 2.5-pt mark crossing the track at `fraction` of the scale.
  private func targetTick(at fraction: Double) -> some View {
    let angle = min(max(fraction, 0), 1) * 2 * .pi
    var path = Path()
    path.move(to: point(radius: radius - stroke / 2 - 2, angle: angle))
    path.addLine(to: point(radius: radius + stroke / 2 + 2, angle: angle))
    // The web draws this 3.5 pt on its hero ring; scaled here so the mark keeps
    // its weight relative to the ring rather than swallowing a 94-pt one.
    let width = Swift.max(2, 3.5 * size / 176)
    return path
      .stroke(HCCTheme.Color.ringTarget, lineWidth: width)
      .frame(width: size, height: size)
  }

  private var centreText: some View {
    // Mockup: baseline is `size/2 - 1` when there is a sub line, otherwise
    // `size/2 + fs*0.36`.
    let valueBaseline = sub == nil ? size / 2 + valueFontSize * 0.36 : size / 2 - 1
    let valueCentre = valueBaseline - Self.baselineToCenter * valueFontSize
    let subCentre = size / 2 + valueFontSize * 0.66 - Self.baselineToCenter * subFontSize

    return ZStack {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(value ?? "--")
          .font(HCCTheme.Font.display(size: valueFontSize, weight: .semibold))
          .foregroundStyle(HCCTheme.Color.text)
          // −0.8 at the handoff's 28-pt numeral.
          .tracking(-valueFontSize * 0.0286)
        // A unit next to `--` would read as a scale for a number that is not
        // there, so it is dropped with the value.
        if let unit, value != nil {
          Text(unit)
            .font(HCCTheme.Font.body(size: unitFontSize, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.muted)
        }
      }
      .monospacedDigit()
      .lineLimit(1)
      .fixedSize()
      .position(x: size / 2, y: valueCentre)

      if let sub {
        Text(sub)
          .font(HCCTheme.Font.data(size: subFontSize, weight: .medium))
          .foregroundStyle(HCCTheme.Color.muted)
          .lineLimit(1)
          .fixedSize()
          .position(x: size / 2, y: subCentre)
      }
    }
    .frame(width: size, height: size)
  }

  // ── Maths ──────────────────────────────────────────────────────────────────

  /// A point on the circle, angle measured clockwise from 12 o'clock — the same
  /// convention the mockup's `sin`/`-cos` pair uses.
  private func point(radius r: CGFloat, angle: Double) -> CGPoint {
    CGPoint(
      x: center.x + r * CGFloat(sin(angle)),
      y: center.y - r * CGFloat(cos(angle))
    )
  }
}

// ── Labelled ring ────────────────────────────────────────────────────────────

/// A ring with the handoff's metric chip under it — the Home row's tappable
/// unit.
///
/// The caption is no longer a muted micro-label with a chevron: it is a pill in
/// the metric's own colour (`rgba(metric,.18)` behind the metric's light tint),
/// which is what ties a ring to the card that carries the same tint further down
/// the screen. `tint` is the metric's base colour and `tintText` its light
/// tint — both passed in, because a ring wrap has no way to know which metric it
/// is drawing and guessing one would be the wrong colour on a bad day.
struct HCCRingWrap: View {
  let title: String
  let ring: HCCRing
  let tint: Color
  let tintText: Color

  var body: some View {
    VStack(spacing: 12) {
      ring
      Text(title)
        .hccLabelStyle(size: 10, color: tintText)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.18)))
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .contentShape(Rectangle())
  }
}
