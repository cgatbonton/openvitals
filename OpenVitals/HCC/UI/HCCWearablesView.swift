import SwiftUI

/// `S.wearables` — the unified wearable deck: every stream this instance
/// collects, graded against its OPTIMAL TARGET.
///
/// REVISED 2026-09-10 (Chris: "they should be graded against optimal targets").
/// The page first shipped grading each stream only against its own rolling
/// baseline, in standard deviations — movement, not position. That is a real
/// reading and it is still here, but it is not what this project means by
/// GRADING. The app grades against the instance profile's optimal bands, and
/// this page now does the same as every other: the pill on each row says
/// whether the stream is in, below or above its target.
///
/// The two readings answer different questions and the row shows both, in
/// their proper order:
///
/// - **the grade** — where the 14-day mean sits against the optimal band
///   (`HCCOptimalRange.grade`), which is the pill and the dot;
/// - **the movement** — how far it has drifted from its OWN baseline in σ, plus
///   the deck's verdict word, which is the muted line underneath.
///
/// A stream with no honest band is NOT graded — no target is invented for it.
/// Those rows fall back to naming the movement verdict and say plainly that no
/// optimal target exists for the stream.
///
/// Everything drawn is the server's: the band, the verdict, the σ, the
/// baselines, the wear coverage. This view invents no value and no target — a
/// stream with no reading in the window says so, and says when it was last
/// seen, instead of showing a stale number as if it were current.
struct HCCWearablesView: View {
  @ObservedObject var store: HealthDataStore
  @StateObject private var load = HCCPageLoad<HCCDeckResponse>()

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Wearables", subtitle: "14-day means · graded vs optimal targets", size: 24)

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
            "Each stream's last 14 days are averaged and graded against your optimal target — "
              + "the instance's own researched band, never a lab reference range. Underneath each "
              + "grade is the second reading: how far the stream has moved from its OWN baseline, "
              + "in standard deviations, with the server's verdict. A stream can be in target and "
              + "still be moving, or off target and perfectly steady. A stream with no honest "
              + "target is not graded."
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
    // The web's caption for this group says these are "scored against their own
    // noise", which was true when the σ was the grade. It is not the grade any
    // more, so the caption describes the streams instead of the method — the
    // method is stated once, in the header and the footnote.
    ("autonomic", "Autonomic", "Nervous-system streams — the first to move."),
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

/// One stream, read top to bottom in the order the project grades things: what
/// it is and what it reads, then how that sits against its OPTIMAL TARGET, then
/// — muted, underneath — how far it has moved from its own baseline.
///
/// The dot and the pill both carry the GRADE, so they cannot disagree. When
/// there is no band, or no value to grade, neither one shows a grade: the pill
/// falls back to naming the movement verdict and the target line says plainly
/// that no optimal target exists. Nothing here manufactures a target.
private struct SignalRow: View {
  let signal: HCCDeckSignal
  let showsDivider: Bool

  /// The grade, and only when there is both a reading and an honest band to
  /// grade it against. Nil means this row is NOT graded — and then nothing on
  /// it may be dressed as a grade.
  private var grade: HCCTargetGrade? {
    guard let current = signal.current, current.isFinite, let optimal = signal.optimal else {
      return nil
    }
    return optimal.grade(current)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .center, spacing: 10) {
          Circle()
            .fill(grade?.color ?? HCCTheme.Color.muted)
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
              color: (grade?.color ?? HCCTheme.Color.muted).opacity(0.9),
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

        // The grade line: the target, and the verdict on it.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(targetText)
            .font(HCCTheme.Font.data(size: 10))
            .foregroundStyle(HCCTheme.Color.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
          Spacer(minLength: 8)
          HCCPill(pillText, tone: pillTone)
        }

        // The second reading, deliberately quieter than the grade above it.
        Text(Self.movement(signal, isGraded: grade != nil))
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

  /// The band this row is graded against, or the plain statement that it has
  /// none. A stream with a band but no reading still shows its target — the
  /// target exists whether or not the wrist reported.
  private var targetText: String {
    guard let text = signal.optimal?.targetText(unit: signal.unit) else {
      return "No optimal target for this stream"
    }
    return "Target \(text)"
  }

  /// The grade when there is one; otherwise the movement verdict, which is then
  /// the only thing this row can honestly say about itself.
  private var pillText: String {
    grade?.label ?? HCCWearableVerdict.label(signal.verdict)
  }

  private var pillTone: HCCPill.Tone {
    grade?.tone ?? HCCWearableVerdict.tone(signal.verdict)
  }

  /// The window's mean, at the precision the stream actually carries. A resting
  /// heart rate of "49.0" claims a tenth of a beat nobody measured.
  static func value(_ signal: HCCDeckSignal) -> String {
    guard let current = signal.current, current.isFinite else { return HCCFormat.placeholder }
    let whole = signal.unit == "bpm" || signal.unit == "count" || signal.unit == "kcal/day"
    return HCCFormat.decimal(current, whole ? 0 : 1)
  }

  /// How far the stream has moved against its OWN baseline — the deck's
  /// original reading, kept underneath the grade.
  ///
  /// `isGraded` decides whether the verdict word is appended: when the row is
  /// not graded the pill is already showing that word, and printing it twice on
  /// one row reads as two different findings.
  static func movement(_ signal: HCCDeckSignal, isGraded: Bool) -> String {
    var parts: [String] = []

    if let mean = signal.baselineMean, let sd = signal.baselineSd {
      var text = ""
      if let deviation = signal.deviationSd, deviation.isFinite {
        text += String(format: "%+.1fσ vs ", deviation)
      }
      text += "baseline \(HCCFormat.decimal(mean, 1)) ± \(HCCFormat.decimal(sd, 1))"
      if let unit = signal.unit, !unit.isEmpty { text += " \(unit)" }
      text += " · \(signal.baselineNights) nights"
      parts.append(text)
      if signal.daysOutsideBand > 1 {
        parts.append("\(signal.daysOutsideBand) days outside band")
      }
    } else if signal.verdict == "calibrating" {
      // The threshold is the server's and is not on the wire, so this counts up
      // rather than inventing an "n of 14".
      parts.append(
        signal.baselineNights == 0
          ? "No baseline nights yet"
          : "\(signal.baselineNights) baseline nights so far"
      )
    } else if let lastSeen = signal.lastSeen, let instant = HCCTime.instant(lastSeen) {
      parts.append(
        "No readings in the window · last seen "
          + HealthDataStore.hccShortDayLabel(HealthDataStore.hccDayKey(instant))
      )
    } else {
      parts.append("No readings on record")
    }

    if isGraded { parts.append(HCCWearableVerdict.label(signal.verdict)) }
    return parts.joined(separator: " · ")
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
