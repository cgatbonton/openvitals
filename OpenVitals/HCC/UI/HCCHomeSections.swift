import SwiftUI

// The pieces of Home, one struct per block of the mockup's `S.home`.
//
// Same rule as `HCCComponents`: everything here takes already-resolved strings
// and fractions. Not one of these views reads the store, formats a metric or
// decides what a missing value looks like — `HCCHomeView` does that, once, so
// there is a single place where a "--" can be introduced and a single place to
// check that none was introduced dishonestly.

// ── Top bar ──────────────────────────────────────────────────────────────────

/// `.daynav` — `‹ Today ›`. Forward is disabled on today, because there is no
/// day after it to read.
///
/// The handoff's shape: a 12-pt rounded pill on the control fill, 3 pt of
/// padding around 30×30 arrow slots, with the day itself in Outfit 600. Not
/// uppercase and not letter-spaced any more — it is a display label now, the
/// same face as the screen title above it. `labelSize` is the handoff's two
/// scales: 14 on Home, 13 in the Journal header.
struct HCCDayNav: View {
  let label: String
  let canGoBack: Bool
  let canGoForward: Bool
  var labelSize: CGFloat = 14
  let goBack: () -> Void
  let goForward: () -> Void

  init(
    label: String,
    canGoBack: Bool,
    canGoForward: Bool,
    labelSize: CGFloat = 14,
    goBack: @escaping () -> Void,
    goForward: @escaping () -> Void
  ) {
    self.label = label
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.labelSize = labelSize
    self.goBack = goBack
    self.goForward = goForward
  }

  var body: some View {
    HStack(spacing: 0) {
      arrow("chevron.left", enabled: canGoBack, action: goBack)
        .accessibilityLabel("Previous day")
      Text(label)
        .font(HCCTheme.Font.display(size: labelSize, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(minWidth: 74)
        .padding(.horizontal, 10)
        .lineLimit(1)
      arrow("chevron.right", enabled: canGoForward, action: goForward)
        .accessibilityLabel("Next day")
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: HCCTheme.Radius.control, style: .continuous)
        .fill(HCCTheme.Color.control)
    )
    .accessibilityElement(children: .contain)
    .accessibilityValue(label)
  }

  private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.3)
  }
}

/// The top bar's three slots: a control on each side, the day nav genuinely
/// centred between them.
///
/// The side slots take `maxWidth: .infinity`, which makes SwiftUI give them
/// equal widths and so puts the centre slot on the screen's midline. A plain
/// `Spacer()` on either side would only centre it while the two controls
/// happened to be the same width — and the device pill's width changes with the
/// hardware name it is showing, so the day label would drift as the name
/// changed. The pill absorbs the difference by truncating (it is already
/// `lineLimit(1)`); the day label never moves.
struct HCCTopBarLayout<Leading: View, Center: View, Trailing: View>: View {
  @ViewBuilder let leading: Leading
  @ViewBuilder let center: Center
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: 8) {
      leading.frame(maxWidth: .infinity, alignment: .leading)
      center.fixedSize()
      trailing.frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

/// The top bar's left control: pull every connected integration now.
///
/// The box's cron is the normal path (WHOOP every 3h, the Fitbit pipe twice a
/// day plus a 5-minute strain refresh, the scale twice a day). This is for the
/// minutes those schedules cannot cover — just off a workout, just off the
/// scale — so it has to show its own work: a spinner while it runs, and then
/// whether anything actually landed. A button that looks identical before and
/// after teaches the owner to tap it twice.
struct HCCSyncButton: View {
  let isRunning: Bool
  /// The finished state, if one is still on screen. `nil` while idle.
  let outcome: Bool?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        RoundedRectangle(cornerRadius: HCCTheme.Radius.control, style: .continuous)
          .fill(HCCTheme.Color.control)
        icon
      }
      .frame(width: 36, height: 36)
      .contentShape(RoundedRectangle(cornerRadius: HCCTheme.Radius.control, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isRunning)
    .accessibilityLabel("Sync now")
    .accessibilityValue(accessibilityValue)
  }

  @ViewBuilder private var icon: some View {
    if isRunning {
      // The system spinner rather than a rotating chevron: it is the one shape
      // iOS users already read as "working", and it cannot desynchronise from
      // the request the way a hand-driven animation can.
      ProgressView()
        .controlSize(.small)
        .tint(HCCTheme.Color.muted)
    } else {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tint)
    }
  }

  private var symbol: String {
    switch outcome {
    case .some(true): "checkmark"
    case .some(false): "exclamationmark.triangle"
    case nil: "arrow.clockwise"
    }
  }

  private var tint: Color {
    switch outcome {
    case .some(true): HCCTheme.Color.good
    case .some(false): HCCTheme.Color.warn
    case nil: HCCTheme.Color.text
    }
  }

  private var accessibilityValue: String {
    if isRunning { return "Syncing" }
    switch outcome {
    case .some(true): return "Synced"
    case .some(false): return "Sync had a problem"
    case nil: return "Idle"
    }
  }
}

/// `.devpill` — the driving device, its state dot, and its battery.
///
/// Several sources expose no battery at all (the read API returns null for
/// them by design), and the mockup has a specific rendering for that: the
/// device's NAME plus a dashed, empty battery outline. That is not a decorative
/// difference — it is the difference between "the battery is empty" and "this
/// device does not report one", and it is why no percentage is ever guessed.
struct HCCDevicePill: View {
  /// Already labelled through `HCCCopy`. `nil` when no device is on record.
  let label: String?
  /// 0–100, or `nil` when the source reports none.
  let batteryPercent: Double?
  let stateColor: Color
  let action: () -> Void

  var body: some View {
    // No background any more: the handoff puts the wearable's state on the
    // background itself — a 7-pt dot, the name in the state's own colour, and
    // the battery glyph. The dot's colour is the caller's (it is the connection
    // state), and the text now follows it so the two cannot disagree.
    Button(action: action) {
      HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 7, height: 7)
        if let batteryPercent {
          Text("\(Int(batteryPercent.rounded()))%")
            .font(HCCTheme.Font.data(size: 11, weight: .medium))
            .foregroundStyle(stateColor)
          HCCBatteryGlyph(fill: batteryPercent / 100)
        } else {
          Text(label ?? "No device")
            .font(HCCTheme.Font.data(size: 11, weight: .medium))
            .foregroundStyle(stateColor)
            .lineLimit(1)
          HCCBatteryGlyph(fill: nil)
        }
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Device")
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let batteryPercent else {
      return "\(label ?? "No device"), battery not reported"
    }
    return "\(label ?? "Device"), battery \(Int(batteryPercent.rounded())) percent"
  }
}

/// `.devpill .bat` — an 18×10 cell with a nub. A `nil` fill draws the dashed
/// outline that means "this device does not report a battery".
struct HCCBatteryGlyph: View {
  let fill: Double?

  var body: some View {
    HStack(spacing: 1) {
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .strokeBorder(
            HCCTheme.Color.muted,
            style: StrokeStyle(lineWidth: 1.5, dash: fill == nil ? [2, 2] : [])
          )
          .frame(width: 18, height: 10)
        if let fill {
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(HCCTheme.Color.good)
            .frame(width: 15 * CGFloat(min(max(fill, 0), 1)), height: 6)
            .padding(.leading, 1.5)
        }
      }
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(HCCTheme.Color.muted)
        .frame(width: 2, height: 4)
    }
  }
}

// ── Numerals ─────────────────────────────────────────────────────────────────

/// A number with its unit letters typeset smaller, from ONE already-formatted
/// string: "10:28 PM", "8h 07m", "52 bpm", "--".
///
/// The handoff prints the unit at a smaller size in a lighter colour, but this
/// screen only ever holds the finished string `HCCHomeView`'s formatting
/// helpers produced — the store does not hand the unit back separately. So the
/// split is made on the glyphs (letters and `%` are unit, everything else is
/// number) rather than by re-deriving a unit here, which would be a second
/// place a value could be invented. `--` carries no letters and stays `--`.
private struct HCCUnitNumeral: View {
  let text: String
  var size: CGFloat
  var tracking: CGFloat
  var color: Color = HCCTheme.Color.text
  var unitSize: CGFloat
  var unitColor: Color

  var body: some View {
    Text(styled)
      .tracking(tracking)
      .lineLimit(1)
      .minimumScaleFactor(0.6)
  }

  /// One `Text` with two runs of type in it, rather than two concatenated: a
  /// single line box, so the unit sits on the numeral's own baseline and the
  /// whole thing scales as one when the column is narrow.
  private var styled: AttributedString {
    var line = AttributedString()
    for segment in Self.segments(of: text) {
      var run = AttributedString(segment.text)
      if segment.isUnit {
        run.font = HCCTheme.Font.body(size: unitSize, weight: .semibold)
        run.foregroundColor = unitColor
      } else {
        run.font = HCCTheme.Font.display(size: size, weight: .semibold).monospacedDigit()
        run.foregroundColor = color
      }
      line.append(run)
    }
    return line
  }

  struct Segment {
    var text: String
    var isUnit: Bool
  }

  /// Runs of "this is the number" and "this is the unit", in order.
  static func segments(of text: String) -> [Segment] {
    var runs: [Segment] = []
    for character in text {
      let isUnit = character.isLetter || character == "%"
      if var last = runs.last, last.isUnit == isUnit {
        last.text.append(character)
        runs[runs.count - 1] = last
      } else {
        runs.append(Segment(text: String(character), isUnit: isUnit))
      }
    }
    return runs
  }
}

// ── Insight ──────────────────────────────────────────────────────────────────

/// `.ins` — the first open card, with the dismiss button and the remaining
/// count. The count is how many are OPEN, not how many are left after this one:
/// that is what the mockup shows, and it is the number the user is deciding
/// about when they look at the button.
struct HCCInsightCardView: View {
  let title: String
  let message: String
  /// The metric slugs (or kind) the card was written from. Never a claim of
  /// its own — just where to look.
  let source: String?
  let openCount: Int
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        // The handoff moves the source out from under the body and onto the
        // title line, as a chip in the recovery tint. Same string, same
        // meaning — where the card was written from.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(HCCTheme.Font.display(size: 16, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(HCCTheme.Color.text)
            .fixedSize(horizontal: false, vertical: true)
          if let source {
            Text(source)
              .font(HCCTheme.Font.data(size: 9.5))
              .tracking(0.4)
              .lineLimit(1)
              .foregroundStyle(HCCTheme.Color.recoveryText)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(HCCTheme.Color.recovery.opacity(0.16))
              )
          }
        }
        Text(message)
          .font(HCCTheme.Font.body(size: 14))
          .lineSpacing(3.6)
          .foregroundStyle(HCCTheme.Color.textBody)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: dismiss) {
        VStack(spacing: 4) {
          Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .semibold))
          Text("\(openCount)")
            .font(HCCTheme.Font.data(size: 11, weight: .medium))
        }
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 38)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(HCCTheme.Color.white(0.08))
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss insight")
      .accessibilityValue("\(openCount) open")
    }
  }
}

// ── Activities ───────────────────────────────────────────────────────────────

/// `.actv` — one activity: a 40-pt icon tile in the activity's colour, the
/// sport name over its clock window, and the number that matters for that kind.
struct HCCActivityRow: View {
  let systemImage: String
  /// Strain for a workout, hours slept for a night. "--" where the server has
  /// no number.
  let badgeText: String
  /// The handoff's small unit beside that number. `nil` where the screen has no
  /// unit to print — this row will not invent one.
  var badgeUnit: String?
  let name: String
  let startText: String
  let endText: String
  /// Sleep blue or strain indigo; the icon tile and the number take it.
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(.white)
          .frame(width: 40, height: 40)
          .background(
            RoundedRectangle(cornerRadius: HCCTheme.Radius.control, style: .continuous)
              // CSS `color-mix(in srgb, <tint> 55%, #123)` — the mock's own
              // `badgeBg`, which is the activity colour darkened enough to
              // carry a white glyph.
              .fill(tint.mix(with: HCCTheme.Color.hex(0x112233), by: 0.45, in: .device))
          )

        VStack(alignment: .leading, spacing: 3) {
          Text(name)
            .font(HCCTheme.Font.body(size: 14, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
            .lineLimit(1)
          Text("\(startText) – \(endText)")
            .font(HCCTheme.Font.data(size: 10.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(badgeText)
            .font(HCCTheme.Font.display(size: 22, weight: .semibold))
            .tracking(-0.5)
            .monospacedDigit()
            .foregroundStyle(tint)
          if let badgeUnit {
            Text(badgeUnit)
              .font(HCCTheme.Font.data(size: 9.5))
              .tracking(0.6)
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
        .lineLimit(1)
      }
      .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 12))
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.row, style: .continuous)
          .fill(HCCTheme.Color.card2)
      )
      .contentShape(RoundedRectangle(cornerRadius: HCCTheme.Radius.row, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}

// ── Tonight's sleep ──────────────────────────────────────────────────────────

/// `.sleep2` — the recommended bedtime, and what the server sized it against.
///
/// The mockup's second column was the alarm; it was removed 2026-09-03 (see
/// `HCCHomeView.tonightCard`) because the alarm can only ring on the phone and
/// does not earn a place on Home. Do not re-add it without a wearable that can
/// actually hold one.
struct HCCTonightSleepCard: View {
  let bedtime: String
  /// "7h 45m" — tonight's measured need, when the server has one.
  let need: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      column(value: bedtime, caption: "Recommended bedtime")
      column(
        value: need ?? "--",
        caption: need == nil ? "No sleep need yet" : "Tonight's sleep need"
      )
    }
  }

  private func column(value: String, caption: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HCCUnitNumeral(
        text: value,
        size: 28,
        tracking: -0.8,
        unitSize: 14,
        unitColor: HCCTheme.Color.sleepText
      )
      Text(caption)
        .font(HCCTheme.Font.body(size: 11.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// ── Dashboard tiles ──────────────────────────────────────────────────────────

/// Which way the number moved against the reference printed beneath it.
///
/// Direction only, and drawn MUTED for every direction.
///
/// The mockup colours ▲ green and ▼ warn, which works for its sample tile
/// (steps, where more is plainly better) and is wrong the moment the tile is
/// resting heart rate: 49 against a 50 baseline is a good morning, and an
/// orange ▼ next to it states a verdict the server never made. Colour would
/// have to come from the stream's own optimal band, and `/vitals` ships the
/// band's bounds without a direction — so until it says which way is better,
/// this says only which way the number moved.
enum HCCTileTrend {
  case up
  case down
  case flat
  case none

  var glyph: String? {
    switch self {
    case .up: "▲"
    case .down: "▼"
    case .flat: "●"
    case .none: nil
    }
  }

  var color: Color { HCCTheme.Color.muted }

  var fontSize: CGFloat {
    self == .flat ? 8 : 10
  }
}

/// `.tile` — one cell of the two-column dashboard grid: its label, the number
/// with its unit and trend, and the reference line the number is read against.
struct HCCDashboardTileRow: View {
  let label: String
  /// "--" wherever the server has no value. Never a zero standing in for one.
  let value: String
  let sub: String
  let trend: HCCTileTrend

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(HCCTheme.Font.body(size: 12, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        HCCUnitNumeral(
          text: value,
          size: 26,
          tracking: -0.7,
          unitSize: 12,
          unitColor: HCCTheme.Color.muted
        )
        if let glyph = trend.glyph {
          Text(glyph)
            .font(.system(size: trend.fontSize))
            .foregroundStyle(trend.color)
        }
      }
      Text(sub)
        .font(HCCTheme.Font.data(size: 10.5))
        .foregroundStyle(HCCTheme.Color.muted2)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .hccCard(
      radius: HCCTheme.Radius.tile,
      padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    )
    .accessibilityElement(children: .combine)
  }
}
