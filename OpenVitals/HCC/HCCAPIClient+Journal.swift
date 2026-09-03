import Foundation

// HCC: the Journal tab's typed calls.
//
// `/api/journal/*` are WEB routes: they answer with `ok()`, which is the object
// itself rather than the read API's `{data, generatedAt, instance}` envelope.
// So every call here goes through one of the client's BARE methods —
// `getBare` for the two reads, and `putBare`/`postBare`/`deleteBare` for the
// three writes. Those share the client's one `send` pipeline, which means these
// calls carry the same bearer closure, the same timeouts and the same
// `failure(status:data:)` mapping as every other call: a 401 here is the same
// `HCCAPIError` a 401 anywhere else is, so the store's sign-out path still
// fires. `send` also does not retry a write, which matters — a replayed POST
// would log a second dose.

extension HCCAPIClient {
  // ── Reads ──────────────────────────────────────────────────────────────────

  /// One civil day: the behavior catalog, that day's answers, the doses it owes
  /// and what has been logged against them. `date` is the SERVER's civil day
  /// key, never one the phone re-bucketed.
  func journalDay(_ date: String) async throws -> HCCJournalDay {
    let response: HCCJournalDayResponse = try await getBare("/api/journal/day/\(date)")
    return response.day
  }

  /// Per-behavior next-day recovery on yes-days vs no-days over `days`.
  func journalImpacts(days: Int) async throws -> HCCJournalImpacts {
    try await getBare("/api/journal/impacts", query: ["days": String(days)])
  }

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Upsert a day's answers. Idempotent on `(date, behaviorId)`, so re-sending
  /// one changed row is safe; an entry with both values cleared is deleted
  /// server-side, which is how an answer becomes unanswered again.
  @discardableResult
  func saveJournalDay(_ date: String, entries: [HCCJournalEntryInput]) async throws -> HCCJournalDay {
    let response: HCCJournalDayResponse = try await putBare(
      "/api/journal/day/\(date)",
      body: HCCJournalDayBody(entries: entries)
    )
    return response.day
  }

  /// Record that a dose was taken. Draws the matching stock down once; never
  /// edits the protocol's dose, status or frequency.
  @discardableResult
  func logJournalDose(_ body: HCCDoseLogBody) async throws -> HCCDoseLogResult {
    try await postBare("/api/journal/doses", body: body)
  }

  /// Undo one logged dose, restoring the stock it drew.
  @discardableResult
  func deleteJournalDose(id: String) async throws -> HCCDoseDeleted {
    try await deleteBare("/api/journal/doses", query: ["id": id])
  }
}
