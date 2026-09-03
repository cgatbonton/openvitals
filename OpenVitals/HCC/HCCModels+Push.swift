import Foundation

// DTOs for `/api/mobile/v1/push-devices` (plan §4.7). Kept in their own file so
// `HCCModels.swift` stays the Phase-2 read API's shapes.

/// The registration body. `environment` is not cosmetic: a token minted by the
/// sandbox gateway is rejected by the production one with `BadDeviceToken`,
/// which the server's fan-out then reads as a dead device and disables — so a
/// DEBUG build must say "sandbox" or it silently unregisters itself.
struct HCCPushDeviceBody: Encodable {
  let apnsToken: String
  let platform: String
  let environment: String
}

/// What the server echoes back — never the token itself.
struct HCCPushDevice: Decodable {
  let id: String
  let platform: String
  let environment: String
  let lastSeenAt: String?
}

/// `DELETE /push-devices?apnsToken=` → `{removed: <count>}`.
struct HCCPushDeviceRemoval: Decodable {
  let removed: Int?
}
