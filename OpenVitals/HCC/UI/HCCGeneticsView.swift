import SwiftUI

/// `S.genetics` — the curated variants for this instance's owner.
///
/// The mockup's pill reads "heterozygous / homozygous / not carried". The
/// payload carries a GENOTYPE (`TT`, `AC`) and whether it was directly called;
/// it does not carry a risk allele, so "not carried" is not derivable and is
/// never printed. Zygosity IS derivable — two identical alleles or two
/// different ones is what the genotype string says — and anything that is not a
/// plain allele pair keeps its raw genotype in a muted pill rather than being
/// forced into a category.
struct HCCGeneticsView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var load = HCCPageLoad<HCCGenetics>()

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Genetics", subtitle: subtitle)

      if let genetics = load.value {
        if genetics.markers.isEmpty {
          HCCEmptyNote("No genome is loaded for this instance.")
            .hccCard()
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(genetics.markers.enumerated()), id: \.element.id) { index, marker in
              MarkerRow(marker: marker, showsDivider: index < genetics.markers.count - 1)
            }
          }
          .hccCard()
          HCCFootnote("The same curated list the web genetics page shows for this instance.")
        }
      } else if let error = load.errorText {
        HCCErrorNote(error) { await load.reload { try await HCCSession.shared.client.genetics() } }
      } else {
        HCCLoadingNote().hccCard()
      }
    }
    .task {
      await load.loadIfNeeded { try await HCCSession.shared.client.genetics() }
    }
  }

  private var subtitle: String {
    guard let count = load.value?.count else { return "Curated variants" }
    return "Curated variants · \(count)"
  }
}

// ── Row ──────────────────────────────────────────────────────────────────────

private struct MarkerRow: View {
  let marker: HCCGenomicMarker
  let showsDivider: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(HCCTheme.Font.body(size: 13.5, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
          Text(marker.headline)
            .font(HCCTheme.Font.body(size: 11.5))
            .foregroundStyle(HCCTheme.Color.muted)
            .fixedSize(horizontal: false, vertical: true)
          if !marker.called {
            Text("inferred, not directly called")
              .font(HCCTheme.Font.data(size: 10))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
        Spacer(minLength: 8)
        HCCPill(zygosity.text, tone: zygosity.tone)
      }
      .padding(.vertical, 11)
      if showsDivider { HCCDivider() }
    }
  }

  /// The gene, plus the rsid when the catalog names one. The genotype is NOT
  /// repeated here — the pill already carries it.
  private var title: String {
    guard let rsid = marker.rsid, !rsid.isEmpty else { return marker.gene }
    return "\(marker.gene) · \(rsid)"
  }

  /// Two identical alleles is homozygous; two different ones heterozygous.
  /// Anything else — an indel, a called haplotype, a no-call — keeps the raw
  /// genotype, because guessing at a category is guessing at a genome.
  private var zygosity: (text: String, tone: HCCPill.Tone) {
    let genotype = marker.genotype.trimmingCharacters(in: .whitespaces)
    let alleles = Array(genotype.uppercased())
    guard alleles.count == 2, alleles.allSatisfy({ "ACGT".contains($0) }) else {
      return (genotype.isEmpty ? "no call" : genotype, .muted)
    }
    return alleles[0] == alleles[1]
      ? ("homozygous \(genotype)", .warn)
      : ("heterozygous \(genotype)", .accent)
  }
}
