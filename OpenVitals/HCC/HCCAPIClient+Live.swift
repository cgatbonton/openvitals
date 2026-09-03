import Foundation

// HCC: the one route a live session calls.
//
// `/api/mobile/v1/activities` is a read-API route, so it answers inside the
// `{data, generatedAt, instance}` envelope and goes through `post`, which
// unwraps it. The shared client's own `createActivity` is not reused: it takes
// `HCCActivityCreate`, which carries no heart-rate fields, and widening that
// type would change what the manual Add-activity sheet sends.

extension HCCAPIClient {
  /// Store a finished live session. The server re-derives the strain from the
  /// `zoneMs` this body carries and hands back the row it stored — including
  /// that strain, which is the number the activity screen then shows. The phone
  /// never displays its own running estimate as the final value.
  @discardableResult
  func createLiveActivity(_ body: HCCLiveActivityCreate) async throws -> HCCActivityResponse {
    try await post("/api/mobile/v1/activities", body: body)
  }
}
