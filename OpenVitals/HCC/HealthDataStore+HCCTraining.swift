import Foundation

// HCC: the Training tab's state box and every write it can make.
//
// Views observe `HCCTrainingState` and never call the network: every mutation
// goes through the store methods below, which follow the documented shape —
// apply locally so the tap feels immediate, call the server, reconcile with what
// the server actually stored, and on failure roll the local edit back and put
// the server's own sentence on `lastError`. A write that did not happen never
// looks like one that did.
//
// The one deliberate exception to "apply locally first" is a plan change. The
// resolved week is a server answer (it depends on stored plan rows and on the
// last week actually trained, neither of which the phone holds), so guessing it
// would paint a week that is simply wrong. That call marks itself busy, waits,
// and adopts the week the server hands back.

@MainActor
final class HCCTrainingState: ObservableObject {
  enum Phase {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var data: HCCTrainingData?

  /// The most recent failed write, in the server's own words. Cleared by the
  /// next write that succeeds.
  @Published var lastError: String?

  /// 0 = the calendar week the server called current, 1 = the week after it.
  /// The mockup's strip is a two-position toggle, not free paging: the payload
  /// carries exactly these two resolved weeks, and any third would have to be
  /// fetched or guessed.
  @Published var weekOffset: Int = 0

  /// The day whose picker is open, if any.
  @Published var pickerDate: String?

  /// Set once a pick lands on a next-week date, so the strip stops claiming the
  /// whole week is still inherited from this one.
  @Published var nextWeekEdited: Bool = false

  /// A write is in flight — the controls that would race it are disabled.
  @Published private(set) var isWriting: Bool = false

  /// Per-AMRAP-set rep drafts, keyed by set id. The − / + stepper edits this;
  /// "Log" is what reaches the server.
  @Published var amrapDrafts: [String: Int] = [:]

  /// Per-session note drafts, keyed by session id. Saved on end-editing.
  @Published var noteDrafts: [String: String] = [:]

  var isPending: Bool {
    switch phase {
    case .idle, .loading: true
    case .loaded, .failed: false
    }
  }

  var errorText: String? {
    if case let .failed(message) = phase { return message }
    return nil
  }

  /// The Monday of the week currently shown.
  var shownWeekStart: String? {
    guard let data else { return nil }
    return HCCFiveThreeOne.addDays(data.weekStartYmd, weekOffset * 7)
  }

  /// The resolved week currently shown. Both weeks arrive in the payload.
  var shownWeekPlan: [HCCResolvedDay] {
    guard let data else { return [] }
    return weekOffset == 0 ? data.weekPlan : data.nextWeekPlan
  }

  /// The AMRAP rep count the stepper is showing for a set: the draft if one has
  /// been touched, else what the server has logged, else the prescribed target.
  func amrapDraft(for set: HCCTrainingSet) -> Int {
    amrapDrafts[set.id] ?? set.actualReps ?? set.targetReps
  }

  func noteDraft(for session: HCCTrainingSession) -> String {
    noteDrafts[session.id] ?? session.notes ?? ""
  }

  // ── Mutation helpers, used only by the store ───────────────────────────────

  fileprivate func set(phase: Phase) { self.phase = phase }
  fileprivate func set(data: HCCTrainingData?) { self.data = data }
  fileprivate func set(writing: Bool) { isWriting = writing }

  /// Swap one session into the cached payload, keeping everything else. Used by
  /// both the optimistic apply and the reconcile, so the two can never disagree
  /// about what "the same session" means.
  fileprivate func replace(session: HCCTrainingSession) {
    guard let current = data else { return }
    data = current.replacing(session: session)
  }

  fileprivate func replace(set updated: HCCTrainingSet, inSession sessionId: String) {
    guard let current = data else { return }
    data = current.replacing(set: updated, inSession: sessionId)
  }

  fileprivate func replaceWeekPlan(weekStart: String, days: [HCCResolvedDay]) {
    guard let current = data else { return }
    data = current.replacingWeekPlan(weekStart: weekStart, days: days)
  }
}

// ── Payload edits ────────────────────────────────────────────────────────────
//
// `HCCTrainingData` is a value type, so an optimistic edit is a copy with one
// row swapped — there is no way for a half-applied change to be observed.

private extension HCCTrainingData {
  func replacing(session: HCCTrainingSession) -> HCCTrainingData {
    HCCTrainingData(
      cycle: cycle,
      todayYmd: todayYmd,
      weekStartYmd: weekStartYmd,
      sessions: sessions.map { $0.id == session.id ? session : $0 },
      cycleSessions: cycleSessions.map { $0.id == session.id ? session : $0 },
      liftHistory: liftHistory,
      weekPlan: weekPlan,
      nextWeekPlan: nextWeekPlan
    )
  }

  func replacing(set updated: HCCTrainingSet, inSession sessionId: String) -> HCCTrainingData {
    func patch(_ session: HCCTrainingSession) -> HCCTrainingSession {
      guard session.id == sessionId else { return session }
      return HCCTrainingSession(
        id: session.id,
        dateYmd: session.dateYmd,
        kind: session.kind,
        title: session.title,
        status: session.status,
        week: session.week,
        notes: session.notes,
        sets: session.sets.map { $0.id == updated.id ? updated : $0 }
      )
    }
    return HCCTrainingData(
      cycle: cycle,
      todayYmd: todayYmd,
      weekStartYmd: weekStartYmd,
      sessions: sessions.map(patch),
      cycleSessions: cycleSessions.map(patch),
      liftHistory: liftHistory,
      weekPlan: weekPlan,
      nextWeekPlan: nextWeekPlan
    )
  }

  func replacingWeekPlan(weekStart: String, days: [HCCResolvedDay]) -> HCCTrainingData {
    let nextStart = HCCFiveThreeOne.addDays(weekStartYmd, 7)
    return HCCTrainingData(
      cycle: cycle,
      todayYmd: todayYmd,
      weekStartYmd: weekStartYmd,
      sessions: sessions,
      cycleSessions: cycleSessions,
      liftHistory: liftHistory,
      weekPlan: weekStart == weekStartYmd ? days : weekPlan,
      nextWeekPlan: weekStart == nextStart ? days : nextWeekPlan
    )
  }
}

// ── Store slot ───────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// The Training tab's own state, created on first use.
  var hccTraining: HCCTrainingState { hcc.slot { HCCTrainingState() } }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Load the tracker once per app run; the tab re-appears on every switch and
  /// re-reading the whole window each time is cost with no answer attached.
  func loadHCCTrainingIfNeeded() async {
    guard case .idle = hccTraining.phase else { return }
    await reloadHCCTraining()
  }

  func reloadHCCTraining() async {
    let state = hccTraining
    if state.data == nil { state.set(phase: .loading) }
    do {
      let payload = try await HCCSession.shared.client.training()
      state.set(data: payload)
      state.set(phase: .loaded)
      // Drafts are keyed by server ids; a reload that changed a value under one
      // would otherwise keep showing the stale draft.
      state.amrapDrafts.removeAll()
      state.noteDrafts.removeAll()
    } catch {
      let message = Self.hccTrainingMessage(error)
      Self.hccTrainingHandleUnauthorized(error)
      // A reload that fails does not blank a payload already on screen; the
      // failure is reported and the last good week stays readable.
      state.set(phase: state.data == nil ? .failed(message) : .loaded)
      if state.data != nil { state.lastError = message }
    }
  }

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Toggle a prescribed set between "did the target" and "not performed", or
  /// log an exact rep count for an AMRAP.
  @discardableResult
  func logHCCTrainingSet(
    sessionId: String,
    set: HCCTrainingSet,
    actualReps: Int?
  ) async -> Bool {
    let state = hccTraining
    let previous = set
    let optimistic = HCCTrainingSet(
      id: set.id,
      lift: set.lift,
      setIndex: set.setIndex,
      targetWeightKg: set.targetWeightKg,
      targetReps: set.targetReps,
      isAmrap: set.isAmrap,
      actualReps: actualReps
    )
    state.replace(set: optimistic, inSession: sessionId)
    state.lastError = nil
    state.set(writing: true)
    defer { state.set(writing: false) }

    do {
      let ack = try await HCCSession.shared.client.patchTrainingSet(id: set.id, actualReps: actualReps)
      state.replace(set: ack.set, inSession: sessionId)
      // The e1RM trend is built from AMRAP reps on the server; logging one moves
      // the progression card, which only a re-read can know about.
      if set.isAmrap { await reloadHCCTraining() }
      return true
    } catch {
      state.replace(set: previous, inSession: sessionId)
      hccTrainingRecord(error)
      return false
    }
  }

  /// Mark a day done / re-open it, switch which conditioning workout it was, or
  /// save its note.
  @discardableResult
  func patchHCCTrainingSession(
    _ session: HCCTrainingSession,
    status: HCCTrainingSessionStatus? = nil,
    title: String? = nil,
    notes: String?? = nil
  ) async -> Bool {
    let state = hccTraining
    let optimistic = HCCTrainingSession(
      id: session.id,
      dateYmd: session.dateYmd,
      kind: session.kind,
      title: title ?? session.title,
      status: status ?? session.status,
      week: session.week,
      notes: notes.map { $0 } ?? session.notes,
      sets: session.sets
    )
    state.replace(session: optimistic)
    state.lastError = nil
    state.set(writing: true)
    defer { state.set(writing: false) }

    do {
      let ack = try await HCCSession.shared.client.patchTrainingSession(
        id: session.id,
        HCCTrainingSessionPatch(status: status?.rawValue, title: title, notes: notes)
      )
      state.replace(session: ack.session)
      return true
    } catch {
      state.replace(session: session)
      hccTrainingRecord(error)
      return false
    }
  }

  /// Start a strength day, or log a conditioning day that has no session yet.
  ///
  /// No optimistic row: a session's identity is its server id and its prescribed
  /// sets are generated server-side from the cycle's training maxes. Inventing a
  /// row here would put set ids on screen that nothing could later log against.
  @discardableResult
  func startHCCTrainingSession(_ body: HCCTrainingSessionCreate) async -> Bool {
    let state = hccTraining
    state.lastError = nil
    state.set(writing: true)
    defer { state.set(writing: false) }

    do {
      _ = try await HCCSession.shared.client.createTrainingSession(body)
      await reloadHCCTraining()
      return true
    } catch {
      hccTrainingRecord(error)
      return false
    }
  }

  /// Change what a day IS. The server hands back the whole re-resolved week,
  /// which is adopted verbatim; the reload that follows picks up the sessions
  /// the plan change regenerated or removed.
  @discardableResult
  func setHCCTrainingDayPlan(date: String, choice: HCCDayChoice) async -> Bool {
    let state = hccTraining
    state.lastError = nil
    state.set(writing: true)
    defer { state.set(writing: false) }

    let body = HCCTrainingPlanBody(
      date: date,
      option: choice.option.rawValue,
      lifts: choice.option == .strength ? choice.lifts.map(\.rawValue) : nil,
      title: choice.option == .conditioning ? choice.title : nil
    )
    do {
      let response = try await HCCSession.shared.client.setTrainingDayPlan(body)
      state.replaceWeekPlan(weekStart: response.weekStart, days: response.weekPlan)
      if let start = state.data?.weekStartYmd, response.weekStart != start {
        state.nextWeekEdited = true
      }
      await reloadHCCTraining()
      return true
    } catch {
      hccTrainingRecord(error)
      return false
    }
  }

  /// Move through the wave: advance, step back, roll into the next cycle, or
  /// undo an accidental cycle start. Every one of these changes the week, the
  /// training maxes and every preview at once, so the payload is re-read rather
  /// than patched.
  @discardableResult
  func runHCCTrainingCycleAction(_ body: HCCTrainingCycleBody) async -> Bool {
    let state = hccTraining
    state.lastError = nil
    state.set(writing: true)
    defer { state.set(writing: false) }

    do {
      _ = try await HCCSession.shared.client.trainingCycleAction(body)
      state.weekOffset = 0
      state.nextWeekEdited = false
      await reloadHCCTraining()
      return true
    } catch {
      hccTrainingRecord(error)
      return false
    }
  }

  // ── Error plumbing ─────────────────────────────────────────────────────────

  private func hccTrainingRecord(_ error: Error) {
    Self.hccTrainingHandleUnauthorized(error)
    hccTraining.lastError = Self.hccTrainingMessage(error)
  }

  /// A dead token is a session question, not a data question, so it is handed to
  /// `HCCSession` wherever it turns up.
  private static func hccTrainingHandleUnauthorized(_ error: Error) {
    if let apiError = error as? HCCAPIError, case .unauthorized = apiError {
      HCCSession.shared.handleUnauthorized()
    }
  }

  private static func hccTrainingMessage(_ error: Error) -> String {
    if let apiError = error as? HCCAPIError {
      return apiError.errorDescription ?? "Could not reach your Command Center."
    }
    return error.localizedDescription
  }
}
