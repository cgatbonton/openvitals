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

  /// Due keys (`protocolId|productId`) with a dose write in flight, and the
  /// direction it is going. The check row reads this so the box flips on the
  /// tap rather than after the round trip.
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

    defer { state.pendingDoses[due.id] = nil }
    do {
      let result = try await HCCSession.shared.client.logJournalDose(
        HCCDoseLogBody(
          protocolId: due.protocolId,
          productId: due.productId,
          amount: due.amount,
          unit: due.unit
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

  /// Undo the most recent dose logged against a due line on this day.
  @discardableResult
  func undoJournalDose(day: String, due: HCCDueDose) async -> Bool {
    let state = hccJournal
    guard state.pendingDoses[due.id] == nil else { return false }
    guard let current = state.dayByDate[day],
          let newest = current.logs(forDueKey: due.id).last
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
      due: day.due.map { $0.id == log.dueKey ? $0.adjustingTakenCount(by: 1) : $0 },
      logs: day.logs + [log]
    )
  }

  static func hccJournalDay(_ day: HCCJournalDay, removingLogId id: String) -> HCCJournalDay {
    guard let removed = day.logs.first(where: { $0.id == id }) else { return day }
    return HCCJournalDay(
      date: day.date,
      behaviors: day.behaviors,
      entries: day.entries,
      due: day.due.map { $0.id == removed.dueKey ? $0.adjustingTakenCount(by: -1) : $0 },
      logs: day.logs.filter { $0.id != id }
    )
  }
}

private extension HCCDueDose {
  /// The same due line with one more (or one fewer) dose counted against it.
  /// Only `takenCount` moves — what the day OWES is the server's derivation
  /// from the protocol and never changes because a dose was ticked.
  func adjustingTakenCount(by delta: Int) -> HCCDueDose {
    HCCDueDose(
      protocolId: protocolId,
      protocolTitle: protocolTitle,
      productId: productId,
      productName: productName,
      unit: unit,
      amount: amount,
      doseText: doseText,
      dueCount: dueCount,
      takenCount: max(0, takenCount + delta),
      expectedPerDay: expectedPerDay,
      cadence: cadence
    )
  }
}
