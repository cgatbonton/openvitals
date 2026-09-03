import SwiftUI

/// `S.protocols` — the owner's documented regimens, read-only.
///
/// The protocol record IS the authority for dose, frequency, status and start
/// date; this screen renders what it holds and recomputes none of it. The
/// mockup's "adherence 6 of 7 this week" needs logged journal doses, which are a
/// later phase, so the footer shows the start date alone rather than an
/// adherence figure nobody calculated.
struct HCCProtocolsView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var load = HCCPageLoad<HCCProtocolsResponse>()

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Protocols", subtitle: "Active · planned · archived")

      if let response = load.value {
        let ordered = Self.ordered(response.protocols)
        if ordered.isEmpty {
          HCCEmptyNote("No protocols on record for this instance.")
            .hccCard()
        } else {
          ForEach(ordered) { item in
            ProtocolCard(item: item)
          }
          HCCFootnote("Doses, dates and statuses come from the protocol records; editing stays on the web page.")
        }
      } else if let error = load.errorText {
        HCCErrorNote(error) { await load.reload { try await HCCSession.shared.client.protocols() } }
      } else {
        HCCLoadingNote().hccCard()
      }
    }
    .task {
      await load.loadIfNeeded { try await HCCSession.shared.client.protocols() }
    }
  }

  /// Live first, then planned, then everything that has stopped. Inside a rank
  /// the server's own order is kept.
  static func ordered(_ items: [HCCProtocol]) -> [HCCProtocol] {
    items.enumerated()
      .sorted { lhs, rhs in
        let left = rank(lhs.element.status)
        let right = rank(rhs.element.status)
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }

  private static func rank(_ status: String) -> Int {
    switch status {
    case "ACTIVE": 0
    case "PLANNED": 1
    case "PAUSED": 2
    case "COMPLETED": 3
    default: 4
    }
  }
}

// ── Card ─────────────────────────────────────────────────────────────────────

private struct ProtocolCard: View {
  let item: HCCProtocol

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(HCCTheme.Font.display(size: 15, weight: .medium))
            .tracking(-0.15)
            .foregroundStyle(HCCTheme.Color.text)
            .fixedSize(horizontal: false, vertical: true)
          if let regimen {
            Text(regimen)
              .font(HCCTheme.Font.body(size: 11.5))
              .foregroundStyle(HCCTheme.Color.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        HCCPill(item.status, tone: Self.tone(item.status))
      }

      if let footer {
        Text(footer)
          .font(HCCTheme.Font.data(size: 10.5))
          .foregroundStyle(HCCTheme.Color.muted)
      }
    }
    .hccCard()
  }

  /// "1 mg SC · daily AM" — dose, frequency and administration route, each
  /// dropped when the record does not carry it.
  private var regimen: String? {
    let parts = [item.dose, item.frequency, item.route]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "Since Aug 24". The record stores the date at UTC midnight, so only the
  /// date part is read — rendering it through a local calendar would slide it a
  /// day for anyone west of UTC.
  private var footer: String? {
    guard let startDate = item.startDate else { return nil }
    let dayKey = String(startDate.prefix(10))
    let label = HealthDataStore.hccShortDayLabel(dayKey)
    return item.status == "PLANNED" ? "Starts \(label)" : "Since \(label)"
  }

  static func tone(_ status: String) -> HCCPill.Tone {
    switch status {
    case "ACTIVE": .good
    case "PLANNED": .accent
    case "PAUSED": .warn
    default: .muted
    }
  }
}
