import SwiftUI

// `S.insights` — the phone's copy of the web app's /insights page.
//
// REBUILT 2026-09-03 (Chris: "the insights page should match the insights page
// from the web app"). It reads the same two feeds the web page reads and lays
// them out in the same order, with the same rules:
//
//  * **The weekly log is FIRST**, then the insights. The web page's own order,
//    and it is the right one: the week in review is the thing that changed
//    since last time.
//  * **Statuses shown are ACTIVE and RESOLVED**, resolved dimmed. Acknowledged
//    and dismissed rows stay in the table for the memory feedback loop and are
//    NOT surfaced — matching `SHOWN_STATUSES` on the web page.
//  * **No acknowledge or dismiss buttons.** The web page deliberately has none:
//    a status change happens in chat, where the reason can be captured. The ✓
//    that used to live on this screen wrote ACKNOWLEDGED with no reason, so it
//    is gone. Home's card keeps its own dismiss — that is a different surface.
//  * **Plain English, in full.** The card renders `summary`, then "The plan",
//    with reasoning/body/related metrics behind a disclosure — not a truncated
//    excerpt. Markdown goes through `HCCMarkdown` rather than being flattened.
//
// Everything on it is the server's. Nothing here re-derives a week boundary, a
// severity or a status word.

struct HCCInsightsView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var cards = HCCPageLoad<HCCInsightsResponse>()
  @StateObject private var weekly = HCCPageLoad<HCCWeeklyInsightsResponse>()

  /// The web page's `WEEKLY_LOG_ROWS`. The endpoint caps at 52.
  private static let weeklyRows = 25

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Insights", subtitle: "What the system has surfaced")

      HCCFootnote("A week-by-week log on top, and the open insights underneath — each in plain words, with the plan to deal with it.")

      weeklySection
      insightsSection
    }
    .task {
      await cards.loadIfNeeded { try await HCCSession.shared.client.insights(status: "all", limit: 100) }
    }
    .task {
      await weekly.loadIfNeeded {
        try await HCCSession.shared.client.weeklyInsights(limit: Self.weeklyRows)
      }
    }
  }

  // ── Section 1: the weekly log ──────────────────────────────────────────────

  @ViewBuilder
  private var weeklySection: some View {
    HCCSectionHeader(title: "Weekly log")
    HCCFootnote("Written each week for the seven days just closed: sleep, recovery, load, body composition, labs, and how the running protocols look.")

    if weekly.isPending {
      HCCLoadingNote(text: "Loading the weekly log...").hccCard()
    } else if let error = weekly.errorText {
      HCCErrorNote(error) {
        await weekly.reload { try await HCCSession.shared.client.weeklyInsights(limit: Self.weeklyRows) }
      }
    } else if let rows = weekly.value?.rows, !rows.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          WeeklyLogRow(row: row, showsDivider: index < rows.count - 1)
        }
      }
      .hccCard()
    } else {
      HCCEmptyNote("No weekly entries yet. One is written for each week just closed.")
        .hccCard()
    }
  }

  // ── Section 2: the insights ────────────────────────────────────────────────

  /// ACTIVE first, then RESOLVED — the server's own `status asc, severity desc,
  /// createdAt desc` ordering already puts them that way, so the list is only
  /// filtered here, never re-sorted.
  private var shown: [HCCInsightCard] {
    (cards.value?.insights ?? []).filter { $0.status == "ACTIVE" || $0.status == "RESOLVED" }
  }

  @ViewBuilder
  private var insightsSection: some View {
    HCCSectionHeader(title: "Insights & flags")
    HCCFootnote("What is going on and why it matters, with the plan for each. Resolved ones stay listed, dimmed.")

    if cards.isPending {
      HCCLoadingNote().hccCard()
    } else if let error = cards.errorText {
      HCCErrorNote(error) {
        await cards.reload { try await HCCSession.shared.client.insights(status: "all", limit: 100) }
      }
    } else if shown.isEmpty {
      HCCEmptyNote("No insights yet. They appear as analyses run over your data.")
        .hccCard()
    } else {
      ForEach(shown) { card in
        InsightCardView(card: card)
      }
    }
  }

  // ── Formatting ─────────────────────────────────────────────────────────────

  /// "Aug 23 – Aug 29, 2026" from the two civil day keys, which are the
  /// server's week boundaries and are never re-derived here.
  ///
  /// Both halves format in the INSTANCE zone: `hccLocalDate` hands back that
  /// zone's midnight, and rendering it through the device calendar would slide
  /// the label a day for anyone west of the instance.
  static func weekRange(_ insight: HCCWeeklyInsight) -> String {
    let calendar = HealthDataStore.hccInstanceCalendar
    guard let start = HealthDataStore.hccLocalDate(fromDayKey: insight.startDayKey),
          let end = HealthDataStore.hccLocalDate(fromDayKey: insight.endDayKey)
    else { return "\(insight.startDayKey) – \(insight.endDayKey)" }
    let crossesYear = calendar.component(.year, from: start) != calendar.component(.year, from: end)
    return "\(day(start, withYear: crossesYear)) – \(day(end, withYear: true))"
  }

  /// "Sep 3, 2026" from an ISO instant. Nil rather than a guessed date when the
  /// server's stamp does not parse.
  static func stamp(_ iso: String) -> String? {
    HCCTime.instant(iso).map { day($0, withYear: true) }
  }

  private static func day(_ date: Date, withYear: Bool) -> String {
    var style = withYear
      ? Date.FormatStyle.dateTime.month(.abbreviated).day().year()
      : Date.FormatStyle.dateTime.month(.abbreviated).day()
    style.timeZone = HealthDataStore.hccInstanceTimeZone
    return date.formatted(style)
  }
}

// ── Weekly row ───────────────────────────────────────────────────────────────

/// One collapsed week, expanding to its highlights and the full entry — the
/// web page's `<details>` row.
private struct WeeklyLogRow: View {
  let row: HCCWeeklyInsight
  let showsDivider: Bool

  @State private var isOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { isOpen.toggle() }
      } label: {
        HStack(alignment: .top, spacing: 9) {
          Text("▶")
            .font(HCCTheme.Font.body(size: 9))
            .foregroundStyle(HCCTheme.Color.muted)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .padding(.top, 3)

          VStack(alignment: .leading, spacing: 5) {
            Text(HCCInsightsView.weekRange(row))
              .font(HCCTheme.Font.data(size: 10.5))
              .foregroundStyle(HCCTheme.Color.muted)
            Text(row.headline)
              .font(HCCTheme.Font.display(size: 13.5, weight: .medium))
              .foregroundStyle(HCCTheme.Color.text)
              .fixedSize(horizontal: false, vertical: true)
              .multilineTextAlignment(.leading)
            if !chips.isEmpty { chipRow }
          }
          Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      // An empty week is dimmed, but only when it holds NEITHER wearable
      // metrics nor readings — a labs-only week is a real week.
      .opacity(isEmptyWeek ? 0.6 : 1)

      if isOpen { expanded }
      if showsDivider { HCCDivider() }
    }
  }

  private var chipRow: some View {
    // Wraps rather than scrolls: a clipped fifth number on a phone reads as
    // "there are four", which is a different claim.
    HCCFlowRow(spacing: 12, lineSpacing: 4) {
      ForEach(chips, id: \.label) { chip in
        HStack(spacing: 5) {
          HCCStatusDot(status: chip.status)
          Text(chip.label)
            .font(HCCTheme.Font.body(size: 10.5))
            .foregroundStyle(HCCTheme.Color.muted)
          Text(chip.value)
            .font(HCCTheme.Font.data(size: 10.5))
            .foregroundStyle(HCCTheme.Color.text)
          if let delta = chip.delta {
            Text("(\(delta))")
              .font(HCCTheme.Font.data(size: 10.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var expanded: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !highlights.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(highlights.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .firstTextBaseline, spacing: 7) {
              Text("•").foregroundStyle(HCCTheme.Color.accent)
              Text(line)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(HCCTheme.Color.text)
            }
            .font(HCCTheme.Font.body(size: 12.5))
          }
        }
      }
      HCCMarkdown(text: row.summary, color: HCCTheme.Color.muted)
      Text(writtenLine)
        .font(HCCTheme.Font.body(size: 10.5))
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .padding(.leading, 18)
    .padding(.bottom, 12)
  }

  // ── The stats JSON ─────────────────────────────────────────────────────────

  private struct Chip {
    let label: String
    let value: String
    let delta: String?
    let status: String?
  }

  /// The same five the web log shows, each naming the device slug and the
  /// computed one for the same thing; whichever the week has is the one drawn,
  /// so the log follows a device switch by itself. Units come from the metric's
  /// own `unit` — they differ between instances and are never hardcoded.
  private static let chipSlugs: [(label: String, slugs: [String])] = [
    ("Recovery", ["whoop_recovery", "hcc_recovery"]),
    ("HRV", ["hrv_sdnn"]),
    ("RHR", ["resting_hr"]),
    ("Sleep", ["sleep_duration"]),
    ("Weight", ["weight"]),
  ]

  private var metrics: [HCCJSONValue] { row.stats?["metrics"]?.arrayValue ?? [] }

  private var highlights: [String] {
    (row.stats?["highlights"]?.arrayValue ?? []).compactMap { $0.stringValue }
  }

  private var labsCount: Int { (row.stats?["labs"]?.arrayValue ?? []).count }

  private var isEmptyWeek: Bool { row.metricsCount == 0 && labsCount == 0 }

  private var chips: [Chip] {
    Self.chipSlugs.compactMap { entry in
      guard let metric = entry.slugs.lazy
        .compactMap({ slug in metrics.first { $0["slug"]?.stringValue == slug } })
        .first,
        let mean = metric["mean"]?.doubleValue
      else { return nil }
      return Chip(
        label: entry.label,
        value: Self.withUnit(Self.number(mean), metric["unit"]?.stringValue),
        delta: metric["delta"]?.doubleValue.map { "\($0 > 0 ? "+" : "")\(Self.number($0))" },
        status: metric["status"]?.stringValue
      )
    }
  }

  private var writtenLine: String {
    let written = HCCInsightsView.stamp(row.createdAt).map { "Written \($0)" } ?? "Written"
    if row.metricsCount > 0 { return "\(written) · \(row.metricsCount) metrics with data" }
    if labsCount > 0 {
      return "\(written) · \(labsCount) reading\(labsCount == 1 ? "" : "s"), no wearable data"
    }
    return "\(written) · no data in window"
  }

  private static func number(_ value: Double) -> String {
    String(format: abs(value) >= 100 ? "%.0f" : "%.1f", value)
  }

  /// "62%" and "98.1°F" close up; "62 ms", "184 lb", "7.4 h" take a space —
  /// the web log's own rule.
  private static func withUnit(_ value: String, _ unit: String?) -> String {
    guard let unit, !unit.isEmpty else { return value }
    let letter = unit.first.map { $0.isLetter } ?? false
    return letter ? "\(value) \(unit)" : "\(value)\(unit)"
  }
}

// ── Insight card ─────────────────────────────────────────────────────────────

/// The web page's insight panel: the status dot and badges, the narrative, the
/// plan, and the technical detail one tap away.
private struct InsightCardView: View {
  let card: HCCInsightCard

  @State private var showsDetail = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HCCStatusDot(status: Self.dotStatus(card.severity), size: 7)
        .padding(.top, 6)

      VStack(alignment: .leading, spacing: 6) {
        Text(card.title)
          .font(HCCTheme.Font.display(size: 15, weight: .medium))
          .tracking(-0.15)
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)

        HCCFlowRow(spacing: 6, lineSpacing: 5) {
          HCCPill(Self.kindLabel(card.kind), tone: Self.kindTone(card.kind))
          HCCPill(card.severity, tone: Self.severityTone(card.severity))
          if let grade = card.evidenceGrade {
            HCCPill(grade, tone: .muted)
          }
        }

        HCCMarkdown(text: card.summary)

        planBlock

        if hasDetail { detailDisclosure }

        Text(footer)
          .font(HCCTheme.Font.body(size: 10.5))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      Spacer(minLength: 0)
    }
    .hccCard()
    // Resolved cards stay listed, dimmed — they are the record of what was
    // closed out as right, not clutter to hide.
    .opacity(card.status == "ACTIVE" ? 1 : 0.6)
  }

  @ViewBuilder
  private var planBlock: some View {
    if let plan = card.plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        HCCLabel("The plan", size: 10, color: HCCTheme.Color.accent)
        HCCMarkdown(text: plan, color: HCCTheme.Color.muted)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(HCCTheme.Color.accent.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(HCCTheme.Color.accent.opacity(0.25), lineWidth: 1)
      )
    } else {
      Text("No plan recorded for this one yet.")
        .font(HCCTheme.Font.body(size: 11))
        .italic()
        .foregroundStyle(HCCTheme.Color.muted)
    }
  }

  private var hasDetail: Bool {
    card.reasoning?.isEmpty == false || card.body?.isEmpty == false || !card.relatedMetricSlugs.isEmpty
  }

  @ViewBuilder
  private var detailDisclosure: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { showsDetail.toggle() }
      } label: {
        HStack(spacing: 5) {
          Text("▶")
            .font(HCCTheme.Font.body(size: 9))
            .rotationEffect(.degrees(showsDetail ? 90 : 0))
          Text("The detail behind it")
            .font(HCCTheme.Font.body(size: 11))
        }
        .foregroundStyle(HCCTheme.Color.muted)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showsDetail {
        VStack(alignment: .leading, spacing: 7) {
          if let reasoning = card.reasoning, !reasoning.isEmpty {
            HCCMarkdown(text: reasoning, size: 12, color: HCCTheme.Color.muted)
          }
          if let body = card.body, !body.isEmpty {
            HCCMarkdown(text: body, size: 12, color: HCCTheme.Color.muted)
          }
          if !card.relatedMetricSlugs.isEmpty {
            HCCFlowRow(spacing: 5, lineSpacing: 5) {
              ForEach(card.relatedMetricSlugs, id: \.self) { slug in
                HCCPill(slug, tone: .muted)
              }
            }
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(HCCTheme.Color.card2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
      }
    }
  }

  /// "Sep 3, 2026 · resolved · outcome: …" — each clause present only when the
  /// server sent the thing behind it.
  private var footer: String {
    var parts = [HCCInsightsView.stamp(card.createdAt)].compactMap { $0 }
    if card.status == "RESOLVED" { parts.append("resolved") }
    if let outcome = card.outcome, !outcome.isEmpty { parts.append("outcome: \(outcome)") }
    return parts.joined(separator: " · ")
  }

  // ── The web page's own maps ────────────────────────────────────────────────

  private static func kindLabel(_ kind: String) -> String {
    switch kind {
    case "RISK_FLAG": "Risk"
    case "SAFETY": "Safety"
    case "TREND": "Trend"
    case "RECOMMENDATION": "Recommendation"
    case "INSIGHT": "Insight"
    case "REVIEW": "Review"
    default: kind
    }
  }

  private static func kindTone(_ kind: String) -> HCCPill.Tone {
    switch kind {
    case "RISK_FLAG", "SAFETY": .bad
    case "TREND": .warn
    case "RECOMMENDATION": .accent
    case "INSIGHT": .good
    default: .muted
    }
  }

  private static func severityTone(_ severity: String) -> HCCPill.Tone {
    switch severity {
    case "CRITICAL", "HIGH": .bad
    case "MEDIUM": .warn
    default: .muted
    }
  }

  /// The web page's dot rule: severity, not status.
  private static func dotStatus(_ severity: String) -> String {
    switch severity {
    case "CRITICAL", "HIGH": "alert"
    case "MEDIUM": "watch"
    default: "nominal"
    }
  }
}
