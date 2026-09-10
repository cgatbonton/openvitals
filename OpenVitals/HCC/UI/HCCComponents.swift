import SwiftUI

// The reusable pieces of the "C · Command" mockup, one struct per CSS class.
//
// Everything here is presentation only: a component takes already-resolved
// strings, colours and fractions and draws them. None of them formats a metric,
// decides a band, or substitutes a value for a missing one — that is the
// caller's job, and keeping it out of here is what stops a component from
// quietly inventing a number.

// ── Chip ─────────────────────────────────────────────────────────────────────

/// `.chip` — a filled pill with an optional coloured dot. No border: the
/// "Tinted" direction separates by fill, not by hairline.
struct HCCChip: View {
  let text: String
  var dotColor: Color?

  init(_ text: String, dotColor: Color? = nil) {
    self.text = text
    self.dotColor = dotColor
  }

  var body: some View {
    HStack(spacing: 5) {
      if let dotColor {
        Circle().fill(dotColor).frame(width: 6, height: 6)
      }
      Text(text)
        .font(HCCTheme.Font.data(size: 10, weight: .medium))
        .tracking(0.4)
    }
    .foregroundStyle(HCCTheme.Color.muted)
    .padding(.horizontal, 9)
    .padding(.vertical, 3)
    .background(Capsule().fill(HCCTheme.Color.control2))
  }
}

// ── Section header ───────────────────────────────────────────────────────────

/// `.sec` — a display-font section title with an optional trailing control.
///
/// `size` is the handoff's two section scales: 18 for "My Dashboard", 15 for a
/// section title inside a card ("Today's activities", "Tonight's sleep").
/// Tracking follows the size, −0.4 at 18 and −0.2 at 15.
struct HCCSectionHeader<Trailing: View>: View {
  let title: String
  var size: CGFloat = 18
  @ViewBuilder let trailing: () -> Trailing

  init(title: String, size: CGFloat = 18, @ViewBuilder trailing: @escaping () -> Trailing) {
    self.title = title
    self.size = size
    self.trailing = trailing
  }

  var body: some View {
    HStack(alignment: .center) {
      Text(title)
        .font(HCCTheme.Font.display(size: size, weight: .semibold))
        .tracking(size >= 18 ? -0.4 : -0.2)
        .foregroundStyle(HCCTheme.Color.text)
      Spacer(minLength: 8)
      trailing()
    }
    // The remainder of the mockup's larger section margin, on top of the 10 the
    // containing stack already supplies. See "Card Spacing Is Stack Spacing".
    .padding(.top, 4)
    .padding(.bottom, 0)
  }
}

extension HCCSectionHeader where Trailing == EmptyView {
  init(title: String, size: CGFloat = 18) {
    self.init(title: title, size: size) { EmptyView() }
  }
}

/// `.sec .lnk` — the micro-label text button beside a section title, in the
/// accent's light tint `#8CC4FF`.
struct HCCSectionLink: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HCCLabel(title, size: 10, color: HCCTheme.Color.accentText)
    }
    .buttonStyle(.plain)
  }
}

// ── Pill ─────────────────────────────────────────────────────────────────────

/// `.pill` — a tinted status word (recovery band, protocol status, evidence).
///
/// NOT uppercased: the handoff's pills print their text exactly as the server
/// wrote it ("ACTIVE" is already capitals; "heterozygous CT" and "watch" are
/// not), and a `textCase(.uppercase)` here would shout the lowercase ones.
struct HCCPill: View {
  enum Tone {
    case good
    case warn
    case bad
    case muted
    /// The handoff's `info` tone. `accent` is the same rendering under the name
    /// the existing call sites already use.
    case info
    case accent

    /// The pill's text colour — the metric's LIGHT tint, not its base colour,
    /// because the pill's ground is a 16 % wash of that same base.
    var color: Color {
      switch self {
      case .good: HCCTheme.Color.rec
      case .warn: HCCTheme.Color.warn
      case .bad: HCCTheme.Color.bad
      case .muted: HCCTheme.Color.muted
      case .info, .accent: HCCTheme.Color.accentText
      }
    }

    var background: Color {
      switch self {
      // `rgba(255,255,255,.08)` — the muted pill is white, not a hue.
      case .muted: HCCTheme.Color.white(0.08)
      case .info, .accent: HCCTheme.Color.accent.opacity(0.16)
      default: color.opacity(0.16)
      }
    }
  }

  let text: String
  var tone: Tone = .good
  /// An explicit colour wins over the tone — the recovery hero pill is tinted
  /// with the band colour, which is not one of the tones.
  var color: Color?

  init(_ text: String, tone: Tone = .good, color: Color? = nil) {
    self.text = text
    self.tone = tone
    self.color = color
  }

  var body: some View {
    let foreground = color ?? tone.color
    Text(text)
      .font(HCCTheme.Font.data(size: 9.5))
      .tracking(0.4)
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        Capsule().fill(color.map { $0.opacity(0.16) } ?? tone.background)
      )
  }
}

// ── Bars ─────────────────────────────────────────────────────────────────────

/// `.bars` — the small column chart under "Last 14 days" / "Last 7 nights".
///
/// `targets` draws the mockup's `b.t::after` rule: a 2-pt line across the
/// column at the target's height. Pass `nil` when there is no target to draw;
/// a target is never invented from the data.
struct HCCBars: View {
  let values: [Double]
  let maxValue: Double
  let color: (Double) -> Color
  var targets: [Double]?
  var height: CGFloat = 56

  init(
    values: [Double],
    max maxValue: Double,
    color: @escaping (Double) -> Color,
    targets: [Double]? = nil,
    height: CGFloat = 56
  ) {
    self.values = values
    self.maxValue = maxValue
    self.color = color
    self.targets = targets
    self.height = height
  }

  /// Convenience for a single-colour chart.
  init(values: [Double], max maxValue: Double, color: Color, targets: [Double]? = nil, height: CGFloat = 56) {
    self.init(values: values, max: maxValue, color: { _ in color }, targets: targets, height: height)
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        bar(index: index, value: value)
      }
    }
    .frame(height: height)
  }

  private func bar(index: Int, value: Double) -> some View {
    let fraction = maxValue > 0 ? min(Swift.max(value / maxValue, 0), 1) : 0
    let barHeight = height * CGFloat(fraction)
    let target = targets.flatMap { $0.indices.contains(index) ? $0[index] : nil }

    return ZStack(alignment: .top) {
      // Full-height frame so the target line can sit anywhere on the column.
      Color.clear
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        UnevenRoundedRectangle(
          topLeadingRadius: 3,
          bottomLeadingRadius: 1,
          bottomTrailingRadius: 1,
          topTrailingRadius: 3,
          style: .continuous
        )
        .fill(color(value))
        .opacity(index == values.count - 1 ? 1 : 0.85)
        .frame(height: barHeight)
      }
      if let target, maxValue > 0 {
        let targetFraction = min(Swift.max(target / maxValue, 0), 1)
        Rectangle()
          .fill(HCCTheme.Color.text.opacity(0.7))
          .frame(height: 2)
          .offset(y: height * CGFloat(1 - targetFraction))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }
}

/// `.axis` — the two muted end labels under a chart.
struct HCCAxis: View {
  let leading: String
  let trailing: String

  var body: some View {
    HStack {
      Text(leading)
      Spacer(minLength: 8)
      Text(trailing)
    }
    .font(HCCTheme.Font.data(size: 9.5))
    .tracking(0.38)
    .foregroundStyle(HCCTheme.Color.muted)
    .padding(.top, 6)
  }
}

// ── Sparkline ────────────────────────────────────────────────────────────────

/// `.spark` — a 28-pt trace with a dot on the newest point.
struct HCCSparkline: View {
  let values: [Double]
  var color: Color = HCCTheme.Color.accent
  var height: CGFloat = 28

  var body: some View {
    GeometryReader { proxy in
      let points = points(in: proxy.size)
      ZStack {
        Path { path in
          guard let first = points.first else { return }
          path.move(to: first)
          for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

        if let last = points.last {
          Circle()
            .fill(color)
            .frame(width: 4.4, height: 4.4)
            .position(last)
        }
      }
    }
    .frame(height: height)
  }

  private func points(in size: CGSize) -> [CGPoint] {
    guard values.count > 1 else { return [] }
    let minimum = values.min() ?? 0
    let maximum = values.max() ?? 0
    let range = maximum - minimum == 0 ? 1 : maximum - minimum
    return values.enumerated().map { index, value in
      CGPoint(
        x: CGFloat(Double(index) / Double(values.count - 1)) * (size.width - 4) + 2,
        y: size.height - 3 - CGFloat((value - minimum) / range) * (size.height - 6)
      )
    }
  }
}

// ── Key/value grid ───────────────────────────────────────────────────────────

struct HCCKeyValue: Identifiable {
  let key: String
  let value: String
  /// The "Need 8h 05m" row the mockup renders in full-strength text.
  var emphasized: Bool = false

  var id: String { key }

  init(_ key: String, _ value: String, emphasized: Bool = false) {
    self.key = key
    self.value = value
    self.emphasized = emphasized
  }
}

/// `.kv` — muted label left, tabular value right.
struct HCCKeyValueGrid: View {
  let rows: [HCCKeyValue]

  init(rows: [HCCKeyValue]) {
    self.rows = rows
  }

  var body: some View {
    VStack(spacing: 6) {
      ForEach(rows) { row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.key)
            .font(HCCTheme.Font.body(size: 12.5))
            .foregroundStyle(row.emphasized ? HCCTheme.Color.text : HCCTheme.Color.muted)
          Spacer(minLength: 8)
          Text(row.value)
            .font(HCCTheme.Font.data(size: 12.5, weight: row.emphasized ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(HCCTheme.Color.text)
            .multilineTextAlignment(.trailing)
        }
      }
    }
  }
}

// ── Optimal band ─────────────────────────────────────────────────────────────

/// `.band` — the optimal window with a marker for where the value sits.
///
/// `position`, `low` and `high` are fractions of the SAME axis the caller chose.
/// This view knows nothing about units or targets; it draws where it is told.
struct HCCBand: View {
  let position: Double
  var low: Double = 0.30
  var high: Double = 0.72

  init(position: Double, low: Double = 0.30, high: Double = 0.72) {
    self.position = position
    self.low = low
    self.high = high
  }

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        // The 6-pt track, its optimal window, and the marker on top. The track
        // and window are clipped to the same rounded rect; the marker is not,
        // because it is taller than the track by design.
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3, style: .continuous).fill(HCCTheme.Color.line)
          Rectangle()
            .fill(HCCTheme.Color.band)
            .frame(width: width * CGFloat(Swift.max(high - low, 0)))
            .offset(x: width * CGFloat(low))
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

        // A 10-pt white disc with a 2-px ring in the page ground, so the marker
        // stays legible wherever on the track it lands.
        Circle()
          .fill(Color.white)
          .frame(width: 10, height: 10)
          .overlay(Circle().strokeBorder(HCCTheme.Color.bg, lineWidth: 2))
          .offset(x: width * CGFloat(min(Swift.max(position, 0), 1)) - 5)
      }
      .frame(height: 10)
    }
    .frame(height: 10)
    .padding(.top, 6)
    .padding(.bottom, 2)
  }
}

// ── Optimal band placement and grading ───────────────────────────────────────

/// Where a value sits against an OPTIMAL target — the app's one grading
/// vocabulary. Never "normal": a value can sit inside a lab's population range
/// and still be below the target this app grades against, and calling that
/// "normal" is the exact swap the project forbids.
enum HCCTargetGrade {
  case below
  case inTarget
  case above

  var label: String {
    switch self {
    case .below: "Below target"
    case .inTarget: "In target"
    case .above: "Above target"
    }
  }

  /// Off target is amber, not red: distance from a target is a direction to
  /// work in, not an alert. Red stays for the things that raise one.
  var tone: HCCPill.Tone {
    switch self {
    case .inTarget: .good
    case .below, .above: .warn
    }
  }

  var color: Color {
    switch self {
    case .inTarget: HCCTheme.Color.good
    case .below, .above: HCCTheme.Color.warn
    }
  }
}

extension HCCOptimalRange {
  /// Which side of the target `value` falls on. A one-sided band grades only on
  /// the side it has — "≥ 45 ms" cannot put anything above target.
  func grade(_ value: Double) -> HCCTargetGrade {
    if let low, value < low { return .below }
    if let high, value > high { return .above }
    return .inTarget
  }

  /// Where `value` sits on `HCCBand`'s rail.
  ///
  /// The strip shades 30%–72% of its width as the optimal window, so the band's
  /// own low and high map onto exactly those two fractions and anything outside
  /// is clamped to the visible rail. One home for the mapping: the Health
  /// monitor and the Wearables deck draw the same strip, and two copies of this
  /// arithmetic would eventually place the same reading in two places.
  func placement(for value: Double) -> Double? {
    guard let low, let high, high > low else { return nil }
    let fraction = (value - low) / (high - low)
    return min(max(0.30 + fraction * 0.42, 0.02), 0.98)
  }

  /// "45–58 bpm", "≥ 45 ms", "≤ 5" — the target in words, or nil when the band
  /// has no bound at all to state.
  func targetText(unit: String?) -> String? {
    let suffix = (unit?.isEmpty == false) ? " \(unit!)" : ""
    switch (low, high) {
    case let (low?, high?): return "\(Self.bound(low))–\(Self.bound(high))\(suffix)"
    case let (low?, nil): return "≥ \(Self.bound(low))\(suffix)"
    case let (nil, high?): return "≤ \(Self.bound(high))\(suffix)"
    default: return nil
    }
  }

  /// A bound at the precision it was actually written with. The bands are hand
  /// researched and mix the two — 45 bpm, 92.3 °F — and printing "45.0" implies
  /// a tenth of a beat that nobody chose.
  private static func bound(_ value: Double) -> String {
    HCCFormat.decimal(value, value == value.rounded() ? 0 : 1)
  }
}

// ── Z-score bar ──────────────────────────────────────────────────────────────

/// `.z` — a signed deviation bar growing out of a centre tick, clamped to ±2 SD.
///
/// Sign convention is the CALLER's: the mockup passes `-(rhr - baseline)` so
/// that "better" always grows right. Negative fills warn-coloured and grows
/// left.
struct HCCZScoreBar: View {
  let z: Double

  init(z: Double) {
    self.z = z
  }

  var body: some View {
    let clamped = min(Swift.max(z, -2), 2)
    let fraction = abs(clamped) / 2 * 0.5

    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(HCCTheme.Color.line).frame(height: 6)
        Rectangle()
          .fill(HCCTheme.Color.muted)
          .frame(width: 1, height: 10)
          .offset(x: width / 2, y: -2)
        Capsule()
          .fill(clamped < 0 ? HCCTheme.Color.warn : HCCTheme.Color.accent)
          .frame(width: width * CGFloat(fraction), height: 6)
          .offset(x: clamped < 0 ? width / 2 - width * CGFloat(fraction) : width / 2)
      }
      .frame(height: 10)
    }
    .frame(height: 10)
  }
}

// ── Three-up stats ───────────────────────────────────────────────────────────

struct HCCStat: Identifiable {
  let value: String
  let label: String

  var id: String { label }

  init(value: String, label: String) {
    self.value = value
    self.label = label
  }
}

/// `.stat3` — three centred number/label pairs.
struct HCCStat3: View {
  let items: [HCCStat]

  init(items: [HCCStat]) {
    self.items = items
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ForEach(items) { item in
        VStack(spacing: 4) {
          Text(item.value)
            .font(HCCTheme.Font.display(size: 20, weight: .medium))
            .monospacedDigit()
            .tracking(-0.4)
            .foregroundStyle(HCCTheme.Color.text)
          HCCLabel(item.label, size: 9.5)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, 10)
  }
}

// ── Buttons ──────────────────────────────────────────────────────────────────

/// One button in a `.btns` row.
struct HCCButtonSpec {
  let title: String
  let action: () -> Void
  /// A disabled button still says why when tapped elsewhere; here it just
  /// renders dimmed and takes no tap.
  var isEnabled: Bool = true
  /// A secondary button whose action removes something: same shape, `bad`
  /// text, so the row reads the same and the one that destroys stands out.
  var isDestructive: Bool = false
  /// The handoff's optional 12-pt leading glyph — "Start activity" carries a
  /// play, "Add" a plus. An SF Symbol name, or `nil` for a text-only button.
  var systemImage: String?

  init(
    title: String,
    isEnabled: Bool = true,
    isDestructive: Bool = false,
    systemImage: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.isEnabled = isEnabled
    self.isDestructive = isDestructive
    self.systemImage = systemImage
    self.action = action
  }
}

/// `.btns` — up to two full-width buttons, secondary left, primary right.
struct HCCButtonRow: View {
  /// The two shapes the handoff draws.
  ///
  /// `.standard` is the card CTA pair: gradient primary, `rgba(255,255,255,.07)`
  /// secondary, 13 pt 600 sentence case, radius 14.
  /// `.utility` is the Training control row: flatter, smaller, uppercase,
  /// radius 12 — a row of settings rather than a call to action.
  enum Style {
    case standard
    case utility
  }

  var primary: HCCButtonSpec?
  var secondary: HCCButtonSpec?
  var style: Style = .standard

  init(primary: HCCButtonSpec? = nil, secondary: HCCButtonSpec? = nil, style: Style = .standard) {
    self.primary = primary
    self.secondary = secondary
    self.style = style
  }

  var body: some View {
    HStack(spacing: 8) {
      if let secondary { button(secondary, isPrimary: false) }
      if let primary { button(primary, isPrimary: true) }
    }
  }

  @ViewBuilder
  private func button(_ spec: HCCButtonSpec, isPrimary: Bool) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: style == .utility ? HCCTheme.Radius.control : HCCTheme.Radius.button,
      style: .continuous
    )
    Button(action: spec.action) {
      HStack(spacing: 6) {
        if let systemImage = spec.systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
        }
        label(spec)
      }
      .foregroundStyle(foreground(spec, isPrimary: isPrimary))
      .frame(maxWidth: .infinity)
      .padding(.vertical, style == .utility ? 11 : 13)
      .padding(.horizontal, 8)
      .background {
        if style == .standard, isPrimary {
          shape.fill(HCCTheme.Color.ctaGradient)
        } else {
          shape.fill(style == .utility ? HCCTheme.Color.control : HCCTheme.Color.control2)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(!spec.isEnabled)
    .opacity(spec.isEnabled ? 1 : 0.45)
  }

  @ViewBuilder
  private func label(_ spec: HCCButtonSpec) -> some View {
    switch style {
    case .standard:
      Text(spec.title)
        .font(HCCTheme.Font.body(size: 13, weight: .semibold))
    case .utility:
      Text(spec.title)
        .font(HCCTheme.Font.body(size: 11, weight: .semibold))
        .tracking(0.88)
        .textCase(.uppercase)
    }
  }

  private func foreground(_ spec: HCCButtonSpec, isPrimary: Bool) -> Color {
    if spec.isDestructive { return HCCTheme.Color.bad }
    if style == .standard, isPrimary { return HCCTheme.Color.ctaText }
    return HCCTheme.Color.text
  }
}

// ── Rows ─────────────────────────────────────────────────────────────────────

/// `.toggle` — a label and the handoff's 44×26 switch, over a hairline.
struct HCCToggleRow: View {
  let title: String
  @Binding var isOn: Bool
  var showsDivider: Bool = true

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(title)
          .font(HCCTheme.Font.body(size: 14, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        HCCSwitch(isOn: $isOn)
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onTapGesture { isOn.toggle() }
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
  }
}

/// `.sw` — the 44×26 pill switch, drawn rather than using `Toggle` so it
/// matches: CTA gradient when on, `rgba(255,255,255,.08)` when off, white knob.
struct HCCSwitch: View {
  @Binding var isOn: Bool

  var body: some View {
    ZStack(alignment: isOn ? .trailing : .leading) {
      Capsule()
        .fill(HCCTheme.Color.white(0.08))
        .overlay {
          if isOn { Capsule().fill(HCCTheme.Color.ctaGradient) }
        }
        .frame(width: 44, height: 26)
      Circle()
        .fill(Color.white)
        .frame(width: 22, height: 22)
        .padding(.horizontal, 2)
    }
    .frame(width: 44, height: 26)
    .animation(.easeOut(duration: 0.15), value: isOn)
  }
}

/// The checkbox itself, so a screen that needs one outside a row (the Training
/// set table's 5-column grid) draws the same box rather than a near-miss.
///
/// Unchecked: transparent behind a 1-px `#3A4560` stroke. Checked: the CTA
/// gradient with an 11-pt bold checkmark in `#070B14`.
struct HCCCheckbox: View {
  let isOn: Bool
  var size: CGFloat = 22
  var radius: CGFloat = 7

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return ZStack {
      if isOn {
        shape.fill(HCCTheme.Color.ctaGradient)
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(HCCTheme.Color.ctaText)
      } else {
        shape.strokeBorder(HCCTheme.Color.checkboxStroke, lineWidth: 1)
      }
    }
    .frame(width: size, height: size)
  }
}

/// `.check` — a square checkbox, a label, and an optional right-hand meta note.
///
/// `size`/`radius` are the handoff's two boxes: 22/7 for a dose row, 20/6 for a
/// Training set row.
struct HCCCheckRow: View {
  let title: String
  @Binding var isOn: Bool
  var meta: String?
  var showsDivider: Bool = true
  var size: CGFloat = 22
  var radius: CGFloat = 7

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        HCCCheckbox(isOn: isOn, size: size, radius: radius)
        Text(title)
          .font(HCCTheme.Font.body(size: 13))
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        if let meta {
          Text(meta)
            .font(HCCTheme.Font.data(size: 11))
            .foregroundStyle(HCCTheme.Color.muted)
        }
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
      .onTapGesture { isOn.toggle() }
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
  }
}

/// `.menu .it` — a tappable settings row with an optional right-hand value.
///
/// The chevron appears ONLY when the row navigates. A chevron on a row that
/// does nothing is a promise the row cannot keep, which is why it follows
/// `action` rather than a flag a caller could set wrong.
struct HCCMenuRow: View {
  let title: String
  var detail: String?
  /// More's account card prints its detail in the recovery tint rather than
  /// muted. The default is the muted meta colour every other row uses.
  var detailColor: Color = HCCTheme.Color.muted
  var showsDivider: Bool = true
  /// Overrides the "chevron follows `action`" rule for the one row that acts
  /// without navigating — More's Sign out, which the design draws bare.
  var showsChevron: Bool?
  var action: (() -> Void)?

  init(
    title: String,
    detail: String? = nil,
    detailColor: Color = HCCTheme.Color.muted,
    showsDivider: Bool = true,
    showsChevron: Bool? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.detail = detail
    self.detailColor = detailColor
    self.showsDivider = showsDivider
    self.showsChevron = showsChevron
    self.action = action
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(title)
          .font(HCCTheme.Font.body(size: 14, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        if let detail {
          Text(detail)
            .font(HCCTheme.Font.data(size: 11.5))
            .foregroundStyle(detailColor)
        }
        if showsChevron ?? (action != nil) {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.chevron)
        }
      }
      .padding(.vertical, 13)
      .contentShape(Rectangle())
      .onTapGesture { action?() }
      if showsDivider { HCCDivider() }
    }
  }
}

/// The 1-pt `rgba(255,255,255,.06)` rule that separates rows inside a card.
struct HCCDivider: View {
  var body: some View {
    Rectangle()
      .fill(HCCTheme.Color.line)
      .frame(height: 1)
  }
}

/// `.empty` — the centred muted sentence a card shows instead of rows.
struct HCCEmptyNote: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(HCCTheme.Font.body(size: 12.5))
      .foregroundStyle(HCCTheme.Color.muted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)
  }
}

// ── Coming soon ──────────────────────────────────────────────────────────────

/// The themed sheet a not-yet-built surface opens instead of doing nothing.
///
/// The mockup links to Journal, Training, Live activity and the Coach; those
/// arrive in later phases. A dead tap reads as a bug, so every one of those
/// links lands here and says plainly that the feature is not in this build.
struct HCCComingSoonSheet: View {
  let feature: String
  @Environment(\.dismiss) private var dismiss

  init(feature: String) {
    self.feature = feature
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(feature)
            .font(HCCTheme.Font.display(size: 24, weight: .semibold))
            .tracking(-0.6)
            .foregroundStyle(HCCTheme.Color.text)
          Text("Arrives in a later phase")
            .font(HCCTheme.Font.data(size: 10.5))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(HCCTheme.Color.muted)
        }
        Spacer(minLength: 8)
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
            .frame(width: 34, height: 34)
            .background(
              RoundedRectangle(cornerRadius: HCCTheme.Radius.control, style: .continuous)
                .fill(HCCTheme.Color.control)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
      }

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Not in this build")
        Text("\(feature) is not part of this phase of the app. Nothing was logged or changed.")
          .font(HCCTheme.Font.body(size: 12.5))
          .foregroundStyle(HCCTheme.Color.text)
      }
      .hccCard()

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .hccBackground()
  }
}

// ── Markdown ─────────────────────────────────────────────────────────────────

/// The server writes prose as markdown — insight summaries, "the plan", the
/// weekly retrospective — and the web app renders it. Rendering it as a flat
/// string on the phone would show `**bold**` and `- ` to the reader, so this is
/// the one place that turns those blocks into views.
///
/// Deliberately small: paragraphs, `#`-headings, `-`/`*` bullets and `1.`
/// ordered items, with inline emphasis handed to `AttributedString`'s own
/// markdown parser. It is not a general renderer — no tables, no code fences,
/// no images — because nothing the server writes uses them. A line it does not
/// recognise renders as a paragraph rather than disappearing.
///
/// Every block takes `.fixedSize(horizontal: false, vertical: true)`. Without it
/// a `Text` nested inside a padded, backgrounded container is offered too little
/// height and silently truncates with an ellipsis — which on these screens means
/// the server's prose is CUT, and a half-sentence reads as the whole claim. It
/// showed up first inside the insight panel's "detail behind it" block, where
/// the reasoning stopped after two lines.
struct HCCMarkdown: View {
  let text: String
  var size: Double = 12.5
  var color: Color = HCCTheme.Color.text

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case let .heading(level, content):
          inline(content)
            .font(HCCTheme.Font.display(size: size + (level == 1 ? 2.5 : 1), weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
            .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(content):
          inline(content)
            .font(HCCTheme.Font.body(size: size))
            .lineSpacing(3)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
        case let .item(marker, content):
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
              .font(HCCTheme.Font.body(size: size))
              .foregroundStyle(HCCTheme.Color.accent)
            inline(content)
              .font(HCCTheme.Font.body(size: size))
              .lineSpacing(3)
              .foregroundStyle(color)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inline(_ content: String) -> Text {
    Text(Self.attributed(content))
  }

  /// Inline emphasis only. `interpretedSyntax: .inlineOnlyPreservingWhitespace`
  /// keeps the parser from swallowing a line it thinks is a block, which is
  /// this type's job; a string it cannot parse is shown verbatim rather than
  /// dropped.
  static func attributed(_ content: String) -> AttributedString {
    (try? AttributedString(
      markdown: content,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(content)
  }

  enum Block {
    case heading(level: Int, String)
    case paragraph(String)
    /// A bullet or a numbered item; `marker` is what is drawn in the gutter.
    case item(marker: String, String)
  }

  /// Consecutive plain lines join into one paragraph — a hard-wrapped sentence
  /// is one sentence, not three — while a heading or a list item always starts
  /// its own block.
  static func blocks(_ text: String) -> [Block] {
    var out: [Block] = []
    var paragraph: [String] = []

    func flush() {
      let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      paragraph.removeAll()
      if !joined.isEmpty { out.append(.paragraph(joined)) }
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { flush(); continue }

      if line.hasPrefix("#") {
        flush()
        let hashes = line.prefix { $0 == "#" }.count
        let content = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        if !content.isEmpty { out.append(.heading(level: min(hashes, 3), content)) }
        continue
      }

      if line.hasPrefix("- ") || line.hasPrefix("* ") {
        flush()
        out.append(.item(marker: "•", String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        continue
      }

      if let dot = line.firstIndex(of: "."),
         line.distance(from: line.startIndex, to: dot) <= 2,
         Int(line[line.startIndex..<dot]) != nil,
         line.index(after: dot) < line.endIndex,
         line[line.index(after: dot)] == " " {
        flush()
        let number = String(line[line.startIndex...dot])
        let content = String(line[line.index(dot, offsetBy: 2)...]).trimmingCharacters(in: .whitespaces)
        out.append(.item(marker: number, content))
        continue
      }

      paragraph.append(line)
    }
    flush()
    return out
  }
}

// ── Status dot ───────────────────────────────────────────────────────────────

/// The web page's `StatusDot`: a 6-pt disc coloured by a server status word.
/// The vocabulary is the server's (`nominal` / `watch` / `alert` / `unknown`),
/// and an unrecognised word draws muted rather than guessing a colour.
struct HCCStatusDot: View {
  let status: String?
  var size: Double = 6

  var body: some View {
    Circle()
      .fill(Self.color(status))
      .frame(width: size, height: size)
  }

  static func color(_ status: String?) -> Color {
    switch status?.lowercased() {
    case "nominal", "optimal", "good": HCCTheme.Color.good
    case "watch": HCCTheme.Color.warn
    case "alert", "bad": HCCTheme.Color.bad
    default: HCCTheme.Color.muted
    }
  }
}

/// The severity vocabulary the server writes on an insight (`INFO` | `LOW` |
/// `MEDIUM` | `HIGH` | `CRITICAL`), read the two ways the web page reads it.
///
/// One home for the rule: the Insights page and the Health landing both show
/// the same card, and a severity that dots red on one screen and grey on the
/// other would be two answers to one question.
extension HCCStatusDot {
  /// The web page's dot rule: the dot follows SEVERITY, not status.
  static func severityStatus(_ severity: String) -> String {
    switch severity {
    case "CRITICAL", "HIGH": "alert"
    case "MEDIUM": "watch"
    default: "nominal"
    }
  }
}

extension HCCPill.Tone {
  static func severity(_ severity: String) -> HCCPill.Tone {
    switch severity {
    case "CRITICAL", "HIGH": .bad
    case "MEDIUM": .warn
    default: .muted
    }
  }
}

// ── Flow row ─────────────────────────────────────────────────────────────────

/// A wrapping row: lays children left to right and starts a new line when the
/// next one will not fit.
///
/// Exists because the web page's badge rows and weekly chips are `flex-wrap`,
/// and on a phone an `HStack` would either clip the last chip or squeeze every
/// one of them. Clipping is the worse failure — a chip row that shows four of
/// five numbers reads as "there are four".
struct HCCFlowRow<Content: View>: View {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 6
  @ViewBuilder let content: () -> Content

  var body: some View {
    Layout(spacing: spacing, lineSpacing: lineSpacing) { content() }
  }

  private struct Layout: SwiftUI.Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let width = proposal.width ?? .infinity
      let rows = rows(subviews: subviews, maxWidth: width)
      let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
      let widest = rows.map(\.width).max() ?? 0
      return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(
      in bounds: CGRect,
      proposal: ProposedViewSize,
      subviews: Subviews,
      cache: inout ()
    ) {
      var y = bounds.minY
      for row in rows(subviews: subviews, maxWidth: bounds.width) {
        var x = bounds.minX
        for index in row.indices {
          let size = subviews[index].sizeThatFits(.unspecified)
          subviews[index].place(
            at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
            proposal: ProposedViewSize(size)
          )
          x += size.width + spacing
        }
        y += row.height + lineSpacing
      }
    }

    private struct Row {
      var indices: [Int] = []
      var width: CGFloat = 0
      var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
      var rows: [Row] = []
      var current = Row()
      for index in subviews.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
        if !current.indices.isEmpty, needed > maxWidth {
          rows.append(current)
          current = Row()
        }
        current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
        current.height = max(current.height, size.height)
        current.indices.append(index)
      }
      if !current.indices.isEmpty { rows.append(current) }
      return rows
    }
  }
}
