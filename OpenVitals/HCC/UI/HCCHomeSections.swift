import SwiftUI

// The pieces of Home, one struct per block of the mockup's `S.home`.
//
// Same rule as `HCCComponents`: everything here takes already-resolved strings
// and fractions. Not one of these views reads the store, formats a metric or
// decides what a missing value looks like — `HCCHomeView` does that, once, so
// there is a single place where a "--" can be introduced and a single place to
// check that none was introduced dishonestly.

// ── Top bar ──────────────────────────────────────────────────────────────────

/// `.daynav` — `‹ TODAY ›`. Forward is disabled on today, because there is no
/// day after it to read.
struct HCCDayNav: View {
  let label: String
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      arrow("chevron.left", enabled: canGoBack, action: goBack)
        .accessibilityLabel("Previous day")
      Text(label)
        .font(HCCTheme.Font.body(size: 11, weight: .semibold))
        .tracking(1.32)
        .textCase(.uppercase)
        .foregroundStyle(HCCTheme.Color.text)
        .frame(minWidth: 74)
        .padding(.horizontal, 10)
        .lineLimit(1)
      arrow("chevron.right", enabled: canGoForward, action: goForward)
        .accessibilityLabel("Next day")
    }
    .padding(3)
    .background(Capsule().fill(HCCTheme.Color.card))
    .overlay(Capsule().strokeBorder(HCCTheme.Color.line, lineWidth: 1))
    .accessibilityElement(children: .contain)
    .accessibilityValue(label)
  }

  private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 28, height: 26)
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
        Circle().fill(HCCTheme.Color.card)
        Circle().strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        icon
      }
      .frame(width: 32, height: 32)
      .contentShape(Circle())
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
        .font(.system(size: 13, weight: .semibold))
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
    Button(action: action) {
      HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 8, height: 8)
        if let batteryPercent {
          Text("\(Int(batteryPercent.rounded()))%")
            .font(HCCTheme.Font.data(size: 11, weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
          HCCBatteryGlyph(fill: batteryPercent / 100)
        } else {
          Text(label ?? "No device")
            .font(HCCTheme.Font.data(size: 11, weight: .medium))
            .foregroundStyle(HCCTheme.Color.muted)
            .lineLimit(1)
          HCCBatteryGlyph(fill: nil)
        }
      }
      .padding(.leading, 10)
      .padding(.trailing, 8)
      .padding(.vertical, 5)
      .background(Capsule().fill(HCCTheme.Color.card))
      .overlay(Capsule().strokeBorder(HCCTheme.Color.line, lineWidth: 1))
      .contentShape(Capsule())
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
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(HCCTheme.Font.display(size: 15, weight: .medium))
          .tracking(-0.15)
          .foregroundStyle(HCCTheme.Color.text)
          .padding(.bottom, 4)
        Text(message)
          .font(HCCTheme.Font.body(size: 12.5))
          .lineSpacing(3.6)
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
        if let source {
          Text(source)
            .font(HCCTheme.Font.data(size: 10))
            .tracking(0.4)
            .foregroundStyle(HCCTheme.Color.muted)
            .padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
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
        .frame(width: 34)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HCCTheme.Color.card2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss insight")
      .accessibilityValue("\(openCount) open")
    }
  }
}

// ── Activities ───────────────────────────────────────────────────────────────

/// `.actv` — one activity: a tinted badge with the sport icon and the number
/// that matters for that kind, the sport name, the clock window, and a colour
/// rail.
struct HCCActivityRow: View {
  let systemImage: String
  /// Strain for a workout, hours slept for a night. "--" where the server has
  /// no number.
  let badgeText: String
  let name: String
  let startText: String
  let endText: String
  /// Sleep blue or strain cyan; the badge fill and the rail take it.
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        HStack(spacing: 5) {
          Image(systemName: systemImage)
            .font(.system(size: 14, weight: .regular))
          Text(badgeText)
            .font(HCCTheme.Font.data(size: 15, weight: .medium))
            .monospacedDigit()
        }
        .foregroundStyle(.white)
        .frame(width: 74, height: 44)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            // CSS `color-mix(in srgb, <tint> 55%, #123)`.
            .fill(tint.mix(with: HCCTheme.Color.hex(0x112233), by: 0.45, in: .device))
        )

        Text(name)
          .font(HCCTheme.Font.body(size: 12, weight: .semibold))
          .tracking(1.2)
          .textCase(.uppercase)
          .foregroundStyle(HCCTheme.Color.text)
          .lineLimit(2)

        Spacer(minLength: 6)

        VStack(alignment: .trailing, spacing: 2) {
          Text(startText)
          Text(endText)
        }
        .font(HCCTheme.Font.data(size: 10.5))
        .foregroundStyle(HCCTheme.Color.muted)
        .lineLimit(1)

        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(tint)
          .frame(width: 3, height: 36)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HCCTheme.Color.card2)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    HStack(alignment: .top, spacing: 8) {
      column(
        value: bedtime,
        lines: ["Recommended", "bedtime"],
        color: HCCTheme.Color.muted
      )
      Text("— — —")
        .font(HCCTheme.Font.body(size: 12))
        .tracking(2)
        .foregroundStyle(HCCTheme.Color.line)
        .padding(.top, 8)
      column(
        value: need ?? "--",
        lines: need == nil ? ["No sleep need", "yet"] : ["Tonight's", "sleep need"],
        color: HCCTheme.Color.muted
      )
    }
    .padding(.top, 6)
    .padding(.bottom, 10)
  }

  private func column(value: String, lines: [String], color: Color) -> some View {
    VStack(spacing: 4) {
      Text(value)
        .font(HCCTheme.Font.display(size: 26, weight: .medium))
        .tracking(-0.52)
        .monospacedDigit()
        .foregroundStyle(HCCTheme.Color.text)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      VStack(spacing: 2) {
        ForEach(lines, id: \.self) { line in
          Text(line)
            .hccLabelStyle(size: 9.5, color: color)
        }
      }
      .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
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

/// `.tile` — a small-caps label on the left, a big number and its reference
/// line on the right.
struct HCCDashboardTileRow: View {
  let label: String
  /// "--" wherever the server has no value. Never a zero standing in for one.
  let value: String
  let sub: String
  let trend: HCCTileTrend

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Text(label)
        .font(HCCTheme.Font.body(size: 11.5, weight: .semibold))
        .tracking(1.15)
        .textCase(.uppercase)
        .foregroundStyle(HCCTheme.Color.text)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(value)
            .font(HCCTheme.Font.display(size: 24, weight: .medium))
            .tracking(-0.48)
            .monospacedDigit()
            .foregroundStyle(HCCTheme.Color.text)
          if let glyph = trend.glyph {
            Text(glyph)
              .font(.system(size: trend.fontSize))
              .foregroundStyle(trend.color)
          }
        }
        Text(sub)
          .font(HCCTheme.Font.data(size: 10.5))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      .lineLimit(1)
    }
    .hccCard()
    .accessibilityElement(children: .combine)
  }
}
