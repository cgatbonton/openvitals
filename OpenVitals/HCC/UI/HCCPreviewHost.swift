#if DEBUG
import SwiftUI

/// Every "C · Command" component on one scrollable page, with sample props.
///
/// DEBUG only, and reachable only through `HCC_DEBUG_OPEN_SCREEN=gallery` on
/// the launch environment — there is no in-app route to it. It exists so the
/// design system can be screenshotted and compared against the mockup without
/// waiting for the screens that consume it, and so a later change to a token
/// has one place that shows what it broke.
///
/// The numbers below are OBVIOUSLY fake and never leave this file: the gallery
/// is not connected to the store and cannot be reached from a shipping build,
/// so nothing here can be mistaken for a reading. Every real screen takes its
/// values from `HealthDataStore`.
struct HCCComponentGallery: View {
  /// The launch-environment switch that opens this screen.
  static let debugScreenKey = "HCC_DEBUG_OPEN_SCREEN"
  static let debugScreenValue = "gallery"

  /// Which section to scroll to on appear, so every part of the gallery can be
  /// screenshotted without UI automation — the same trick `HCC_DEBUG_OPEN_ROUTE`
  /// uses for the detail screens. `rings` | `chips` | `charts` | `rows` |
  /// `controls`; absent means the top.
  static let debugAnchorKey = "HCC_DEBUG_GALLERY_ANCHOR"

  static var isRequested: Bool {
    ProcessInfo.processInfo.environment[debugScreenKey] == debugScreenValue
  }

  private static var requestedAnchor: String? {
    ProcessInfo.processInfo.environment[debugAnchorKey].flatMap { $0.isEmpty ? nil : $0 }
  }

  @State private var toggleOn = true
  @State private var toggleOff = false
  @State private var checkOn = true
  @State private var checkOff = false
  @State private var comingSoon = false

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header
          rings.id("rings")
          chipsAndPills.id("chips")
          charts.id("charts")
          rowsAndGrids.id("rows")
          controls.id("controls")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
      }
      .onAppear {
        guard let anchor = Self.requestedAnchor else { return }
        proxy.scrollTo(anchor, anchor: .top)
      }
    }
    .scrollIndicators(.hidden)
    .hccBackground()
    .sheet(isPresented: $comingSoon) {
      HCCComingSoonSheet(feature: "Coach")
    }
  }

  // ── Sections ───────────────────────────────────────────────────────────────

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Command components")
        .font(HCCTheme.Font.display(size: 20, weight: .medium))
        .tracking(-0.4)
        .foregroundStyle(HCCTheme.Color.text)
      Text("Sample props · not connected to any instance")
        .font(HCCTheme.Font.body(size: 11.5))
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .padding(.top, 14)
    .padding(.bottom, 4)
  }

  private var rings: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Rings")

      // The Home row: three 94-pt rings, 7-pt stroke, no ticks.
      HStack(spacing: 8) {
        HCCRingWrap(
          title: "Sleep",
          ring: HCCRing(progress: 0.81, kind: .sleep, size: 94, stroke: 7, value: "81", unit: "%")
        )
        HCCRingWrap(
          title: "Recovery",
          ring: HCCRing(
            progress: 0.70, kind: .rec, size: 94, stroke: 7,
            value: "70", unit: "%", sub: "84 · 51", band: .band(for: 70)
          )
        )
        HCCRingWrap(
          title: "Strain",
          ring: HCCRing(
            progress: 12.4 / 21, kind: .strain, size: 94, stroke: 7,
            value: "12.4", target: 13.5 / 21
          )
        )
      }

      // The Recovery hero: 176 pt, 11-pt stroke, ticked, orb gradient.
      VStack(spacing: 6) {
        HCCRing(
          progress: 0.70, kind: .rec, size: 176, stroke: 11, ticks: true,
          value: "70", unit: "%", sub: HCCRecoveryBand.band(for: 70).word.uppercased(),
          band: .band(for: 70)
        )
        HCCPill(
          HCCRecoveryBand.band(for: 70).word,
          color: HCCRecoveryBand.band(for: 70).color
        )
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)

      // Recovery is band-coloured, so every band gets shown — plus the state
      // where there is no band at all.
      HCCLabel("Recovery bands · orb gradients")
        .padding(.bottom, 4)
      HStack(spacing: 8) {
        recoveryBandSample(value: 78)
        recoveryBandSample(value: 50)
        recoveryBandSample(value: 22)
      }
      HStack(spacing: 8) {
        // Calibrating: no value, no band, no glow — the muted pair.
        VStack(spacing: 6) {
          HCCRing(progress: 0, kind: .rec, size: 94, stroke: 7, value: nil, unit: "%", sub: "--")
          HCCLabel("Calibrating")
          HCCPill("No band", tone: .muted)
        }
        .frame(maxWidth: .infinity)
        VStack(spacing: 6) {
          HCCRing(progress: 0, kind: .sleep, size: 94, stroke: 7, value: nil, unit: "%")
          HCCLabel("Sleep · no data")
          HCCPill("--", tone: .muted)
        }
        .frame(maxWidth: .infinity)
        VStack(spacing: 6) {
          HCCRing(
            progress: 12.4 / 21, kind: .strain, size: 94, stroke: 7, ticks: true,
            value: "12.4", sub: "TGT 13.5", target: 13.5 / 21
          )
          HCCLabel("Strain · ticked")
          HCCPill("Target", tone: .accent)
        }
        .frame(maxWidth: .infinity)
      }
      .padding(.top, 6)
    }
  }

  /// One recovery ring in whichever band its value falls in, with the word and
  /// pill beside it, so a colour mismatch between them is visible at a glance.
  private func recoveryBandSample(value: Double) -> some View {
    let band = HCCRecoveryBand.band(for: value)
    return VStack(spacing: 6) {
      HCCRing(
        progress: value / 100, kind: .rec, size: 94, stroke: 7,
        value: String(format: "%.0f", value), unit: "%", band: band
      )
      HCCLabel(band.word)
      HCCPill(band.word, color: band.color)
    }
    .frame(maxWidth: .infinity)
  }

  private var chipsAndPills: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Chips and pills") {
        HCCSectionLink(title: "Link ✎") {}
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          HCCChip("7 days")
          HCCChip("recovery", dotColor: HCCTheme.Color.rec)
          HCCChip("moderate", dotColor: HCCTheme.Color.strain)
        }
        HStack(spacing: 8) {
          HCCPill("Primed", tone: .good)
          HCCPill("Watch", tone: .warn)
          HCCPill("Rest", tone: .bad)
          HCCPill("Archived", tone: .muted)
          HCCPill("Planned", tone: .accent)
        }
        HCCLabel("Small caps label")
        HCCEmptyNote("No open insights. New ones appear as syncs land.")
      }
      .hccCard()
    }
  }

  private var charts: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Charts")

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Bars · banded colour")
        HCCBars(
          values: [61, 48, 70, 77, 65, 58, 72, 81, 69, 74, 86, 64, 89, 82],
          max: 100,
          color: { HCCRecoveryBand.band(for: $0).color }
        )
        HCCAxis(leading: "Aug 20", trailing: "today")
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Bars · with targets")
        HCCBars(
          values: [11.2, 9.4, 14.1, 8.2, 13.0, 10.6, 12.4],
          max: HCCTheme.strainMax,
          color: HCCTheme.Color.strain,
          targets: [12, 11, 13.5, 9, 12.5, 11, 13.5]
        )
        HCCAxis(leading: "Thu", trailing: "today")
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Sparkline")
        HCCSparkline(values: [48, 52, 51, 58, 55, 61, 59, 66, 63, 70])
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Optimal band")
        HCCBand(position: 0.55)
        HCCLabel("Z-score · positive then negative", size: 9.5)
        HCCZScoreBar(z: 1.2)
        HCCZScoreBar(z: -0.8)
      }
      .hccCard()
    }
  }

  private var rowsAndGrids: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Data rows")

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Key / value")
        HCCKeyValueGrid(rows: [
          HCCKeyValue("Baseline need", "7h 36m"),
          HCCKeyValue("Recent strain", "+0h 14m"),
          HCCKeyValue("Sleep debt", "+0h 15m"),
          HCCKeyValue("Need", "8h 05m", emphasized: true),
        ])
      }
      .hccCard()

      HCCStat3(items: [
        HCCStat(value: "142", label: "Avg HR"),
        HCCStat(value: "171", label: "Max HR"),
        HCCStat(value: "486", label: "kcal"),
      ])
      .hccCard()

      VStack(alignment: .leading, spacing: 0) {
        HCCLabel("Menu rows")
          .padding(.bottom, 4)
        HCCMenuRow(title: "Server", detail: "localhost:3999") {}
        HCCMenuRow(title: "Time zone", detail: "America/Bogota") {}
        HCCMenuRow(title: "Sign out", showsDivider: false) {}
      }
      .hccCard()
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Controls")

      VStack(alignment: .leading, spacing: 0) {
        HCCToggleRow(title: "Smart wake window", isOn: $toggleOn)
        HCCToggleRow(title: "Watch haptic", isOn: $toggleOff, showsDivider: false)
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 0) {
        HCCCheckRow(title: "Recovery graph", isOn: $checkOn, meta: "graph")
        HCCCheckRow(title: "Resting heart rate", isOn: $checkOff, meta: "metric", showsDivider: false)
      }
      .hccCard()

      HCCButtonRow(
        primary: HCCButtonSpec(title: "◉ Start activity") { comingSoon = true },
        secondary: HCCButtonSpec(title: "＋ Add activity") {}
      )
      HCCButtonRow(
        primary: HCCButtonSpec(title: "Disabled primary", isEnabled: false) {},
        secondary: HCCButtonSpec(title: "Coming soon sheet") { comingSoon = true }
      )
    }
  }
}
#endif
