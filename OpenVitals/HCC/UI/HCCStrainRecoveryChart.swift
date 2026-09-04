import SwiftUI

/// One day of the strain / recovery graph.
///
/// Both values are optional and independently so: a day the band was off the
/// wrist has a recovery and no strain, and a day the engine has not scored yet
/// has neither. Nothing here fills a gap — a missing point is drawn as a gap in
/// the line, which is the honest shape of "no reading".
struct HCCStrainRecoveryPoint: Identifiable {
  /// The server's civil day key. Used as identity, never re-bucketed.
  let day: String
  /// Two-line axis label, e.g. "Thu" over "27".
  let weekday: String
  let dayOfMonth: String
  /// 0–21.
  let strain: Double?
  /// 0–100.
  let recovery: Double?

  var id: String { day }
}

/// `srChart()` from the approved mockup: seven days, strain on the left axis
/// (0–21, strain colour) and recovery on the right (0/33/66/100%, coloured by
/// its band), each point labelled, today's column shaded.
///
/// The mockup's SVG is 300×190 with 30/34/14/30 insets. The height and the
/// insets are kept in points; only the horizontal span stretches to the width
/// it is given, so the chart fills a phone wider than the mockup's 360-pt frame
/// without the labels drifting off the ends.
struct HCCStrainRecoveryChart: View {
  let points: [HCCStrainRecoveryPoint]
  /// Bands for colouring the recovery dots and their labels. The server's own
  /// cutoffs when `/instance` has been read; the published defaults otherwise.
  var bands: HCCScoreBand?
  /// Whether the newest column is TODAY and should get the mockup's shading.
  /// False when the window ends before today, so a stale week is never dressed
  /// up as the current one.
  var highlightsLast: Bool = true

  // Mockup geometry. The plot itself is the mockup's 146 pt tall; the frame is
  // 20 pt taller than the mockup's 190 because strain labels now always sit
  // BELOW their point (see `strainLabelPosition`), and a label under a
  // near-zero strain needs room that does not belong to the day axis.
  private let chartHeight: CGFloat = 210
  private let insetLeading: CGFloat = 30
  private let insetTrailing: CGFloat = 34
  private let insetTop: CGFloat = 14
  private let insetBottom: CGFloat = 50
  /// How far the FIRST and LAST columns sit inside the plot.
  ///
  /// A point label is centred on its column, so a column on the plot edge put
  /// its label half outside the plot and straight through the axis text beside
  /// it — "100%" on day one landed on the strain scale, and on the last day it
  /// landed on the recovery scale. The gridlines still span the full width;
  /// only the columns move in. 12 pt clears the widest label the chart can
  /// draw (a four-character "100%", about 23 pt) with room to spare.
  private let pointInset: CGFloat = 12

  private var innerHeight: CGFloat { chartHeight - insetTop - insetBottom }

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, insetLeading + insetTrailing + 1)
      let innerWidth = width - insetLeading - insetTrailing

      ZStack(alignment: .topLeading) {
        todayColumn(innerWidth: innerWidth)
        strainGrid(width: width)
        recoveryAxis(width: width)
        line(
          values: points.map(\.recovery),
          y: recoveryY,
          innerWidth: innerWidth,
          color: HCCTheme.Color.hex(0x8A93A6),
          lineWidth: 1.5
        )
        line(
          values: points.map(\.strain),
          y: strainY,
          innerWidth: innerWidth,
          color: HCCTheme.Color.strain,
          lineWidth: 1.8
        )
        recoveryPoints(innerWidth: innerWidth)
        strainPoints(innerWidth: innerWidth)
        dayLabels(innerWidth: innerWidth)
      }
      .frame(width: width, height: chartHeight)
    }
    .frame(height: chartHeight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Strain and recovery, last \(points.count) days")
  }

  // ── Scales ─────────────────────────────────────────────────────────────────

  private func x(_ index: Int, innerWidth: CGFloat) -> CGFloat {
    guard points.count > 1 else { return insetLeading + innerWidth / 2 }
    let span = Swift.max(innerWidth - pointInset * 2, 1)
    return insetLeading + pointInset + CGFloat(index) * (span / CGFloat(points.count - 1))
  }

  private func strainY(_ value: Double) -> CGFloat {
    insetTop + innerHeight - CGFloat(value / HCCTheme.strainMax) * innerHeight
  }

  private func recoveryY(_ value: Double) -> CGFloat {
    insetTop + innerHeight - CGFloat(value / 100) * innerHeight
  }

  private func recoveryColor(_ value: Double) -> Color {
    HCCRecoveryBand.band(for: value, bands: bands).color
  }

  // ── Layers ─────────────────────────────────────────────────────────────────

  /// The shaded column behind the newest day.
  @ViewBuilder
  private func todayColumn(innerWidth: CGFloat) -> some View {
    if highlightsLast, !points.isEmpty {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.white.opacity(0.06))
        .frame(width: 36, height: innerHeight + 12)
        .position(
          x: x(points.count - 1, innerWidth: innerWidth),
          y: insetTop - 6 + (innerHeight + 12) / 2
        )
    }
  }

  private func strainGrid(width: CGFloat) -> some View {
    ForEach([0.0, 7.0, 14.0, 21.0], id: \.self) { value in
      let y = strainY(value)
      Path { path in
        path.move(to: CGPoint(x: insetLeading, y: y))
        path.addLine(to: CGPoint(x: width - insetTrailing, y: y))
      }
      .stroke(HCCTheme.Color.line, lineWidth: 1)

      axisText("\(Int(value))", color: HCCTheme.Color.strain)
        .frame(width: 24, alignment: .trailing)
        .position(x: insetLeading - 6 - 12, y: y)
    }
  }

  private func recoveryAxis(width: CGFloat) -> some View {
    ForEach(Self.recoveryTicks, id: \.value) { tick in
      axisText(tick.label, color: tick.color)
        .frame(width: 28, alignment: .leading)
        .position(x: width - insetTrailing + 6 + 14, y: recoveryY(tick.value))
    }
  }

  /// The four labelled recovery gridline values. 0% and 33% share the "rest"
  /// colour in the mockup; both are below the band floor.
  private static let recoveryTicks: [(label: String, value: Double, color: Color)] = [
    ("100%", 100, HCCTheme.Color.rec),
    ("66%", 66, HCCTheme.Color.yellow),
    ("33%", 33, HCCTheme.Color.bad),
    ("0%", 0, HCCTheme.Color.bad),
  ]

  /// A polyline over the days that HAVE a value, broken wherever one is
  /// missing — a straight segment across a gap would draw a reading nobody took.
  private func line(
    values: [Double?],
    y: @escaping (Double) -> CGFloat,
    innerWidth: CGFloat,
    color: Color,
    lineWidth: CGFloat
  ) -> some View {
    Path { path in
      var pen = false
      for (index, value) in values.enumerated() {
        guard let value else {
          pen = false
          continue
        }
        let point = CGPoint(x: x(index, innerWidth: innerWidth), y: y(value))
        if pen {
          path.addLine(to: point)
        } else {
          path.move(to: point)
          pen = true
        }
      }
    }
    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
  }

  private func recoveryPoints(innerWidth: CGFloat) -> some View {
    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
      if let recovery = point.recovery {
        let color = recoveryColor(recovery)
        let y = recoveryY(recovery)
        Circle()
          .fill(HCCTheme.Color.bg)
          .overlay(Circle().strokeBorder(color, lineWidth: 2))
          .frame(width: 8, height: 8)
          .position(x: x(index, innerWidth: innerWidth), y: y)
        // Always above its point. Recovery is the series that keeps its place,
        // so a reader can find the percentage without checking which side it
        // landed on; strain is the one that moves out of the way.
        pointLabel("\(Int(recovery.rounded()))%", color: color)
          .position(x: x(index, innerWidth: innerWidth), y: recoveryLabelY(recovery))
      }
    }
  }

  private func strainPoints(innerWidth: CGFloat) -> some View {
    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
      if let strain = point.strain {
        let y = strainY(strain)
        let strainText = HealthDataStore.hccDecimalText(strain, fractionDigits: 1)
        let recoveryText = point.recovery.map { "\(Int($0.rounded()))%" }
        Circle()
          .fill(HCCTheme.Color.bg)
          .overlay(Circle().strokeBorder(HCCTheme.Color.strain, lineWidth: 2))
          .frame(width: 8, height: 8)
          .position(x: x(index, innerWidth: innerWidth), y: y)
        pointLabel(strainText, color: HCCTheme.Color.strain)
          .position(
            strainLabelPosition(
              index: index,
              strain: strain,
              strainText: strainText,
              recovery: point.recovery,
              recoveryText: recoveryText,
              innerWidth: innerWidth
            )
          )
      }
    }
  }

  // ── Label placement ────────────────────────────────────────────────────────

  /// A recovery label sits 11 pt above its point, never closer than 6 pt to the
  /// top edge — a 100% day would otherwise be clipped by the frame.
  private func recoveryLabelY(_ value: Double) -> CGFloat {
    Swift.max(recoveryY(value) - 11, 6)
  }

  /// A strain label sits 11 pt BELOW its point, and gets out of the way when
  /// the day's recovery point is close enough for the two to collide.
  ///
  /// The two series cross often — on the dev instance's Aug 20–25 week they
  /// cross twice — and where they do, "15.7" lands on top of "84%". Two steps,
  /// in order:
  ///
  ///  1. If the POINTS are within 14 pt, drop the strain label a further 10 pt.
  ///     Labels between two near points have nowhere else to go.
  ///  2. If the two LABELS still share a line, step sideways — far enough to
  ///     actually clear, which is half of each label's width plus a gap, not a
  ///     fixed nudge. Sun 23 is the case that proves it: the points are 24 pt
  ///     apart (so step 1 does not fire) but the labels sit on opposite sides
  ///     of their own points and meet in the middle, and 10 pt of a ~24 pt-wide
  ///     "14.2" still overlaps "51%".
  ///
  /// It is always the STRAIN label that moves, so recovery — the number the
  /// bands are about — keeps a predictable place.
  private func strainLabelPosition(
    index: Int,
    strain: Double,
    strainText: String,
    recovery: Double?,
    recoveryText: String?,
    innerWidth: CGFloat
  ) -> CGPoint {
    var x = x(index, innerWidth: innerWidth)
    var y = strainY(strain) + 11
    guard let recovery, let recoveryText else { return CGPoint(x: x, y: y) }

    if abs(strainY(strain) - recoveryY(recovery)) <= 14 {
      y += 10
    }
    if abs(y - recoveryLabelY(recovery)) < 11 {
      // Half of each label plus a gap: the halves are what makes the two
      // centred labels touch, the gap is what makes them read as two numbers.
      let step = (Self.labelWidth(strainText) + Self.labelWidth(recoveryText)) / 2 + 8
      // Right, unless that runs off the plot — then left. Either way the label
      // stays inside the axes rather than under the recovery percentages.
      let rightEdge = insetLeading + innerWidth
      x += (x + step + Self.labelWidth(strainText) / 2 > rightEdge) ? -step : step
    }
    return CGPoint(x: x, y: y)
  }

  /// Rendered width of a label. The data face is monospaced, so a character
  /// count times the advance is exact enough to place a label with.
  private static func labelWidth(_ text: String) -> CGFloat {
    CGFloat(text.count) * 9.5 * 0.6
  }

  private func dayLabels(innerWidth: CGFloat) -> some View {
    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
      VStack(spacing: 1) {
        axisText(point.weekday, color: HCCTheme.Color.muted)
        axisText(point.dayOfMonth, color: HCCTheme.Color.muted)
      }
      .position(x: x(index, innerWidth: innerWidth), y: chartHeight - 12)
    }
  }

  // ── Text ───────────────────────────────────────────────────────────────────

  private func axisText(_ text: String, color: Color) -> some View {
    Text(text)
      .font(HCCTheme.Font.data(size: 9.5, weight: .medium))
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize()
  }

  private func pointLabel(_ text: String, color: Color) -> some View {
    Text(text)
      .font(HCCTheme.Font.data(size: 9.5, weight: .semibold))
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize()
  }
}

// ── Building the points from the store ───────────────────────────────────────

extension HCCStrainRecoveryChart {
  /// A window of `count` consecutive days from `/scores`, newest last, ending on
  /// the most recent day that actually scored something.
  ///
  /// Anchoring on the last scored day rather than on today is what keeps the
  /// chart from being seven empty columns after a week off the wrist. It does
  /// NOT pretend the window is current: the caller reads `endsToday` and both
  /// drops the today shading and says which day the window ends on. Empty when
  /// the whole history scored nothing — then the tile is hidden entirely.
  static func window(from days: [HCCScoreDay], count: Int = 7) -> [HCCScoreDay] {
    guard let last = days.lastIndex(where: { $0.strain != nil || $0.recovery != nil }) else {
      return []
    }
    return Array(days[Swift.max(0, last - count + 1)...last])
  }

  /// The window as drawable points.
  ///
  /// The day key is the SERVER's bucket; it is parsed here only to produce the
  /// two-line axis label, exactly as `hccDayLabel` does elsewhere.
  static func points(from days: [HCCScoreDay], count: Int = 7) -> [HCCStrainRecoveryPoint] {
    window(from: days, count: count).map { day in
      let date = HealthDataStore.hccLocalDate(fromDayKey: day.date)
      return HCCStrainRecoveryPoint(
        day: day.date,
        weekday: date?.formatted(.dateTime.weekday(.abbreviated)) ?? "",
        dayOfMonth: date?.formatted(.dateTime.day()) ?? day.date,
        strain: day.strain?.value,
        recovery: day.recovery?.value
      )
    }
  }
}
