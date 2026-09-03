import Foundation
import Security

/// Keychain accounts used by HCC provider mode. Two credentials, two roles:
/// the mobile token reads and writes as the user, the ingest token is the
/// narrow HealthKit upload credential (Apple Watch → server) and can be
/// revoked on its own.
enum HCCKeychainAccount {
  static let mobileToken = "mobileToken"
  static let ingestToken = "ingestToken"
}

enum KeychainError: Error, LocalizedError {
  case encodingFailed
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .encodingFailed:
      "Could not encode the value for the Keychain."
    case let .status(status):
      "Keychain error \(status)."
    }
  }
}

/// A very small string-in / string-out wrapper over `kSecClassGenericPassword`.
///
/// Deliberately not generic over types: everything stored here is a bearer
/// token, and keeping the surface to three functions makes it obvious at a
/// glance that nothing else ends up on this keyring.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: background refresh needs
/// the token after a reboot without the user unlocking first, and
/// `ThisDeviceOnly` keeps it out of iCloud Keychain and encrypted backups — a
/// server credential should not travel to a device its owner never signed in on.
enum KeychainStore {
  static let service = "com.gatbontonlabs.hcc"

  static func read(_ account: String) -> String? {
    var query = baseQuery(account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty
    else {
      return nil
    }
    return value
  }

  static func write(_ value: String, account: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.encodingFailed
    }
    let query = baseQuery(account)
    let update: [String: Any] = [kSecValueData as String: data]

    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainError.status(addStatus)
    }
  }

  /// Idempotent: a missing item is a successful delete, not an error.
  static func delete(_ account: String) {
    SecItemDelete(baseQuery(account) as CFDictionary)
  }

  private static func baseQuery(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
