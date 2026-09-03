import SwiftUI

// The controls the "C · Command" secondary screens add on top of the shared
// design system, plus the wall-clock arithmetic they need.
//
// The header bar, the screen scaffold and the muted footnote are NOT here: they
// are `HCCDetailHeader`, `HCCScreen` and `HCCFootnote` in the detail
// workstream's files, and these screens use those rather than growing a second
// set with the same job. What is left is the three controls the mockup uses
// only on Add activity, Alarm, Devices and Customize — `.field`, `.seg` and
// `.zones` — and one enum of time helpers.
//
// Everything is presentation only, exactly like `HCCComponents.swift`: nothing
// in this file formats a metric, decides a band, or invents a value.

// ── Rows and controls ────────────────────────────────────────────────────────

/// `.field` — a label on the left and an accent, data-font value on the right,
/// over a hairline. The trailing side is a view so a picker or a text field can
/// sit where the mockup shows a value.
struct HCCFieldRow<Trailing: View>: View {
  let title: String
  var showsDivider: Bool = true
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(title)
          .font(HCCTheme.Font.body(size: 13.5))
          .foregroundStyle(HCCTheme.Color.text)
        Spacer(minLength: 8)
        trailing()
      }
      .padding(.vertical, 11)
      if showsDivider { HCCDivider() }
    }
  }
}

extension HCCFieldRow where Trailing == HCCFieldValue {
  init(title: String, value: String, showsDivider: Bool = true) {
    self.init(title: title, showsDivider: showsDivider) { HCCFieldValue(value) }
  }
}

/// `.field .val` — the accent, monospaced right-hand value.
struct HCCFieldValue: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(HCCTheme.Font.data(size: 12.5))
      .foregroundStyle(HCCTheme.Color.accent)
      .multilineTextAlignment(.trailing)
      .lineLimit(2)
  }
}

/// `.seg` — a two-or-more-way segmented control drawn to the mockup rather than
/// using `Picker(.segmented)`, whose look is fixed by UIKit.
struct HCCSegmentedControl<Value: Hashable>: View {
  struct Option: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
  }

  let options: [Option]
  @Binding var selection: Value

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options) { option in
        let isOn = option.value == selection
        Text(option.title)
          .font(HCCTheme.Font.body(size: 10.5, weight: .semibold))
          .tracking(0.63)
          .textCase(.uppercase)
          .foregroundStyle(isOn ? HCCTheme.Color.bg : HCCTheme.Color.muted)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .padding(.horizontal, 4)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(isOn ? HCCTheme.Color.accent : Color.clear)
          )
          .contentShape(Rectangle())
          .onTapGesture { selection = option.value }
          .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(HCCTheme.Color.card2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
    )
    .padding(.vertical, 8)
  }
}

/// `.zones` — one row per heart-rate zone: the label, a bar whose width is the
/// zone's share of the LARGEST zone (the mockup's `mins[i]/max`), and minutes.
///
/// It draws the minutes it is handed. A zone the server reported as zero draws
/// as zero; nothing here fills an empty array with a shape.
struct HCCZoneBars: View {
  /// Minutes in Z1…Z5, in order.
  let minutes: [Double]
  /// The zone currently being trained, 1-based. `nil` outside a live session.
  var current: Int?

  var body: some View {
    let peak = max(minutes.max() ?? 0, 1)
    VStack(spacing: 6) {
      ForEach(Array(minutes.prefix(5).enumerated()), id: \.offset) { index, value in
        let isCurrent = current.map { $0 - 1 == index } ?? false
        HStack(spacing: 8) {
          Text("Z\(index + 1)")
            .frame(width: 32, alignment: .leading)
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HCCTheme.Color.line)
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HCCTheme.Color.zone(index + 1))
                .frame(width: proxy.size.width * CGFloat(min(max(value / peak, 0), 1)))
            }
            .overlay {
              if isCurrent {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .strokeBorder(HCCTheme.Color.text, lineWidth: 1.5)
              }
            }
          }
          .frame(height: 14)
          Text("\(Int(value.rounded())) min")
            .frame(width: 46, alignment: .trailing)
        }
        .font(HCCTheme.Font.data(size: 11, weight: .medium))
        .foregroundStyle(isCurrent ? HCCTheme.Color.text : HCCTheme.Color.muted)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// A −/value/+ control sized for a `.field` row.
///
/// `Stepper` is not used: its system look does not belong on these cards, and
/// the mockup shows the value between the two controls rather than beside them.
struct HCCStepper: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  var step: Int = 1
  var suffix: String = ""

  var body: some View {
    HStack(spacing: 8) {
      button("minus", enabled: value - step >= range.lowerBound) {
        value = max(range.lowerBound, value - step)
      }
      Text(suffix.isEmpty ? "\(value)" : "\(value) \(suffix)")
        .font(HCCTheme.Font.data(size: 12.5))
        .monospacedDigit()
        .foregroundStyle(HCCTheme.Color.accent)
        .frame(minWidth: 54, alignment: .trailing)
      button("plus", enabled: value + step <= range.upperBound) {
        value = min(range.upperBound, value + step)
      }
    }
  }

  private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 26, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(HCCTheme.Color.card2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.4)
    .accessibilityLabel(symbol == "minus" ? "Decrease" : "Increase")
  }
}

// ── Time ─────────────────────────────────────────────────────────────────────

/// The clock arithmetic these screens need on top of `HCCTime`'s ISO parsing.
///
/// Two rules, both load-bearing:
///
///  * The alarm is a WALL CLOCK in the instance's timezone (`HH:MM`), not an
///    instant — that is what the server stores and what the phone will schedule.
///    It is never routed through the device's timezone.
///  * An instant the server sends (a bedtime, an activity's start) is rendered
///    in the INSTANCE's timezone, so a phone that is travelling still shows the
///    same clock face the web app does. `HCCFormat.clock` renders in the
///    DEVICE's zone, which is right for the screens that pair a time with the
///    phone's own day and wrong for these.
enum HCCWallClock {
  /// "9:29 a.m." — the mockup's clock style, in the given zone.
  static func clock(_ date: Date, timezone: String?) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
      .replacingOccurrences(of: "AM", with: "a.m.")
      .replacingOccurrences(of: "PM", with: "p.m.")
  }

  /// The same, from an ISO instant. `nil` when the string will not parse — the
  /// caller shows "--" rather than a guess.
  static func clock(iso: String?, timezone: String?) -> String? {
    HCCTime.instant(iso).map { clock($0, timezone: timezone) }
  }

  /// `"06:30"` → `("6:30", "a.m.")` for the big `.timepick` display. Returns
  /// nil for a string the server contract says cannot occur, rather than
  /// printing a half-parsed time.
  static func split(_ hhmm: String) -> (time: String, suffix: String)? {
    guard let total = minutes(from: hhmm) else { return nil }
    let hour = total / 60
    let minute = total % 60
    let suffix = hour < 12 ? "a.m." : "p.m."
    let display = hour % 12 == 0 ? 12 : hour % 12
    return (String(format: "%d:%02d", display, minute), suffix)
  }

  /// `"06:30"` → minutes since midnight, for the wheel picker's date proxy.
  static func minutes(from hhmm: String) -> Int? {
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0...23).contains(hour), (0...59).contains(minute)
    else { return nil }
    return hour * 60 + minute
  }

  static func hhmm(fromMinutes total: Int) -> String {
    let wrapped = ((total % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
  }

  /// "1h 12m" from minutes — `HCCFormat.hours` in the units the activity rows
  /// carry.
  static func duration(minutes total: Double) -> String {
    HCCFormat.hours(total / 60)
  }
}
