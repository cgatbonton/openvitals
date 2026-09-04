import SwiftUI

/// `S.biomarkers` — the lab panels, grouped by category.
///
/// Every target on this screen is the app's OPTIMAL target (`optimalLow` /
/// `optimalHigh`, which the server derives from the metric catalog). A lab's own
/// reference range is not in this payload and is never shown: a value inside a
/// lab range but outside the optimal target is below/above target, not "normal".
/// The dot colour comes from the server's `status`, which is graded on the same
/// basis — this screen does not re-grade anything itself.
struct HCCBiomarkersView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var load = HCCPageLoad<HCCBiomarkerPanels>()

  /// The row whose detail sheet is open. The web shows this content on hover;
  /// a phone has no hover, so the same card is presented off a tap.
  @State private var selected: HCCMetricView?

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Biomarkers", subtitle: subtitle)

      if let panels = load.value {
        if panels.panels.isEmpty {
          HCCEmptyNote("No lab panels on record for this instance.")
            .hccCard()
        } else {
          ForEach(panels.panels) { panel in
            panelCard(panel)
          }
          HCCFootnote(
            "Tap a marker for its insight and how the number compares. Targets are the optimal "
              + "targets from your metric catalog, not lab reference ranges."
          )
        }
      } else if let error = load.errorText {
        HCCErrorNote(error) { await load.reload { try await HCCSession.shared.client.biomarkers() } }
      } else {
        HCCLoadingNote().hccCard()
      }
    }
    .sheet(item: $selected) { metric in
      HCCBiomarkerDetailSheet(metric: metric)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(HCCTheme.Color.bg)
    }
    .task {
      await load.loadIfNeeded { try await HCCSession.shared.client.biomarkers() }
      openRequestedBiomarker()
    }
  }

  /// DEBUG only. `HCC_DEBUG_OPEN_BIOMARKER=<slug>` presents that row's detail
  /// sheet once the panels have loaded. `simctl` cannot tap, so this is the only
  /// way a scripted run can screenshot where the tap lands.
  private func openRequestedBiomarker() {
    #if DEBUG
    guard let slug = ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_BIOMARKER"], !slug.isEmpty,
          let metric = load.value?.panels.flatMap(\.metrics).first(where: { $0.slug == slug })
    else { return }
    selected = metric
    #endif
  }

  private var subtitle: String {
    guard let panels = load.value else { return "Graded vs optimal targets" }
    let newest = panels.panels
      .flatMap(\.metrics)
      .map(\.lastTestedISO)
      .max()
    guard let newest, let date = HCCTime.instant(newest) else {
      return "Graded vs optimal targets"
    }
    return "Last panel \(date.formatted(.dateTime.month(.abbreviated).day())) · graded vs optimal targets"
  }

  private func panelCard(_ panel: HCCBiomarkerPanel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HCCLabel(Self.categoryTitle(panel.category), size: 11)
      ForEach(Array(panel.metrics.enumerated()), id: \.element.slug) { index, metric in
        BiomarkerRow(metric: metric, showsDivider: index < panel.metrics.count - 1) {
          selected = metric
        }
      }
    }
    .hccCard()
  }

  /// `CARDIOVASCULAR` → `Cardiovascular`. The server's enum is the grouping key;
  /// the screen just makes it readable.
  static func categoryTitle(_ raw: String) -> String {
    raw.split(separator: "_")
      .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
      .joined(separator: " ")
  }
}

// ── Row ──────────────────────────────────────────────────────────────────────

/// `.bio` — status dot, name, value, optimal target. Tapping it opens the same
/// card the web app shows on hover (`HCCBiomarkerDetailSheet`).
private struct BiomarkerRow: View {
  let metric: HCCMetricView
  let showsDivider: Bool
  let onTap: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Button(action: onTap) { rowContent }
        .buttonStyle(.plain)
      if showsDivider { HCCDivider() }
    }
  }

  private var rowContent: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Self.dotColor(metric.status))
        .frame(width: 8, height: 8)

      Text(metric.displayName)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.text)
        .lineLimit(2)

      Spacer(minLength: 8)

      valueText

      Text(Self.targetText(metric))
        .font(HCCTheme.Font.data(size: 10))
        .foregroundStyle(HCCTheme.Color.muted)
        .frame(minWidth: 56, alignment: .trailing)

      Text("\u{203A}")
        .font(HCCTheme.Font.body(size: 13))
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .padding(.vertical, 7)
    // The whole row is the target, not just the glyphs in it: the gaps between
    // name, value and target are the widest part of the row and a tap that
    // lands in one must still open the card.
    .contentShape(Rectangle())
  }

  /// The number, with its unit trailing in the muted micro size the mockup uses
  /// for secondary data.
  @ViewBuilder
  private var valueText: some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) {
      Text(metric.value.map { HCCFormat.decimal($0, abs($0) >= 100 ? 0 : 1) } ?? HCCFormat.placeholder)
        .font(HCCTheme.Font.data(size: 12.5))
        .monospacedDigit()
        .foregroundStyle(HCCTheme.Color.text)
      if let unit = metric.unit, !unit.isEmpty, metric.value != nil {
        Text(unit)
          .font(HCCTheme.Font.data(size: 9.5))
          .foregroundStyle(HCCTheme.Color.muted)
      }
    }
  }

  /// `nominal` / `watch` / `alert` from the server, which graded them against
  /// the optimal target. Anything else is unknown and stays muted rather than
  /// being coloured green by default.
  static func dotColor(_ status: String) -> Color {
    switch status {
    case "nominal": HCCTheme.Color.good
    case "watch": HCCTheme.Color.warn
    case "alert": HCCTheme.Color.bad
    default: HCCTheme.Color.muted
    }
  }

  /// "70–90", "<5.4", "≥15" — the optimal target as the direction states it.
  static func targetText(_ metric: HCCMetricView) -> String {
    let low = metric.optimalLow
    let high = metric.optimalHigh
    switch metric.optimalDir {
    case "LOWER_IS_BETTER":
      if let high { return "<\(trimmed(high))" }
    case "HIGHER_IS_BETTER":
      if let low { return "≥\(trimmed(low))" }
    default:
      break
    }
    switch (low, high) {
    case let (low?, high?): return "\(trimmed(low))–\(trimmed(high))"
    case let (low?, nil): return "≥\(trimmed(low))"
    case let (nil, high?): return "<\(trimmed(high))"
    default: return "no target"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 10000
      ? String(format: "%.0f", value)
      : String(format: "%g", value)
  }
}
