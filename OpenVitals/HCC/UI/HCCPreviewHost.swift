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
  @State private var biomarkerDetail: HCCMetricView?

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
          biomarkerDetailSection.id("biomarker")
        }
        .padding(.horizontal, 16)
        // The tab bar floats over the content now, so the gallery leaves the
        // same clearance a real screen does.
        .padding(.bottom, HCCTheme.Spacing.tabBarClearance)
      }
      .onAppear {
        guard let anchor = Self.requestedAnchor else { return }
        proxy.scrollTo(anchor, anchor: .top)
        // `simctl` cannot tap, so the one anchor that names a sheet opens it.
        if anchor == "biomarker" { biomarkerDetail = Self.sampleMetric }
      }
    }
    .scrollIndicators(.hidden)
    .hccBackground()
    .sheet(isPresented: $comingSoon) {
      HCCComingSoonSheet(feature: "Coach")
    }
    .sheet(item: $biomarkerDetail) { metric in
      HCCBiomarkerDetailSheet(metric: metric)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(HCCTheme.Color.bg)
    }
  }

  // ── Sections ───────────────────────────────────────────────────────────────

  /// The card a biomarker row opens — the phone's stand-in for the web app's
  /// hover tooltip. Presented from here so it can be screenshotted without a
  /// signed-in instance; the numbers are fake, like everything else on this page.
  private var biomarkerDetailSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Biomarker detail")
      HCCButtonRow(
        primary: HCCButtonSpec(title: "Open detail sheet") { biomarkerDetail = Self.sampleMetric }
      )
      .padding(.bottom, 12)
    }
  }

  /// Obviously fake, and it never leaves this file.
  private static let sampleMetric = HCCMetricView(
    slug: "sample-marker",
    displayName: "Sample Marker",
    category: "METABOLIC",
    unit: "mg/dL",
    value: 123.0,
    optimalDir: "LOWER_IS_BETTER",
    status: "watch",
    n: 4,
    lastTestedISO: "2020-01-02T00:00:00.000Z",
    ageText: "3 mo ago",
    summary: "A made-up marker that exists only in this gallery, so the card can be "
      + "screenshotted without a signed-in instance.",
    optimalLow: nil,
    optimalHigh: 100,
    comparison: "23 above the optimal ceiling",
    trend: "Up 8 since the previous reading",
    aiInsight: "**Sample insight.** This paragraph stands in for the personalized read the "
      + "server writes, so the markdown rendering and the accent card can be checked.",
    insightStale: true
  )

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Command components")
        .font(HCCTheme.Font.display(size: 26, weight: .semibold))
        .tracking(-0.6)
        .foregroundStyle(HCCTheme.Color.text)
      Text("Sample props · not connected to any instance")
        .font(HCCTheme.Font.data(size: 10.5))
        .tracking(0.5)
        .textCase(.uppercase)
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .padding(.top, 14)
    .padding(.bottom, 4)
  }

  private var rings: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Rings")

      // The Home row: three 100-pt rings, 10-pt stroke, no ticks, each under
      // its own metric chip and staggered 0.1 s apart.
      HStack(spacing: 8) {
        HCCRingWrap(
          title: "Sleep",
          ring: HCCRing(
            progress: 0.72, kind: .sleep, size: 100, stroke: 10,
            value: "72", unit: "%", animationDelay: 0
          ),
          tint: HCCTheme.Color.sleep,
          tintText: HCCTheme.Color.sleepText
        )
        HCCRingWrap(
          title: "Recovery",
          ring: HCCRing(
            progress: 0.69, kind: .rec, size: 100, stroke: 10,
            value: "69", unit: "%", band: .band(for: 69), animationDelay: 0.1
          ),
          tint: HCCTheme.Color.recovery,
          tintText: HCCTheme.Color.recoveryText
        )
        HCCRingWrap(
          title: "Strain",
          ring: HCCRing(
            progress: 11.4 / 21, kind: .strain, size: 100, stroke: 10,
            value: "11.4", target: 14.9 / 21, animationDelay: 0.2
          ),
          tint: HCCTheme.Color.strain,
          tintText: HCCTheme.Color.strainText
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
          HCCRing(progress: 0, kind: .rec, size: 94, stroke: 7, value: nil, unit: "%")
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
        HCCFlowRow(spacing: 8, lineSpacing: 8) {
          HCCPill("ACTIVE", tone: .good)
          HCCPill("watch", tone: .warn)
          HCCPill("alert", tone: .bad)
          HCCPill("COMPLETED", tone: .muted)
          HCCPill("heterozygous CT", tone: .info)
          HCCPill("PLANNED", tone: .accent)
        }
        HCCLabel("Small caps label")
        HCCSectionLink(title: "Biomarkers") {}
        HCCEmptyNote("No open insights. New ones appear as syncs land.")
      }
      .hccCard()

      // The metric tints, which are what the direction is named after: a card
      // that belongs to one metric carries that metric's colour.
      VStack(alignment: .leading, spacing: 8) {
        tintedCardSample("Sleep tint", tint: HCCTheme.Color.sleep, text: HCCTheme.Color.sleepText)
        tintedCardSample("Recovery tint", tint: HCCTheme.Color.recovery, text: HCCTheme.Color.recoveryText)
        tintedCardSample("Strain tint", tint: HCCTheme.Color.strain, text: HCCTheme.Color.strainText)
        tintedCardSample("Good tint · 0.08 → 0.02", tint: HCCTheme.Color.good, text: HCCTheme.Color.goodText, top: 0.08, bottom: 0.02)

        // The one card in the design with a border.
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text("Recovery 69%")
              .font(HCCTheme.Font.display(size: 16, weight: .semibold))
              .tracking(-0.2)
              .foregroundStyle(HCCTheme.Color.text)
            HCCPill("hcc_recovery", color: HCCTheme.Color.recovery)
          }
          Text("The insight card: the cyan/violet gradient plus a 1-px border, the only bordered card in the design.")
            .font(HCCTheme.Font.body(size: 14))
            .lineSpacing(4)
            .foregroundStyle(HCCTheme.Color.textBody)
            .fixedSize(horizontal: false, vertical: true)
        }
        .hccCard(
          fill: HCCTheme.Color.insightGradient,
          border: HCCTheme.Color.recovery.opacity(0.14),
          padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        )
      }
      .padding(.top, 8)
    }
  }

  private func tintedCardSample(
    _ title: String,
    tint: Color,
    text: Color,
    top: Double = 0.15,
    bottom: Double = 0.035
  ) -> some View {
    HStack {
      Text(title)
        .font(HCCTheme.Font.display(size: 15, weight: .semibold))
        .tracking(-0.2)
        .foregroundStyle(HCCTheme.Color.text)
      Spacer(minLength: 8)
      Text("SAMPLE")
        .hccLabelStyle(size: 10, color: text)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.18)))
    }
    .hccCard(tint: tint, tintTop: top, tintBottom: bottom)
  }

  /// A week shaped to stress the chart's edges, not to look tidy.
  private static let strainRecoveryFixture: [HCCStrainRecoveryPoint] = [
    .init(day: "2026-08-31", weekday: "Mon", dayOfMonth: "31", strain: 5.0, recovery: 100),
    .init(day: "2026-09-01", weekday: "Tue", dayOfMonth: "1", strain: 15.7, recovery: 84),
    .init(day: "2026-09-02", weekday: "Wed", dayOfMonth: "2", strain: 14.2, recovery: 51),
    .init(day: "2026-09-03", weekday: "Thu", dayOfMonth: "3", strain: nil, recovery: 56),
    .init(day: "2026-09-04", weekday: "Fri", dayOfMonth: "4", strain: 0.1, recovery: nil),
    .init(day: "2026-09-05", weekday: "Sat", dayOfMonth: "5", strain: 8.4, recovery: 66),
    .init(day: "2026-09-06", weekday: "Sun", dayOfMonth: "6", strain: 18.6, recovery: 100),
  ]

  private var charts: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Charts")

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Strain & recovery")
        // The widest labels the chart can draw, on the two columns that sit
        // closest to the axis text: a full-width "100%" on day one and a
        // two-digit strain on the last. Home cannot show this without a week
        // of live scores, so the fixture is the only way to see the edges.
        HCCStrainRecoveryChart(points: Self.strainRecoveryFixture)
      }
      .hccCard()

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
        // A navigating row gets the chevron; a row with no action does not.
        HCCMenuRow(title: "Server", detail: "localhost:3999") {}
        HCCMenuRow(title: "Account", detail: "you@example.com", detailColor: HCCTheme.Color.recoveryText) {}
        HCCMenuRow(title: "Time zone", detail: "America/Bogota")
        HCCMenuRow(title: "Sign out", showsDivider: false, showsChevron: false) {}
      }
      .hccCard()
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCSectionHeader(title: "Controls")

      // The Home top bar, in every state its sync button has. Here rather than
      // only on Home because Home needs a signed-in session and a reachable
      // instance before it will draw anything, and this arrangement — where the
      // day label sits, what the button does while it works — has to be
      // checkable against the design without either.
      VStack(alignment: .leading, spacing: 8) {
        topBarSample(isRunning: false, outcome: nil)
        topBarSample(isRunning: true, outcome: nil)
        topBarSample(isRunning: false, outcome: true)
        topBarSample(isRunning: false, outcome: false)
        Text("Synced — nothing new yet.")
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.muted)
      }
      .padding(.bottom, 14)

      VStack(alignment: .leading, spacing: 0) {
        HCCToggleRow(title: "Smart wake window", isOn: $toggleOn)
        HCCToggleRow(title: "Watch haptic", isOn: $toggleOff, showsDivider: false)
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 0) {
        HCCCheckRow(title: "Recovery graph", isOn: $checkOn, meta: "graph")
        HCCCheckRow(title: "Resting heart rate", isOn: $checkOff, meta: "metric", showsDivider: false)
        // The Training set row's smaller box, next to the dose row's, so the
        // pair can be compared rather than eyeballed one at a time.
        HStack(spacing: 12) {
          HCCCheckbox(isOn: true)
          HCCCheckbox(isOn: false)
          HCCCheckbox(isOn: true, size: 20, radius: 6)
          HCCCheckbox(isOn: false, size: 20, radius: 6)
          Spacer(minLength: 0)
        }
        .padding(.top, 10)
      }
      .hccCard()

      VStack(alignment: .leading, spacing: 8) {
        HCCButtonRow(
          primary: HCCButtonSpec(title: "Start activity", systemImage: "play.fill") { comingSoon = true },
          secondary: HCCButtonSpec(title: "Add", systemImage: "plus") {}
        )
        HCCButtonRow(
          primary: HCCButtonSpec(title: "Disabled primary", isEnabled: false) {},
          secondary: HCCButtonSpec(title: "Coming soon sheet") { comingSoon = true }
        )
        // The Training control row.
        HCCButtonRow(
          primary: HCCButtonSpec(title: "Deload") {},
          secondary: HCCButtonSpec(title: "Advance week") {},
          style: .utility
        )
      }
      .padding(.top, 10)

      // The header, with the trailing slot Journal fills with its day nav.
      VStack(alignment: .leading, spacing: 12) {
        HCCDetailHeader(title: "Journal", subtitle: "Today · Tue, Sep 9", showsBack: false) {
          HCCDayNav(
            label: "Today", canGoBack: true, canGoForward: false, labelSize: 13,
            goBack: {}, goForward: {}
          )
        }
        HCCDetailHeader(title: "Biomarkers", subtitle: "Last panel Aug 22 · graded vs optimal targets", size: 24)
      }
      .padding(.top, 16)
    }
  }

  /// One top bar with the real components, so the centring is measured rather
  /// than mocked. The device label is deliberately a long one — that is the
  /// case where a naive layout would push the day label off the midline.
  private func topBarSample(isRunning: Bool, outcome: Bool?) -> some View {
    HCCTopBarLayout {
      HCCSyncButton(isRunning: isRunning, outcome: outcome) {}
    } center: {
      HCCDayNav(label: "Today", canGoBack: true, canGoForward: false, goBack: {}, goForward: {})
    } trailing: {
      HCCDevicePill(label: "Fitbit Air", batteryPercent: 82, stateColor: HCCTheme.Color.good) {}
    }
  }
}
#endif
