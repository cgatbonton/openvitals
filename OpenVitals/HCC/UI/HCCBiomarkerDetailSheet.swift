import SwiftUI

/// The phone's rendition of the web app's `MetricTooltip` — the card the web
/// shows when a biomarker row is hovered.
///
/// A hover has no phone equivalent, so the same content is presented as a sheet
/// off a tap. The content is the tooltip's, in the tooltip's order: the AI
/// insight first (it is the headline read), then the catalog blurb, then the
/// latest / comparison / optimal target / trend / history rows, then the
/// not-medical-advice line.
///
/// **It never grades anything.** `status`, `comparison` and `trend` are the
/// server's own sentences, computed against the app's OPTIMAL target — never a
/// lab reference range, which is not in this payload at all. The sheet repeats
/// the screen's footnote so "In range" cannot be misread as a lab range.
struct HCCBiomarkerDetailSheet: View {
  let metric: HCCMetricView

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HCCScreen {
      // No back chevron: this is a sheet, and "‹" would promise a screen behind
      // it that does not exist. The trailing action closes it, as the drag
      // indicator does.
      HCCDetailHeader(
        title: metric.displayName,
        subtitle: statusText,
        showsBack: false,
        actionTitle: "Close",
        action: { dismiss() }
      )

      insightCard

      if !metric.summary.isEmpty {
        Text(metric.summary)
          .font(HCCTheme.Font.body(size: 12.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .hccCard()
      }

      HCCKeyValueGrid(rows: rows).hccCard()

      HCCFootnote(
        "Targets are the optimal targets from your metric catalog, not lab reference ranges. "
          + "Informational only — not medical advice."
      )
    }
  }

  // ── The AI insight ─────────────────────────────────────────────────────────

  /// The accent-bordered block the web tooltip leads with. When there is no
  /// cached insight the web offers its "Generate AI insights" button; the phone
  /// has no such control, so it says where the insight comes from instead of
  /// pointing at a button that is not on this screen.
  @ViewBuilder
  private var insightCard: some View {
    if let insight = metric.aiInsight, !insight.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "sparkles")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.accent)
          HCCLabel("AI insight", color: HCCTheme.Color.accent)
          if metric.insightStale {
            Text("· new data — refresh")
              .font(HCCTheme.Font.body(size: 10))
              .foregroundStyle(HCCTheme.Color.warn)
          }
          Spacer(minLength: 0)
        }
        HCCMarkdown(text: insight)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .fill(HCCTheme.Color.accent.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: HCCTheme.Radius.card, style: .continuous)
          .strokeBorder(HCCTheme.Color.accent.opacity(0.25), lineWidth: 1)
      )
    } else {
      HCCEmptyNote("No personalized insight for this marker yet — they are generated in your Command Center.")
        .hccCard()
    }
  }

  // ── The stat rows ──────────────────────────────────────────────────────────

  private var rows: [HCCKeyValue] {
    var rows: [HCCKeyValue] = [
      HCCKeyValue("Latest", latestText),
      HCCKeyValue("Comparison", metric.comparison),
    ]
    if let target = Self.targetText(metric) {
      rows.append(HCCKeyValue("Optimal target", target))
    }
    if let trend = metric.trend, !trend.isEmpty {
      rows.append(HCCKeyValue("Trend", trend))
    }
    rows.append(HCCKeyValue("History", historyText))
    return rows
  }

  /// "88.0 mg/dL · 2026-09-03" — the web's own pairing of the value with the day
  /// it was drawn. The date is the server's ISO day, already in the instance's
  /// civil time; the phone does not re-derive it.
  private var latestText: String {
    let number = HCCFormat.decimal(metric.value, (metric.value.map { abs($0) >= 100 } ?? false) ? 0 : 1)
    let unit = (metric.unit?.isEmpty == false && metric.value != nil) ? " \(metric.unit!)" : ""
    return "\(number)\(unit) · \(metric.lastTestedISO.prefix(10))"
  }

  private var historyText: String {
    "\(metric.n) reading\(metric.n == 1 ? "" : "s") · last \(metric.ageText)"
  }

  private var statusText: String {
    switch metric.status {
    case "nominal": "In range"
    case "watch": "Watch"
    case "alert": "Out of range"
    default: "Unknown"
    }
  }

  /// The web tooltip's `fmtRange`: "70–90 mg/dL", "≤ 5.4 %", "≥ 600 ng/dL", and
  /// nil when the catalog gives this metric no bound at all — in which case the
  /// web omits the row rather than printing an empty target.
  static func targetText(_ metric: HCCMetricView) -> String? {
    let unit = metric.unit.map { $0.isEmpty ? "" : " \($0)" } ?? ""
    switch (metric.optimalLow, metric.optimalHigh) {
    case let (low?, high?): return "\(trimmed(low))–\(trimmed(high))\(unit)"
    case let (nil, high?): return "≤ \(trimmed(high))\(unit)"
    case let (low?, nil): return "≥ \(trimmed(low))\(unit)"
    default: return nil
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 10000
      ? String(format: "%.0f", value)
      : String(format: "%g", value)
  }
}
