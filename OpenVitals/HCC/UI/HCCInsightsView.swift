import SwiftUI

/// `S.insights` — open cards, the latest weekly retrospective, and the archive.
///
/// The ✓ button sends `ACKNOWLEDGED`, which is a different claim from the
/// `DISMISSED` the Home card sends: acknowledged means read, dismissed means
/// not useful, and the server records them separately. The row is moved locally
/// the moment the write succeeds and the list is re-read afterwards, so what is
/// on screen is what the server holds — a failed write leaves the card open and
/// says why.
struct HCCInsightsView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var cards = HCCPageLoad<HCCInsightsResponse>()
  @StateObject private var weekly = HCCPageLoad<HCCWeeklyInsightsResponse>()

  /// Ids this screen has just acknowledged, so the row moves before the re-read
  /// lands. Never used to hide anything the server still calls ACTIVE after a
  /// failed write — see `acknowledge`.
  @State private var acknowledgedIds: Set<String> = []
  @State private var writeError: String?

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Insights", subtitle: "Open · acknowledged · weekly")

      if let error = writeError {
        HCCErrorNote(error)
      }

      openSection
      weeklySection
      archiveSection
    }
    .task {
      await cards.loadIfNeeded { try await HCCSession.shared.client.insights(status: "all", limit: 50) }
    }
    .task {
      await weekly.loadIfNeeded { try await HCCSession.shared.client.weeklyInsights(limit: 1) }
    }
  }

  // ── Open ───────────────────────────────────────────────────────────────────

  private var openCards: [HCCInsightCard] {
    (cards.value?.insights ?? [])
      .filter { $0.status == "ACTIVE" && !acknowledgedIds.contains($0.id) }
  }

  @ViewBuilder
  private var openSection: some View {
    if cards.isPending {
      HCCLoadingNote().hccCard()
    } else if let error = cards.errorText {
      HCCErrorNote(error) { await reloadCards() }
    } else if openCards.isEmpty {
      HCCEmptyNote("No open insights. New ones appear as syncs land.")
        .hccCard()
    } else {
      ForEach(openCards) { card in
        InsightCardView(card: card) { await acknowledge(card) }
      }
    }
  }

  private func reloadCards() async {
    await cards.reload { try await HCCSession.shared.client.insights(status: "all", limit: 50) }
  }

  private func acknowledge(_ card: HCCInsightCard) async {
    writeError = nil
    acknowledgedIds.insert(card.id)
    do {
      _ = try await HCCSession.shared.client.setInsightStatus(id: card.id, status: "ACKNOWLEDGED")
      await reloadCards()
      acknowledgedIds.remove(card.id)
      // Home reads the open feed off the store, so it has to hear about this
      // too or the card comes back the next time that screen appears.
      await store.refreshFromHCC()
    } catch {
      acknowledgedIds.remove(card.id)
      if let apiError = error as? HCCAPIError {
        if case .unauthorized = apiError { HCCSession.shared.handleUnauthorized() }
        writeError = apiError.errorDescription ?? "Could not update that insight."
      } else {
        writeError = error.localizedDescription
      }
    }
  }

  // ── Weekly ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private var weeklySection: some View {
    if let latest = weekly.value?.latest {
      VStack(alignment: .leading, spacing: 6) {
        HCCLabel("Weekly insight · \(Self.weekRange(latest))", size: 10)
        Text(latest.headline)
          .font(HCCTheme.Font.body(size: 12.5, weight: .medium))
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
        if let excerpt = Self.excerpt(latest.summary) {
          Text(excerpt)
            .font(HCCTheme.Font.body(size: 12.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .hccCard()
    } else if weekly.isPending {
      HCCLoadingNote(text: "Loading the weekly log...").hccCard()
    }
  }

  /// "Aug 24–30" from the two civil day keys, which are the server's week
  /// boundaries and are never re-derived here.
  static func weekRange(_ insight: HCCWeeklyInsight) -> String {
    let start = HealthDataStore.hccLocalDate(fromDayKey: insight.weekStart)
    let end = HealthDataStore.hccLocalDate(fromDayKey: insight.weekEnd)
    guard let start, let end else { return "\(insight.weekStart) – \(insight.weekEnd)" }
    let startText = start.formatted(.dateTime.month(.abbreviated).day())
    let sameMonth = Calendar.current.component(.month, from: start) == Calendar.current.component(.month, from: end)
    let endText = sameMonth
      ? end.formatted(.dateTime.day())
      : end.formatted(.dateTime.month(.abbreviated).day())
    return "\(startText)–\(endText)"
  }

  /// The first prose paragraph of the markdown summary, capped. The full text
  /// lives on the web page; this is a look, not a replacement.
  static func excerpt(_ markdown: String, limit: Int = 260) -> String? {
    let plain = markdown
      .split(separator: "\n")
      .map { line -> String in
        var text = String(line)
        while text.hasPrefix("#") || text.hasPrefix(">") || text.hasPrefix("-") || text.hasPrefix("*") {
          text.removeFirst()
        }
        return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !plain.isEmpty else { return nil }
    guard plain.count > limit else { return plain }
    return plain.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
  }

  // ── Archive ────────────────────────────────────────────────────────────────

  private var archived: [HCCInsightCard] {
    (cards.value?.insights ?? []).filter { $0.status == "ACKNOWLEDGED" || $0.status == "DISMISSED" }
  }

  @ViewBuilder
  private var archiveSection: some View {
    if !archived.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HCCLabel("Acknowledged", size: 11)
          .padding(.bottom, 4)
        ForEach(Array(archived.enumerated()), id: \.element.id) { index, card in
          HCCMenuRow(
            title: card.title,
            detail: card.status.lowercased(),
            showsDivider: index < archived.count - 1
          )
        }
      }
      .hccCard()
    }
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

/// `.ins` — the card body and the ✓ column beside it.
private struct InsightCardView: View {
  let card: HCCInsightCard
  let acknowledge: () async -> Void

  @State private var isWriting = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(card.title)
          .font(HCCTheme.Font.display(size: 15, weight: .medium))
          .tracking(-0.15)
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
        Text(card.summary)
          .font(HCCTheme.Font.body(size: 12.5))
          .lineSpacing(3)
          .foregroundStyle(HCCTheme.Color.text)
          .fixedSize(horizontal: false, vertical: true)
        if !card.relatedMetricSlugs.isEmpty {
          Text(card.relatedMetricSlugs.joined(separator: " · "))
            .font(HCCTheme.Font.data(size: 10))
            .tracking(0.4)
            .foregroundStyle(HCCTheme.Color.muted)
            .padding(.top, 2)
        }
      }

      Button {
        guard !isWriting else { return }
        isWriting = true
        Task {
          await acknowledge()
          isWriting = false
        }
      } label: {
        VStack(spacing: 4) {
          if isWriting {
            ProgressView().controlSize(.mini).tint(HCCTheme.Color.text)
          } else {
            Image(systemName: "checkmark")
              .font(.system(size: 13, weight: .semibold))
          }
        }
        .foregroundStyle(HCCTheme.Color.text)
        .frame(width: 34)
        .frame(minHeight: 34)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(HCCTheme.Color.card2)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Acknowledge")
    }
    .hccCard()
  }
}
