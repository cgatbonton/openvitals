import SwiftUI
import WidgetKit

// The three Command Center widgets.
//
// None of them fetches anything. A widget process is woken with no session and
// a few hundred milliseconds of budget, so the app writes `summary.json` into
// the shared App Group container after every read and these draw whatever is in
// that file. The consequence is stated on the widget itself: the timestamp line
// is when the APP last refreshed, never "now".
//
// A missing value is `--` plus the server's own reason. Never 0, never a stale
// number redrawn as if it were current.

// ── Timeline ─────────────────────────────────────────────────────────────────

struct HCCSummaryEntry: TimelineEntry {
  let date: Date
  let summary: HCCWidgetSummary?
}

struct HCCSummaryProvider: TimelineProvider {
  func placeholder(in context: Context) -> HCCSummaryEntry {
    HCCSummaryEntry(date: Date(), summary: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (HCCSummaryEntry) -> Void) {
    completion(HCCSummaryEntry(date: Date(), summary: HCCWidgetStore.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<HCCSummaryEntry>) -> Void) {
    let entry = HCCSummaryEntry(date: Date(), summary: HCCWidgetStore.read())
    // One entry, refreshed on the hour. The app reloads timelines itself after
    // every read and after every silent push, so this is only the floor for a
    // phone that has not opened the app in a while.
    let next = Date().addingTimeInterval(60 * 60)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }
}

// ── Home screen ──────────────────────────────────────────────────────────────

struct HCCHomeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "HCCHomeWidget", provider: HCCSummaryProvider()) { entry in
      HCCHomeWidgetView(entry: entry)
        .containerBackground(HCCWidgetTheme.bg, for: .widget)
    }
    .configurationDisplayName("Command Center")
    .description("Sleep, recovery and strain from your command center.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private struct HCCHomeWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: HCCSummaryEntry

  private var summary: HCCWidgetSummary? { entry.summary }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text(dayLabel)
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .tracking(1.2)
          .foregroundStyle(HCCWidgetTheme.muted)
        Spacer(minLength: 0)
        if let updatedAt = summary?.updatedAt {
          Text(updatedAt, style: .time)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(HCCWidgetTheme.muted)
        }
      }

      HStack(spacing: family == .systemMedium ? 18 : 8) {
        ring(
          label: "Sleep",
          value: summary?.sleep.map { "\($0)" },
          unit: "%",
          progress: summary?.sleep.map { Double($0) / 100 },
          colors: HCCWidgetTheme.sleepRing
        )
        ring(
          label: "Recovery",
          value: summary?.recovery.map { "\($0)" },
          unit: "%",
          progress: summary?.recovery.map { Double($0) / 100 },
          colors: HCCWidgetTheme.recoveryRing(band: summary?.recoveryBand)
        )
        ring(
          label: "Strain",
          value: summary?.strain.map { String(format: "%.1f", $0) },
          unit: nil,
          progress: summary?.strain.map { $0 / 21 },
          colors: HCCWidgetTheme.strainRing,
          target: summary?.strainTarget.map { $0 / 21 }
        )
        if family == .systemMedium { Spacer(minLength: 0) }
      }

      if family == .systemMedium {
        Text(vitalsLine)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(HCCWidgetTheme.muted)
          .lineLimit(1)
      }

      if let note {
        Text(note)
          .font(.system(size: 9.5))
          .foregroundStyle(HCCWidgetTheme.muted)
          .lineLimit(family == .systemMedium ? 2 : 1)
      }
      Spacer(minLength: 0)
    }
  }

  private func ring(
    label: String,
    value: String?,
    unit: String?,
    progress: Double?,
    colors: (Color, Color),
    target: Double? = nil
  ) -> some View {
    VStack(spacing: 4) {
      HCCWidgetRing(
        progress: progress,
        colors: colors,
        size: family == .systemMedium ? 58 : 44,
        stroke: family == .systemMedium ? 6 : 5,
        value: value,
        unit: unit,
        target: target
      )
      Text(label)
        .font(.system(size: 9, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.9)
        .foregroundStyle(HCCWidgetTheme.muted)
    }
  }

  private var dayLabel: String {
    summary?.day ?? "No reading"
  }

  /// "HRV 64 · RHR 51", or `--` for whichever the server has not sent.
  private var vitalsLine: String {
    let hrv = summary?.hrv.map { String(format: "%.0f", $0) } ?? HCCWidgetTheme.placeholder
    let rhr = summary?.rhr.map { String(format: "%.0f", $0) } ?? HCCWidgetTheme.placeholder
    return "HRV \(hrv) · RHR \(rhr)"
  }

  private var note: String? {
    guard let summary else { return "Open the app to load your latest reading." }
    return summary.reason
  }
}

// ── Lock screen ──────────────────────────────────────────────────────────────

struct HCCRecoveryGaugeWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "HCCRecoveryGaugeWidget", provider: HCCSummaryProvider()) { entry in
      HCCRecoveryGaugeView(entry: entry)
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Recovery")
    .description("Today's recovery from your command center.")
    .supportedFamilies([.accessoryCircular])
  }
}

private struct HCCRecoveryGaugeView: View {
  let entry: HCCSummaryEntry

  var body: some View {
    // The lock screen renders accessories in a single tint, so the recovery
    // band's colour cannot carry the reading here — the word does not fit
    // either, so this shows the number and nothing that could be mistaken for
    // a band.
    Gauge(value: fraction) {
      Text("REC")
    } currentValueLabel: {
      Text(entry.summary?.recovery.map { "\($0)" } ?? HCCWidgetTheme.placeholder)
    }
    .gaugeStyle(.accessoryCircularCapacity)
  }

  /// An empty gauge for a missing score, so the ring cannot read as a low one.
  private var fraction: Double {
    guard let recovery = entry.summary?.recovery else { return 0 }
    return min(max(Double(recovery) / 100, 0), 1)
  }
}

struct HCCScoresRectangularWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "HCCScoresRectangularWidget", provider: HCCSummaryProvider()) { entry in
      HCCScoresRectangularView(entry: entry)
        .containerBackground(.clear, for: .widget)
    }
    .configurationDisplayName("Scores")
    .description("Sleep, recovery and strain on one line each.")
    .supportedFamilies([.accessoryRectangular])
  }
}

private struct HCCScoresRectangularView: View {
  let entry: HCCSummaryEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      row("Sleep", entry.summary?.sleep.map { "\($0)%" })
      row("Recovery", entry.summary?.recovery.map { "\($0)%" })
      row("Strain", entry.summary?.strain.map { String(format: "%.1f", $0) })
    }
    .privacySensitive()
  }

  private func row(_ label: String, _ value: String?) -> some View {
    HStack(spacing: 4) {
      Text(label)
        .font(.system(size: 12))
      Spacer(minLength: 4)
      Text(value ?? HCCWidgetTheme.placeholder)
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }
  }
}
