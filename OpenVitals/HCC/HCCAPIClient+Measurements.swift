import Foundation

// `POST /api/measurements` — the owner logging a home reading by hand.
//
// A web route, not a `/api/mobile/v1/*` one, so it answers with a bare `ok()`
// object rather than the read API's `{data, generatedAt, instance}` envelope —
// hence `postBare(_:body:)` on the shared client rather than `post`. Only the
// DTOs and the one typed call live here; the request itself goes through the
// client's own `send`, so a 401 becomes the same `.unauthorized` every other
// call produces and a write is never retried.

/// `POST /api/measurements` body, mirroring the route's zod schema exactly.
///
/// `measuredAt` is `z.string().datetime()` WITHOUT `{offset: true}` on that
/// route, so it must be a UTC instant — `HCCTime.isoInstant` produces exactly
/// that. A nil `notes` is omitted rather than sent as null, because the schema
/// marks it optional, not nullable.
struct HCCMeasurementCreate: Encodable {
  let metricSlug: String
  let value: Double
  let measuredAt: String?
  let notes: String?
}

/// The 201 body: `ok({ metric, value, ...result })` where `result` is
/// `recordMeasurements`' `{written, skipped}` count pair.
///
/// `written == 0` cannot arrive here — the route turns that into a 409 — but
/// the field is kept because it is what the server actually sends, and the
/// sheet quotes the metric slug the server resolved rather than the one it
/// asked for (an alias resolves to its canonical slug server-side).
struct HCCMeasurementWritten: Decodable {
  let metric: String
  let value: Double
  let written: Int
  let skipped: Int
}

extension HCCAPIClient {
  /// Log one manual reading. 409 (a reading already exists at that exact
  /// instant) arrives as `HCCAPIError.http(status: 409, message:)` carrying the
  /// server's own sentence, which is the one the sheet shows.
  @discardableResult
  func logMeasurement(_ body: HCCMeasurementCreate) async throws -> HCCMeasurementWritten {
    try await postBare("/api/measurements", body: body)
  }
}
