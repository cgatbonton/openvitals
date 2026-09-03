import Foundation

// The two calls that register and forget this phone's APNs token.
//
// `HCCAPIClient.v1` is file-private to the client, so the path base is repeated
// here rather than the client being edited to expose it; this file is the only
// place these two paths appear.

extension HCCAPIClient {
  private static let pushDevicesPath = "/api/mobile/v1/push-devices"

  /// Upsert this device's APNs token against the signed-in account.
  @discardableResult
  func registerPushDevice(
    apnsToken: String,
    platform: String = "ios",
    environment: String
  ) async throws -> HCCPushDevice {
    try await post(
      Self.pushDevicesPath,
      body: HCCPushDeviceBody(apnsToken: apnsToken, platform: platform, environment: environment)
    )
  }

  /// Explicit opt-out: the row is deleted, not disabled.
  @discardableResult
  func unregisterPushDevice(apnsToken: String) async throws -> HCCPushDeviceRemoval {
    try await delete(Self.pushDevicesPath, query: ["apnsToken": apnsToken])
  }
}
