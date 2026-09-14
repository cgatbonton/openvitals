import Foundation

// HCC: the Training tab's routes, one function per path so a path string appears
// exactly once.
//
// These are the app's own WEB routes (`/api/training/*`), not `/api/mobile/v1`,
// so every one of them answers with a bare `ok()` object rather than the read
// API's `{data, generatedAt, instance}` envelope — hence `getBare`/`postBare`/
// `putBare`/`patchBare` throughout, all of them the shared client's.

extension HCCAPIClient {
  private static var trainingRoot: String { "/api/training" }

  /// The whole tracker payload: the active cycle, this week and next week
  /// already resolved, the session window, and the AMRAP-derived history.
  func training() async throws -> HCCTrainingData {
    try await getBare(Self.trainingRoot)
  }

  /// One Mon–Sun week, already resolved, for a week the payload does not carry.
  /// Any day of the week is accepted and snapped to its Monday by the route.
  ///
  /// This is what makes paging past the payload's two weeks possible WITHOUT
  /// guessing: resolution depends on stored plan rows and on the last week
  /// actually trained, so the server is the only side that can answer it — and
  /// this route is that answer. The web client has always used it.
  /// The week goes in `query:`, never interpolated into the path — the shared
  /// client feeds `path` to `appendingPathComponent`, which percent-encodes a
  /// `?` into `%3F` and turns the whole thing into one bogus path segment
  /// (`/api/training/plan%3FweekStart=…` → 404, seen 2026-09-14).
  func trainingWeekPlan(weekStart: String) async throws -> HCCTrainingPlanResponse {
    try await getBare("\(Self.trainingRoot)/plan", query: ["weekStart": weekStart])
  }

  /// Set what one day IS (as opposed to logging what happened on it). The
  /// response carries the whole re-resolved week.
  @discardableResult
  func setTrainingDayPlan(_ body: HCCTrainingPlanBody) async throws -> HCCTrainingPlanResponse {
    try await putBare("\(Self.trainingRoot)/plan", body: body)
  }

  /// Start a day. Re-opening a day that already exists returns it rather than
  /// duplicating, so this is safe to send twice.
  @discardableResult
  func createTrainingSession(_ body: HCCTrainingSessionCreate) async throws -> HCCTrainingSessionAck {
    try await postBare("\(Self.trainingRoot)/sessions", body: body)
  }

  @discardableResult
  func patchTrainingSession(id: String, _ body: HCCTrainingSessionPatch) async throws -> HCCTrainingSessionAck {
    try await patchBare("\(Self.trainingRoot)/sessions/\(id)", body: body)
  }

  /// The hot path — one tap on a checkbox between sets.
  @discardableResult
  func patchTrainingSet(id: String, actualReps: Int?) async throws -> HCCTrainingSetAck {
    try await patchBare("\(Self.trainingRoot)/sets/\(id)", body: HCCTrainingSetPatch(actualReps: actualReps))
  }

  @discardableResult
  func trainingCycleAction(_ body: HCCTrainingCycleBody) async throws -> HCCTrainingCycleAck {
    try await postBare("\(Self.trainingRoot)/cycle", body: body)
  }
}
