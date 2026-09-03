import Foundation

/// Where health metrics come from.
///
/// `.bridge` is upstream OpenVitals exactly as it is: BLE packets through the
/// Rust core into the local SQLite store. `.hccCloud` reads already-scored
/// metrics from the user's own self-hosted Health Command Center instance over
/// HTTPS. The two paths never mix in one snapshot — a value is either local or
/// it is the server's, and it says which.
enum HealthMetricProvider: String, CaseIterable, Identifiable {
  case bridge
  case hccCloud

  var id: String { rawValue }

  /// Copy for the onboarding picker. Never names a manufacturer.
  var title: String {
    switch self {
    case .bridge: "Pair a compatible BLE health device"
    case .hccCloud: "Connect to your Command Center"
    }
  }

  var detail: String {
    switch self {
    case .bridge: "Read a user-owned band directly over Bluetooth. Everything stays on this iPhone."
    case .hccCloud: "Read metrics your own self-hosted server has already scored. Requires an account on it."
    }
  }
}

/// The provider switch and the two non-secret settings that ride with it.
///
/// Defaults to `.bridge` so a build of this fork behaves exactly like upstream
/// until someone opts in. Nothing here is secret — the tokens live in the
/// Keychain (`KeychainStore`); a base URL is an address, not a credential, so
/// it stays in `UserDefaults` where a settings screen can read it cheaply.
enum HCCProviderSettings {
  static let storageKey = "open_vitals.swift.hcc.provider"
  /// Base URL of the user's own instance. Not a secret — see above.
  static let baseURLKey = "open_vitals.swift.hcc.baseURL"
  /// Cached `HCCAccountSummary` JSON (email, display name, instance, timezone).
  static let accountKey = "open_vitals.swift.hcc.account"

  static var current: HealthMetricProvider {
    get {
      let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
      return HealthMetricProvider(rawValue: raw) ?? .bridge
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
    }
  }

  static var isCloud: Bool { current == .hccCloud }
}
