import SwiftUI

// HCC: root of the Journal tab in cloud mode.

/// The Journal tab — `S.journal` from the approved "C · Command" mockup.
///
/// Three cards, in the order the mockup has them: the behaviors the owner
/// answers for a day, the doses that day owes from the active protocols, and
/// what the answers have actually cost or bought in next-day recovery.
///
/// It deliberately does NOT list the day's activities. Home already owns that
/// list, and two places showing the same rows is how they end up disagreeing.
///
/// The day navigator in the header is what makes a missed day fixable: the
/// impact maths only counts days that were answered, so a journal that could
/// only be filled in on the day itself would quietly lose every busy evening.
struct HCCJournalView: View {
  @ObservedObject var store: HealthDataStore

  var body: some View {
    HCCJournalScreen(store: store, state: store.hccJournal)
  }
}

private struct HCCJournalScreen: View {
  @ObservedObject var store: HealthDataStore
  @ObservedObject var state: HCCJournalState

  /// The day on screen, as the SERVER's civil day key. Held as a key rather
  /// than a `Date` because that is what the cache, the reads and the writes all
  /// speak; a `Date` here would need re-bucketing at every use.
  @State private var dayKey = HealthDataStore.hccDayKey(Date())
  @State private var didRunDebugLaunch = false
  @State private var didRunDebugSave = false

  var body: some View {
    ScrollViewReader { scroller in
      HCCScreen {
        header
        if let error = state.lastError {
          HCCErrorNote(error, retry: { await store.loadJournal(day: dayKey, force: true) })
        }
        if !HCCJournalAnchor.isImpactsOnly {
          // Doses first (DECISION 2026-09-03, Chris): the stack is what gets
          // ticked every day, so it should not sit behind a scroll past the
          // behaviors. Behaviors stay a full card, just underneath.
          dosesCard.id(HCCJournalAnchor.doses.rawValue)
          behaviorsCard.id(HCCJournalAnchor.behaviors.rawValue)
        }
        impactsCard.id(HCCJournalAnchor.impacts.rawValue)
      }
      .onAppear { scrollToDebugAnchorIfRequested(scroller) }
    }
    .refreshable { await store.loadJournal(day: dayKey, force: true) }
    .task(id: dayKey) {
      await store.loadJournal(day: dayKey)
      await runDebugSaveIfRequested()
    }
    .task(id: state.doseWarning) { await clearDoseWarningAfterDelay() }
    .onAppear(perform: runDebugLaunchHookIfRequested)
  }

  // ── The day being shown ────────────────────────────────────────────────────

  private var day: HCCJournalDay? { state.day(dayKey) }

  private var hasLoaded: Bool { state.hasLoaded(dayKey) }

  private var todayKey: String { HealthDataStore.hccDayKey(Date()) }

  private var isToday: Bool { dayKey == todayKey }

  /// "Today" / "Yesterday" / "Sep 1", from the instance's calendar.
  private var relativeLabel: String { HealthDataStore.hccDayLabel(dayKey) }

  /// "Tue, Sep 1" — the mockup's dated half of the subtitle, drawn in the
  /// instance's zone so a phone in another one does not name the wrong weekday.
  private var datedLabel: String {
    guard let date = HealthDataStore.hccLocalDate(fromDayKey: dayKey) else { return dayKey }
    var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
    style.timeZone = HealthDataStore.hccInstanceTimeZone
    return date.formatted(style)
  }

  /// "Today · Tue, Sep 1". A day that is neither today nor yesterday already
  /// reads as a date, so it is not said twice.
  private var subtitle: String {
    relativeLabel == datedLabel || !isRelative ? datedLabel : "\(relativeLabel) · \(datedLabel)"
  }

  private var isRelative: Bool { relativeLabel == "Today" || relativeLabel == "Yesterday" }

  private func step(days: Int) {
    guard let current = HealthDataStore.hccLocalDate(fromDayKey: dayKey),
          let next = HealthDataStore.hccInstanceCalendar.date(byAdding: .day, value: days, to: current)
    else {
      return
    }
    let key = HealthDataStore.hccDayKey(next)
    // Forward stops at today: the journal records what happened, and there is
    // nothing to answer about a day that has not been lived yet.
    guard key <= todayKey else { return }
    dayKey = key
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      HCCDetailHeader(title: "Journal", subtitle: subtitle, showsBack: false)
      HCCDayNav(
        label: relativeLabel,
        canGoBack: true,
        canGoForward: !isToday,
        goBack: { step(days: -1) },
        goForward: { step(days: 1) }
      )
    }
  }

  // ── Behaviors ──────────────────────────────────────────────────────────────

  private var behaviorsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HCCLabel("Behaviors", size: 11)
        .padding(.bottom, 8)

      if let day {
        let behaviors = day.visibleBehaviors
        if behaviors.isEmpty {
          HCCEmptyNote("No behaviors set up on this instance yet.")
        } else {
          ForEach(Array(behaviors.enumerated()), id: \.element.id) { index, behavior in
            behaviorRow(behavior, day: day, showsDivider: index < behaviors.count - 1)
          }
          HCCFootnote("Tap to answer yes or no. Long-press an answered behavior to clear it.")
            .padding(.top, 8)
        }
      } else if hasLoaded {
        HCCEmptyNote("No journal for \(relativeLabel.lowercased()).")
      } else {
        HCCLoadingNote()
      }
    }
    .hccCard()
  }

  @ViewBuilder
  private func behaviorRow(_ behavior: HCCJournalBehavior, day: HCCJournalDay, showsDivider: Bool) -> some View {
    let entry = day.entry(behaviorId: behavior.id)
    switch behavior.kind {
    case .boolean:
      HCCBehaviorToggleRow(
        label: behavior.label,
        answer: Self.answer(entry),
        showsDivider: showsDivider,
        onTap: {
          // Unanswered and "no" both go to yes; a yes goes to no. Clearing is
          // the long press, so a stray tap can never wipe an answer.
          let next = Self.answer(entry) == .yes ? false : true
          write(behavior, valueBool: next, valueNum: nil)
        },
        onClear: { write(behavior, valueBool: nil, valueNum: nil) }
      )
    case .number:
      HCCBehaviorNumberRow(
        label: behavior.label,
        unit: behavior.unit ?? "",
        value: Int((entry?.valueNum ?? 0).rounded()),
        isAnswered: entry?.valueNum != nil,
        showsDivider: showsDivider,
        onChange: { write(behavior, valueBool: nil, valueNum: Double($0)) },
        onClear: { write(behavior, valueBool: nil, valueNum: nil) }
      )
    }
  }

  /// Nil entry, or an entry whose boolean was cleared, is UNANSWERED — never a
  /// "no". The server deletes a cleared row for the same reason.
  private static func answer(_ entry: HCCJournalEntry?) -> HCCBehaviorAnswer {
    guard let value = entry?.valueBool else { return .unanswered }
    return value ? .yes : .no
  }

  private func write(_ behavior: HCCJournalBehavior, valueBool: Bool?, valueNum: Double?) {
    let key = dayKey
    Task {
      await store.setJournalBehavior(
        day: key,
        behaviorId: behavior.id,
        valueBool: valueBool,
        valueNum: valueNum
      )
    }
  }

  // ── Doses ──────────────────────────────────────────────────────────────────

  private var dosesCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        // "Doses today" only when the day on screen IS today; on a back day the
        // word would be a small lie about which day is being ticked.
        HCCLabel(isToday ? "Doses today" : "Doses", size: 11)
        Spacer(minLength: 8)
        HCCChip("from active protocols")
      }
      .padding(.bottom, 8)

      if let day {
        if day.due.isEmpty {
          HCCEmptyNote("No doses due from active protocols.")
        } else {
          ForEach(Array(day.due.enumerated()), id: \.element.id) { index, due in
            doseRow(due, showsDivider: index < day.due.count - 1)
          }
        }
      } else if hasLoaded {
        HCCEmptyNote("No doses due from active protocols.")
      } else {
        HCCLoadingNote()
      }

      if let warning = state.doseWarning {
        HCCFootnote(warning)
          .padding(.top, 8)
      }
    }
    .hccCard()
  }

  private func doseRow(_ due: HCCDueDose, showsDivider: Bool) -> some View {
    let taken = state.isDoseTaken(due)
    return HCCDoseCheckRow(
      title: Self.doseTitle(due),
      subtitle: nil,
      doseText: Self.doseText(due),
      count: due.expectedPerDay > 1 ? "\(due.takenCount)/\(due.dueCount)" : nil,
      // A cycling product skips days by design; saying so is what stops a blank
      // line reading as a missed dose. It stays tappable so an off-schedule
      // dose can still be recorded.
      note: due.dueCount == 0 ? "not due today" : nil,
      isTaken: taken,
      showsDivider: showsDivider,
      onTap: {
        let key = dayKey
        Task {
          if taken {
            await store.undoJournalDose(day: key, due: due)
          } else {
            await store.logJournalDose(day: key, due: due)
          }
        }
      }
    )
  }

  /// What the row is called: the supplement, not the protocol it belongs to.
  ///
  /// DECISION 2026-09-03 (Chris): the protocol title ("Daily Foundational
  /// Supplement Stack") is repeated down every row of a stack and says nothing
  /// the card's own header does not, so the product name is the whole label.
  ///
  /// It falls BACK to the protocol title, because `productName` is null for a
  /// protocol with no linked product — a free-text regimen like a peptide
  /// course — and those rows have no other name. Dropping the title outright
  /// would leave them blank, which is the one thing worse than a repeated word.
  static func doseTitle(_ due: HCCDueDose) -> String {
    if let name = due.productName, !name.isEmpty { return name }
    return due.protocolTitle
  }

  /// The protocol's free-text regimen when it has one, otherwise the product's
  /// structured draw. Never both, and never a number parsed out of the text.
  private static func doseText(_ due: HCCDueDose) -> String {
    if let text = due.doseText, !text.isEmpty { return text }
    guard let amount = due.amount, amount.isFinite else { return HCCFormat.placeholder }
    let number = amountText(amount)
    guard let unit = due.unit, !unit.isEmpty else { return number }
    return "\(number) \(unit)"
  }

  /// "3.2", "1", "0.1" — up to two decimals, with the trailing zeros the
  /// server's floats carry taken off.
  private static func amountText(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    return String(format: "%g", rounded)
  }

  private func clearDoseWarningAfterDelay() async {
    guard state.doseWarning != nil else { return }
    try? await Task.sleep(for: .seconds(5))
    guard !Task.isCancelled else { return }
    state.doseWarning = nil
  }

  // ── Impacts ────────────────────────────────────────────────────────────────

  private var impactsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        HCCLabel("Impact on recovery", size: 11)
        Spacer(minLength: 8)
        HCCChip("\(HealthDataStore.hccJournalImpactDays) days")
      }
      .padding(.bottom, 8)

      if let impacts = state.impacts {
        if impacts.impacts.isEmpty {
          HCCEmptyNote("No behaviors answered in this window yet.")
        } else {
          HCCImpactGrid(rows: impacts.sortedRows.map(Self.gridRow))
        }
        HCCFootnote(
          "Shown once a behavior has at least \(impacts.minDays) yes and \(impacts.minDays) no days."
        )
        .padding(.top, 8)
      } else {
        HCCLoadingNote()
      }
    }
    .hccCard()
  }

  /// One impact row reduced to the three strings the grid draws.
  ///
  /// The recovery entry is the one this card is about; the server has already
  /// resolved it from `hcc_recovery` then `whoop_recovery`, so no slug is
  /// chosen here. A row under the day gate shows its sample size and how much
  /// more it needs — never a delta, because there is not one yet.
  private static func gridRow(_ row: HCCImpactRow) -> HCCImpactGridRow {
    let counts = "\(row.nYes) / \(row.nNo)"
    guard row.eligible, let delta = row.recovery?.delta, delta.isFinite else {
      let needed = row.moreNeeded
      return HCCImpactGridRow(
        id: row.slug,
        label: row.label,
        delta: nil,
        isImprovement: nil,
        counts: needed > 0 ? "\(counts) · needs \(needed) more" : counts
      )
    }
    let whole = delta.rounded()
    let sign = whole > 0 ? "+" : whole < 0 ? "\u{2212}" : ""
    return HCCImpactGridRow(
      id: row.slug,
      label: row.label,
      delta: "\(sign)\(Int(abs(whole)))%",
      // Recovery is a score where up is the good direction, so the sign maps
      // straight onto the colour. It would not for resting heart rate, which
      // is why this card reads only the recovery entry.
      isImprovement: whole == 0 ? nil : whole > 0,
      counts: counts
    )
  }
}

// ── Debug launch hooks ───────────────────────────────────────────────────────

/// The scroll targets `HCC_DEBUG_JOURNAL_ANCHOR` can name.
///
/// The Journal is about two screens tall and `simctl` cannot scroll, so the
/// doses and impact cards need a launch-time way to be brought into view for a
/// screenshot — the same trick `HCC_DEBUG_HOME_ANCHOR` uses for Home.
enum HCCJournalAnchor: String, CaseIterable {
  case behaviors
  case doses
  case impacts
  /// Draws the impact card ALONE. The two cards above it are taller than a
  /// phone, and the cloud shell's bottom inset does not currently reach
  /// `HCCScreen`'s scroll view (see the note in `docs/hcc-provider.md`), so the
  /// last card cannot be scrolled clear of the tab bar for a screenshot. DEBUG
  /// only — it changes nothing about how the tab renders in the app.
  case impactsOnly

  static var isImpactsOnly: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["HCC_DEBUG_JOURNAL_ANCHOR"] == Self.impactsOnly.rawValue
    #else
    false
    #endif
  }
}

private extension HCCJournalScreen {
  func scrollToDebugAnchorIfRequested(_ scroller: ScrollViewProxy) {
    #if DEBUG
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_JOURNAL_ANCHOR"],
          let anchor = HCCJournalAnchor(rawValue: raw)
    else {
      return
    }
    // After the read lands, so the card being aimed at has its height. Twice,
    // because the impact card only gets its rows on the second of the two.
    // The last card cannot reach the top of the viewport — there is nothing
    // below it to scroll up — so it is aimed at the bottom edge instead.
    let edge: UnitPoint = anchor == .impacts ? .bottom : .top
    Task { @MainActor in
      for delay in [2, 4] {
        try? await Task.sleep(for: .seconds(delay))
        scroller.scrollTo(anchor.rawValue, anchor: edge)
      }
    }
    #endif
  }

  /// `HCC_DEBUG_SAVE=1` — answer the first two yes/no behaviors (one yes, one
  /// no) and log the first due dose, through the same store writes a tap goes
  /// through. `simctl` cannot tap, and this is the only way to prove the write
  /// path end to end without UI automation. Same contract, and the same
  /// warning, as the alarm and dashboard sheets: it MUTATES SERVER STATE, so it
  /// is never set against an instance whose data you are not willing to change.
  func runDebugSaveIfRequested() async {
    #if DEBUG
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SAVE"] == "1" else { return }
    guard !didRunDebugSave, let day = state.day(dayKey) else { return }
    didRunDebugSave = true

    let booleans = day.visibleBehaviors.filter { $0.kind == .boolean }
    if let first = booleans.first {
      await store.setJournalBehavior(day: dayKey, behaviorId: first.id, valueBool: true, valueNum: nil)
    }
    if booleans.count > 1 {
      await store.setJournalBehavior(day: dayKey, behaviorId: booleans[1].id, valueBool: false, valueNum: nil)
    }
    if let due = state.day(dayKey)?.due.first {
      await store.logJournalDose(day: dayKey, due: due)
    }
    #endif
  }
}

private extension HCCJournalScreen {
  /// `HCC_DEBUG_OPEN_DATE=YYYY-MM-DD` — which day the Journal opens on.
  /// `simctl` cannot tap the day navigator, so a screenshot of a back day needs
  /// a launch-time way in. DEBUG only, and a no-op without the variable; reach
  /// the tab itself with `HCC_DEBUG_OPEN_TAB=journal`.
  func runDebugLaunchHookIfRequested() {
    #if DEBUG
    guard !didRunDebugLaunch else { return }
    didRunDebugLaunch = true
    guard let requested = HCCDebugScreen.requestedDayKey,
          HealthDataStore.hccLocalDate(fromDayKey: requested) != nil
    else {
      return
    }
    dayKey = requested
    #endif
  }
}
