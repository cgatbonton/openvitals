import SwiftUI

/// `S.wearables` — the unified wearable deck: every stream this instance
/// collects, each scored against ITS OWN rolling baseline.
///
/// That is the whole reason this is a separate page from Biomarkers, and the
/// distinction is load-bearing rather than cosmetic. Biomarkers grades a value
/// against the metric catalog's OPTIMAL TARGET — "is this number where it
/// should be". The deck asks a different question — "has this number MOVED,
/// relative to its own noise" — and answers it in standard deviations of this
/// owner's own baseline. A stream can sit a long way from its optimal target
/// and be perfectly steady here, and a stream inside its target can flag. So
/// nothing on this screen is a target grading, and the footnote says so in
/// words rather than leaving the reader to infer it.
///
/// Everything drawn is the server's: the verdict, the σ, the baseline, the wear
/// coverage. This view computes no judgement of its own and invents no value —
/// a stream with no reading in the window says so, and says when it was last
/// seen, instead of showing a stale number as if it were current.
struct HCCWearablesView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var load = HCCPageLoad<HCCDeckResponse>()

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Wearables", subtitle: "14-day window · vs own baseline", size: 24)

      if let response = load.value {
        if response.deck.isEmpty {
          HCCEmptyNote("No wearable streams on record yet.")
            .hccCard()
        } else {
          ForEach(Self.groups(response.deck)) { group in
            SystemCard(group: group)
          }
          confounders(response.deck)
          wear(response)
          HCCFootnote(
            "Each stream is read over its last 14 days against its own rolling baseline, "
              + "not against an optimal target — a stream can be steady here and still be off "
              + "its target on the Biomarkers page. Steady, Watch and Flag are the server's own verdicts."
          )
        }
      } else if let error = load.errorText {
        HCCErrorNote(error) { await load.reload { try await HCCSession.shared.client.deck() } }
      } else {
        HCCLoadingNote().hccCard()
      }
    }
    .task {
      await load.loadIfNeeded { try await HCCSession.shared.client.deck() }
    }
  }

  // ── Sections ───────────────────────────────────────────────────────────────

  /// The confounders, all systems together — the web page's own arrangement.
  /// They are not judged less than the signals (they carry the same verdicts);
  /// they are separated because they MOVE the signals, so reading a signal
  /// without them is how a night of bad sleep gets read as a compound effect.
  @ViewBuilder
  private func confounders(_ deck: [HCCDeckSignal]) -> some View {
    let rows = deck.filter { $0.role == "confounder" }
    if !rows.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HCCLabel("Confounders")
          .padding(.bottom, 2)
        Text("Rule these out before reading a compound effect.")
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .padding(.bottom, 4)
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, signal in
          SignalRow(signal: signal, showsDivider: index < rows.count - 1)
        }
      }
      .hccCard()
    }
  }

  /// Which devices are reporting, how much of the span they actually covered,
  /// and when each was last seen. The cloud surface names the brand (see the
  /// Copy Rule), and it names it ONLY through `HCCCopy`.
  @ViewBuilder
  private func wear(_ response: HCCDeckResponse) -> some View {
    let sources = response.sources
    if !sources.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HCCLabel("Wear coverage")
          .padding(.bottom, 4)
        ForEach(Array(sources.enumerated()), id: \.element) { index, source in
          SourceRow(
            source: source,
            coverage: response.coverage[source],
            provenance: response.provenance.first { $0.source == source },
            showsDivider: index < sources.count - 1
          )
        }
      }
      .hccCard()
    }
  }

  // ── Grouping ───────────────────────────────────────────────────────────────

  /// One body system's signals, in the server's own rendering order.
  struct Group: Identifiable {
    let system: String
    let title: String
    let caption: String
    let signals: [HCCDeckSignal]

    var id: String { system }
  }

  /// The order and copy are the web page's, so the two surfaces describe the
  /// same deck the same way. A system this build does not recognise is NOT
  /// dropped — it gets its own group under its raw name, the same rule the
  /// Journal applies to an unknown dose slot. Silently hiding a stream the
  /// server sent is the one outcome worse than an ugly heading.
  static func groups(_ deck: [HCCDeckSignal]) -> [Group] {
    let signals = deck.filter { $0.role != "confounder" }
    var out: [Group] = []
    for system in knownSystems {
      let rows = signals.filter { $0.system == system.key }
      if !rows.isEmpty {
        out.append(Group(system: system.key, title: system.title, caption: system.caption, signals: rows))
      }
    }
    let known = Set(knownSystems.map(\.key))
    for system in orderedUniqueSystems(of: signals) where !known.contains(system) {
      let rows = signals.filter { $0.system == system }
      out.append(
        Group(
          system: system,
          title: system.replacingOccurrences(of: "_", with: " ").capitalized,
          caption: "",
          signals: rows
        )
      )
    }
    return out
  }

  private static func orderedUniqueSystems(of signals: [HCCDeckSignal]) -> [String] {
    var seen = Set<String>()
    return signals.compactMap { seen.insert($0.system).inserted ? $0.system : nil }
  }

  private static let knownSystems: [(key: String, title: String, caption: String)] = [
    ("autonomic", "Autonomic", "Nervous-system streams, each scored against its own noise."),
    ("thermo", "Thermo & sleep", "Temperature and the sleep context around it."),
    ("body", "Body composition", "What the scale sees — lean mass is the guarded metric."),
  ]
}

// ── System card ───────────────────────────────────────────────────────────────

private struct SystemCard: View {
  let group: HCCWearablesView.Group

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCLabel(group.title)
        .padding(.bottom, group.caption.isEmpty ? 4 : 2)
      if !group.caption.isEmpty {
        Text(group.caption)
          .font(HCCTheme.Font.body(size: 11.5))
          .foregroundStyle(HCCTheme.Color.muted)
          .padding(.bottom, 4)
      }
      ForEach(Array(group.signals.enumerated()), id: \.element.id) { index, signal in
        SignalRow(signal: signal, showsDivider: index < group.signals.count - 1)
      }
    }
    .hccCard()
  }
}

// ── Signal row ────────────────────────────────────────────────────────────────

/// One stream: its name and 14-day mean, a trace of the window, and the
/// server's verdict — with the baseline it was judged against spelled out
/// underneath, because a σ with no baseline behind it is not a claim anyone can
/// check.
private struct SignalRow: View {
  let signal: HCCDeckSignal
  let showsDivider: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .center, spacing: 10) {
          Circle()
            .fill(HCCWearableVerdict.color(signal.verdict))
            .frame(width: 8, height: 8)

          Text(signal.displayName)
            .font(HCCTheme.Font.body(size: 13))
            .foregroundStyle(HCCTheme.Color.text)
            .lineLimit(1)

          Spacer(minLength: 8)

          // Only beside a real reading. `series` is the stream's history, which
          // outlives the 14-day window — so a stream that stopped reporting
          // still carries points, and drawing them next to `--` and "No data"
          // would put a trend line under a row that says it has nothing. A
          // one-point "trend" is likewise a dot pretending to be a direction.
          if signal.current != nil, signal.series.count > 1 {
            HCCSparkline(
              values: signal.series.map(\.value),
              color: HCCWearableVerdict.color(signal.verdict).opacity(0.9),
              height: 16
            )
            .frame(width: 46)
          }

          HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Self.value(signal))
              .font(HCCTheme.Font.display(size: 15, weight: .semibold))
              .tracking(-0.3)
              .monospacedDigit()
              .foregroundStyle(HCCTheme.Color.text)
            // The unit rides with the number and is dropped with it: a unit
            // beside `--` reads as a scale for a value that is not there.
            if let unit = signal.unit, !unit.isEmpty, signal.current != nil {
              Text(unit)
                .font(HCCTheme.Font.data(size: 9.5))
                .foregroundStyle(HCCTheme.Color.muted)
            }
          }
          .lineLimit(1)
        }

        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(Self.caption(signal))
            .font(HCCTheme.Font.data(size: 10))
            .foregroundStyle(HCCTheme.Color.muted2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          HCCPill(HCCWearableVerdict.label(signal.verdict), tone: HCCWearableVerdict.tone(signal.verdict))
        }
      }
      .padding(.vertical, 9)

      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
  }

  /// The window's mean, at the precision the stream actually carries. A resting
  /// heart rate of "49.0" claims a tenth of a beat nobody measured.
  static func value(_ signal: HCCDeckSignal) -> String {
    guard let current = signal.current, current.isFinite else { return HCCFormat.placeholder }
    let whole = signal.unit == "bpm" || signal.unit == "count" || signal.unit == "kcal/day"
    return HCCFormat.decimal(current, whole ? 0 : 1)
  }

  /// What the verdict was reached against, in the server's own numbers.
  static func caption(_ signal: HCCDeckSignal) -> String {
    if let mean = signal.baselineMean, let sd = signal.baselineSd {
      var text = ""
      if let deviation = signal.deviationSd, deviation.isFinite {
        text += String(format: "%+.1fσ vs ", deviation)
      }
      text += "baseline \(HCCFormat.decimal(mean, 1))"
      text += " ± \(HCCFormat.decimal(sd, 1))"
      if let unit = signal.unit, !unit.isEmpty { text += " \(unit)" }
      text += " · \(signal.baselineNights) nights"
      if signal.daysOutsideBand > 1 {
        text += " · \(signal.daysOutsideBand) days outside band"
      }
      return text
    }
    // No baseline yet. Say which of the two reasons it is rather than printing
    // an empty line: still gathering nights, or nothing arriving at all.
    // The pill already says "Calibrating", so the caption says the one thing it
    // cannot: how far along. The threshold is the server's and is not on the
    // wire, so this counts up rather than inventing an "n of 14".
    if signal.verdict == "calibrating" {
      return signal.baselineNights == 0
        ? "No baseline nights yet"
        : "\(signal.baselineNights) baseline nights so far"
    }
    if let lastSeen = signal.lastSeen, let instant = HCCTime.instant(lastSeen) {
      return "No readings in the window · last seen \(HealthDataStore.hccShortDayLabel(HealthDataStore.hccDayKey(instant)))"
    }
    return "No readings on record"
  }
}

// ── Source row ────────────────────────────────────────────────────────────────

/// One device's contribution: how many streams it wins, when it last reported,
/// and how much of its own span it actually covered.
private struct SourceRow: View {
  let source: String
  let coverage: HCCCoverage?
  let provenance: HCCDeckProvenance?
  let showsDivider: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(HCCCopy.sourceLabel(source))
            .font(HCCTheme.Font.body(size: 13, weight: .medium))
            .foregroundStyle(HCCTheme.Color.text)
          Spacer(minLength: 8)
          // A percentage over a zero-day span is not a measurement — a manual
          // source with one entry and no span would otherwise read "0% wear".
          if let coverage, coverage.spanDays > 0 {
            Text("\(HCCFormat.decimal(coverage.wearPct, 0))%")
              .font(HCCTheme.Font.display(size: 15, weight: .semibold))
              .tracking(-0.3)
              .monospacedDigit()
              .foregroundStyle(HCCTheme.Color.text)
            Text("wear")
              .font(HCCTheme.Font.data(size: 9.5))
              .foregroundStyle(HCCTheme.Color.muted)
          }
        }
        Text(detail)
          .font(HCCTheme.Font.data(size: 10))
          .foregroundStyle(HCCTheme.Color.muted2)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 9)

      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
  }

  private var detail: String {
    var parts: [String] = []
    if let streams = provenance?.streams {
      parts.append(streams == 1 ? "1 stream" : "\(streams) streams")
    }
    if let coverage, coverage.spanDays > 0 {
      parts.append("\(coverage.totalNights) of \(coverage.spanDays) days")
      if let first = coverage.firstDay, let last = coverage.lastDay {
        parts.append(Self.range(from: first, to: last))
      }
    }
    if let lastSeen = provenance?.lastSeenAt, let instant = HCCTime.instant(lastSeen) {
      parts.append("last seen \(HealthDataStore.hccShortDayLabel(HealthDataStore.hccDayKey(instant)))")
    }
    return parts.isEmpty ? "No coverage on record" : parts.joined(separator: " · ")
  }

  /// A span, with the years shown only when it crosses one. This account's own
  /// wrist history runs to six years, and a bare "Oct 9 – Aug 25" reads as ten
  /// months rather than the six years it is.
  static func range(from first: String, to last: String) -> String {
    let firstLabel = HealthDataStore.hccShortDayLabel(first)
    let lastLabel = HealthDataStore.hccShortDayLabel(last)
    let firstYear = String(first.prefix(4))
    let lastYear = String(last.prefix(4))
    guard firstYear != lastYear, firstYear.count == 4, lastYear.count == 4 else {
      return "\(firstLabel) – \(lastLabel)"
    }
    return "\(firstLabel) \(firstYear) – \(lastLabel) \(lastYear)"
  }
}

// ── Verdict vocabulary ────────────────────────────────────────────────────────

/// The deck's five verdicts, in one home.
///
/// The words and the tones are the web page's, deliberately: "steady" is the
/// ACCENT tone there, not green. Green would read as a health verdict, and this
/// scale says nothing about health — only that a stream has or has not moved
/// against its own noise. An unrecognised word draws muted rather than being
/// coloured optimistically.
enum HCCWearableVerdict {
  static func label(_ verdict: String) -> String {
    switch verdict {
    case "steady": "Steady"
    case "watch": "Watch"
    case "flag": "Flag"
    case "calibrating": "Calibrating"
    case "no-data": "No data"
    default: verdict.capitalized
    }
  }

  static func tone(_ verdict: String) -> HCCPill.Tone {
    switch verdict {
    case "steady": .info
    case "watch": .warn
    case "flag": .bad
    default: .muted
    }
  }

  static func color(_ verdict: String) -> Color {
    switch verdict {
    case "steady": HCCTheme.Color.accent
    case "watch": HCCTheme.Color.warn
    case "flag": HCCTheme.Color.bad
    default: HCCTheme.Color.muted
    }
  }
}
