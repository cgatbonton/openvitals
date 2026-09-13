import Foundation
import SwiftUI

// HCC: the Journal tab's state and its writes.
//
// One box per feature, reached through `HCCStoreState.slot(_:)`, so adding the
// Journal never edits `HealthDataStore+HCC.swift` and the view observes exactly
// the object it draws from.
//
// Every write follows the pattern `docs/hcc-provider.md` sets out: apply the
// change locally so the control answers the tap, call the server, reconcile
// with what came back, and on failure put the previous state back and record
// the server's own message. A control that rolled back never looks like one
// that saved. A 401 anywhere hands the session to `HCCSession`.

/// Journal state: the days that have been read, the impact roll-up, and what
/// is currently in flight.
@MainActor
final class HCCJournalState: ObservableObject {
  /// Read days, keyed by the SERVER's civil day string.
  @Published var dayByDate: [String: HCCJournalDay] = [:]
  @Published var impacts: HCCJournalImpacts?
  @Published var loading = false
  @Published var lastError: String?

  /// The server's sentence when a dose was logged but stock was deliberately
  /// not drawn. Cleared on a timer by the view that showed it.
  @Published var doseWarning: String?

  /// Behavior ids with a PUT in flight. The row stays tappable, but a second
  /// tap on the same behavior is ignored so two writes cannot race to decide
  /// the same answer.
  @Published var savingBehaviorIds: Set<String> = []

  /// Row ids (`HCCDueDose.id` — the server's `key`, so one of a split pair's
  /// rows is its own entry here) with a dose write in flight, and the direction
  /// it is going. The check row reads this so the box flips on the tap rather
  /// than after the round trip.
  @Published var pendingDoses: [String: Bool] = [:]

  /// Day keys whose first read has not answered yet — used to tell "loading"
  /// apart from "loaded and empty".
  fileprivate var loadedDays: Set<String> = []

  func day(_ key: String) -> HCCJournalDay? { dayByDate[key] }

  func hasLoaded(_ key: String) -> Bool { loadedDays.contains(key) }

  /// Whether the dose line should render as taken right now: the pending
  /// direction while a write is in flight, otherwise the server's count.
  func isDoseTaken(_ due: HCCDueDose) -> Bool {
    pendingDoses[due.id] ?? (due.takenCount > 0)
  }
}

// ── The slot ─────────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// The one Journal box for this store.
  var hccJournal: HCCJournalState { hcc.slot { HCCJournalState() } }
}

// ── Reads ────────────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// The window the impact card reports over. Fixed for now; the card says so
  /// on its chip, so the number and the label cannot drift apart.
  static let hccJournalImpactDays = 90

  /// Load one day, and the impact roll-up alongside it.
  ///
  /// `force` re-reads a day already in the cache — what pull-to-refresh wants.
  /// Without it, stepping back to a day already seen is instant and silent.
  func loadJournal(day: String, force: Bool = false) async {
    let state = hccJournal
    if !force, state.hasLoaded(day), state.impacts != nil { return }

    state.loading = true
    state.lastError = nil

    async let dayRead = HCCSession.shared.client.journalDay(day)
    async let impactRead = HCCSession.shared.client.journalImpacts(days: Self.hccJournalImpactDays)

    var failure: Error?
    do {
      let loaded = try await dayRead
      // Keyed on the date the SERVER answered with, not the one asked for.
      state.dayByDate[loaded.date] = loaded
      state.loadedDays.insert(loaded.date)
      state.loadedDays.insert(day)
    } catch {
      failure = error
    }
    do {
      state.impacts = try await impactRead
    } catch {
      // The day is the screen; the impact card is an extra. Only report the
      // impact failure when the day itself arrived, so one error line shows.
      if failure == nil { failure = error }
    }

    // A cancelled read is not a failed one. Stepping the day navigator (or the
    // debug launch hook picking a day) retargets `.task(id:)`, which cancels the
    // read already in flight — reporting that as an error would put "not loaded"
    // over a screen that is, at that moment, loading the day the user asked for.
    // The newer task owns `loading` and `lastError` from here on.
    guard !Task.isCancelled, !Self.hccJournalIsCancellation(failure) else { return }

    state.loading = false
    if let failure { hccJournalRecord(failure, on: state) }
  }

  /// Whether an error is "the caller went away", in any of the shapes it
  /// arrives in: Swift's own, and the one `URLSession` reports.
  private static func hccJournalIsCancellation(_ error: Error?) -> Bool {
    guard let error else { return false }
    if error is CancellationError { return true }
    if let apiError = error as? HCCAPIError, case let .transport(underlying) = apiError {
      return underlying is CancellationError || (underlying as? URLError)?.code == .cancelled
    }
    return (error as? URLError)?.code == .cancelled
  }
}

// ── Writes ───────────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// Answer, change or clear one behavior for one day.
  ///
  /// Both values `nil` clears the answer — the server deletes the row, and the
  /// behavior goes back to unanswered rather than becoming a "no".
  @discardableResult
  func setJournalBehavior(
    day: String,
    behaviorId: String,
    valueBool: Bool?,
    valueNum: Double?
  ) async -> Bool {
    let state = hccJournal
    guard let previous = state.dayByDate[day] else { return false }
    guard !state.savingBehaviorIds.contains(behaviorId) else { return false }

    state.savingBehaviorIds.insert(behaviorId)
    state.lastError = nil
    state.dayByDate[day] = Self.hccJournalDay(
      previous,
      settingBehavior: behaviorId,
      valueBool: valueBool,
      valueNum: valueNum
    )

    defer { state.savingBehaviorIds.remove(behaviorId) }
    do {
      // The PUT carries only the row that changed: the upsert is keyed on
      // `(date, behaviorId)`, so sending the whole form would rewrite answers
      // another device may have changed since this day was read.
      let saved = try await HCCSession.shared.client.saveJournalDay(
        day,
        entries: [
          HCCJournalEntryInput(
            behaviorId: behaviorId,
            valueBool: valueBool,
            valueNum: valueNum,
            notes: nil
          )
        ]
      )
      state.dayByDate[saved.date] = saved
      state.loadedDays.insert(saved.date)
      return true
    } catch {
      state.dayByDate[day] = previous
      hccJournalRecord(error, on: state)
      return false
    }
  }

  /// Record one dose of a due line as taken.
  @discardableResult
  func logJournalDose(day: String, due: HCCDueDose) async -> Bool {
    let state = hccJournal
    guard state.pendingDoses[due.id] == nil else { return false }

    state.pendingDoses[due.id] = true
    state.lastError = nil
    state.doseWarning = nil

    // Stamped HERE, at the tap, and never left to the server's `now()`. See
    // `HCCDoseLogBody.takenAt` and `hccDoseTakenAt` for the two days this
    // otherwise files a dose on: the day the request finally lands, and today
    // when the owner is filling in a back day.
    let takenAt = Self.hccDoseTakenAt(day: day)

    defer { state.pendingDoses[due.id] = nil }
    do {
      let result = try await HCCSession.shared.client.logJournalDose(
        HCCDoseLogBody(
          protocolId: due.protocolId,
          productId: due.productId,
          amount: due.amount,
          unit: due.unit,
          takenAt: takenAt
        )
      )
      // Reconcile from the server's own row rather than a fabricated one: the
      // log's id is what a later undo deletes, and the amount and unit are the
      // ones the server actually drew.
      if let current = state.dayByDate[day] {
        state.dayByDate[day] = Self.hccJournalDay(current, appending: result.log)
      }
      state.doseWarning = result.warning
      return true
    } catch {
      hccJournalRecord(error, on: state)
      return false
    }
  }

  /// Undo the most recent dose logged against a due line's PAIR on this day.
  ///
  /// The pair, not the row: a `DoseLog` carries no slot, so for one of the rows
  /// a twice-daily pair splits into (`splitBySlots`) there is no log that names
  /// it, and keying the lookup on the row's `id` meant undo silently did nothing
  /// on the Dinner half of Floratil and nitazoxanide.
  ///
  /// The accepted semantics, matching the web page's: undoing from EITHER row of
  /// a split pair removes the newest log for the pair, which under the server's
  /// positional attribution unchecks the LAST checked row rather than the row
  /// that was tapped. That is intended, not a rough edge tolerated — the logs
  /// share one pool and their timestamps cannot be read as a slot either (a dose
  /// is stamped at the tap, and a back day at midday), so with one undo
  /// affordance "undo" can only honestly mean "the last dose I logged".
  @discardableResult
  func undoJournalDose(day: String, due: HCCDueDose) async -> Bool {
    let state = hccJournal
    guard state.pendingDoses[due.id] == nil else { return false }
    guard let current = state.dayByDate[day],
          let newest = current
            .logs(forProtocolId: due.protocolId, productId: due.productId)
            .last
    else {
      return false
    }

    state.pendingDoses[due.id] = false
    state.lastError = nil
    state.doseWarning = nil

    defer { state.pendingDoses[due.id] = nil }
    do {
      _ = try await HCCSession.shared.client.deleteJournalDose(id: newest.id)
      if let latest = state.dayByDate[day] {
        state.dayByDate[day] = Self.hccJournalDay(latest, removingLogId: newest.id)
      }
      return true
    } catch {
      hccJournalRecord(error, on: state)
      return false
    }
  }

  /// The instant a dose ticked on `day` should be recorded at.
  ///
  /// Today's screen stamps the tap itself. A BACK day cannot — "now" is not a
  /// time on that day at all, and a dose ticked while catching up on yesterday
  /// would land on today, where it was neither due nor taken. Midday of the
  /// civil day is used instead: it is inside that day's bounds in the instance's
  /// zone by a twelve-hour margin, so no clock change can push it into a
  /// neighbour. The journal's whole day navigator exists to make a missed day
  /// fixable, and a fix that files itself under the wrong day is not one.
  ///
  /// A day key the calendar cannot read falls back to the tap, which is the same
  /// behaviour as before this existed.
  static func hccDoseTakenAt(day: String) -> String {
    if day == hccDayKey(Date()) { return HCCTime.isoInstant(Date()) }
    guard let midnight = hccLocalDate(fromDayKey: day),
          let midday = hccInstanceCalendar.date(byAdding: .hour, value: 12, to: midnight)
    else {
      return HCCTime.isoInstant(Date())
    }
    return HCCTime.isoInstant(midday)
  }

  private func hccJournalRecord(_ error: Error, on state: HCCJournalState) {
    if let apiError = error as? HCCAPIError {
      if case .unauthorized = apiError { HCCSession.shared.handleUnauthorized() }
      state.lastError = apiError.errorDescription
    } else {
      state.lastError = error.localizedDescription
    }
  }
}

// ── Local edits to a cached day ──────────────────────────────────────────────
//
// Pure rewrites of one immutable day into the next one. Kept `static` and
// value-only so the optimistic edit and the rollback are the same shape of
// operation, and so neither can accidentally reach the network.

private extension HealthDataStore {
  static func hccJournalDay(
    _ day: HCCJournalDay,
    settingBehavior behaviorId: String,
    valueBool: Bool?,
    valueNum: Double?
  ) -> HCCJournalDay {
    var entries = day.entries.filter { $0.behaviorId != behaviorId }
    if valueBool != nil || valueNum != nil {
      let slug = day.behaviors.first { $0.id == behaviorId }?.slug ?? ""
      let existing = day.entry(behaviorId: behaviorId)
      entries.append(
        HCCJournalEntry(
          behaviorId: behaviorId,
          slug: slug,
          valueBool: valueBool,
          valueNum: valueNum,
          notes: existing?.notes
        )
      )
    }
    return HCCJournalDay(
      date: day.date,
      behaviors: day.behaviors,
      entries: entries,
      due: day.due,
      logs: day.logs
    )
  }

  static func hccJournalDay(_ day: HCCJournalDay, appending log: HCCDoseLog) -> HCCJournalDay {
    HCCJournalDay(
      date: day.date,
      behaviors: day.behaviors,
      entries: day.entries,
      due: hccJournalDue(day.due, matching: log, adjustingBy: 1),
      logs: day.logs + [log]
    )
  }

  static func hccJournalDay(_ day: HCCJournalDay, removingLogId id: String) -> HCCJournalDay {
    guard let removed = day.logs.first(where: { $0.id == id }) else { return day }
    return HCCJournalDay(
      date: day.date,
      behaviors: day.behaviors,
      entries: day.entries,
      due: hccJournalDue(day.due, matching: removed, adjustingBy: -1),
      logs: day.logs.filter { $0.id != id }
    )
  }

  /// Move one taken dose onto (or off) the right row of a log's PAIR.
  ///
  /// Which row of a split pair shows the tick is the SERVER's decision on the
  /// next read, and it attributes positionally: first log of the day to the
  /// first row, the last row absorbing anything over what the pair owes. This
  /// reproduces that same rule locally, because the optimistic edit and the
  /// answer that follows it must not disagree — matching on the row identity
  /// instead (`id == log.dueKey`, as this did before the split landed) found no
  /// row at all for a split pair, so a ticked Dinner dose un-ticked itself the
  /// moment the write returned and the pending flag cleared.
  ///
  /// `day.due` carries a pair's split rows in slot order, which is the order
  /// positional attribution counts in, so array order is the right order here.
  static func hccJournalDue(
    _ due: [HCCDueDose],
    matching log: HCCDoseLog,
    adjustingBy delta: Int
  ) -> [HCCDueDose] {
    let rows = due.indices.filter {
      due[$0].protocolId == log.protocolId && due[$0].productId == log.productId
    }
    guard let lastRow = rows.last else { return due }

    let target: Int?
    if delta > 0 {
      // The first row of the pair that is not yet taken; an extra dose beyond
      // what the pair owes piles onto the last one, as the server's own
      // arithmetic does rather than inventing a third row.
      target = rows.first(where: { due[$0].takenCount == 0 }) ?? lastRow
    } else {
      // The mirror: the LAST row that is taken, which is the one the newest log
      // of the pair is attributed to.
      target = rows.last(where: { due[$0].takenCount > 0 })
    }

    guard let index = target else { return due }
    var next = due
    next[index] = next[index].adjustingTakenCount(by: delta)
    return next
  }
}

private extension HCCDueDose {
  /// The same due line with one more (or one fewer) dose counted against it.
  /// Only `takenCount` moves — what the day OWES is the server's derivation
  /// from the protocol and never changes because a dose was ticked.
  func adjustingTakenCount(by delta: Int) -> HCCDueDose {
    HCCDueDose(
      key: key,
      protocolId: protocolId,
      protocolTitle: protocolTitle,
      label: label,
      productId: productId,
      productName: productName,
      unit: unit,
      amount: amount,
      doseText: doseText,
      dueCount: dueCount,
      takenCount: max(0, takenCount + delta),
      expectedPerDay: expectedPerDay,
      cadence: cadence,
      slot: slot
    )
  }
}
