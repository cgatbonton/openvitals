import Foundation
import UserNotifications

// The APNs device token, and the one place it is sent to the instance.
//
// Two rules shape this file:
//
// 1. The token is a credential — it is what lets anything put text on this
//    phone's lock screen — so it is never logged, never put in an error string
//    and never shown on a screen. `More` says "Registered <time>", not a hex.
// 2. iOS hands the app a token on EVERY launch, and it is usually the same one.
//    Posting it every launch would be a write per cold start for no new
//    information, so a POST happens only when the token actually changed or the
//    last successful registration is over a day old — which is also what keeps
//    the server's `lastSeenAt` honest without a heartbeat.
//
// Nothing here runs in bridge mode: the caller (`HCCAppDelegate`) gates on
// `HCCProviderSettings.isCloud` before it asks the OS for a token at all.

/// What the Notifications rows on More can say about push.
enum HCCPushState: Equatable {
  case notAuthorized(String)
  case authorizedNotRegistered(String?)
  case registered(Date)

  /// The row's right-hand line. One short phrase — never the token, and never
  /// an OS error string: a four-line failure message in a settings row buries
  /// the three rows around it. The detail goes in `note`.
  var rowDetail: String {
    switch self {
    case .notAuthorized:
      return "Off"
    case .authorizedNotRegistered:
      return "Not registered"
    case let .registered(at):
      return "Registered \(HCCPushClock.time(at))"
    }
  }

  /// The whole sentence, for the footnote under the card. `nil` when there is
  /// nothing to explain.
  var note: String? {
    switch self {
    case let .notAuthorized(reason):
      return "Notifications are \(reason)."
    case let .authorizedNotRegistered(reason):
      return reason.map { "This iPhone could not register for notifications: \($0)" }
        ?? "This iPhone has not registered for notifications yet."
    case .registered:
      return nil
    }
  }
}

@MainActor
final class HCCPushRegistrar: ObservableObject {
  static let shared = HCCPushRegistrar()

  /// When the server last acknowledged this device's token.
  @Published private(set) var registeredAt: Date?
  /// The last failure, in the API client's own words. Never the token.
  @Published private(set) var lastError: String?
  /// What the OS says about notification permission, refreshed on activation.
  @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
  /// True once iOS has handed this launch a device token.
  @Published private(set) var hasDeviceToken = false

  private static let tokenKey = "open_vitals.hcc.push.token"
  private static let registeredAtKey = "open_vitals.hcc.push.registeredAt"
  /// A registration older than this is refreshed even when the token is the same.
  private static let maxAge: TimeInterval = 24 * 3600

  private var isRegistering = false

  private init() {
    let defaults = UserDefaults.standard
    hasDeviceToken = defaults.string(forKey: Self.tokenKey) != nil
    let stamp = defaults.double(forKey: Self.registeredAtKey)
    registeredAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
  }

  // ── State for the UI ───────────────────────────────────────────────────────

  /// One value the Notifications rows render, combining the OS's answer and
  /// the server's. Reads as a sentence, in that order, because "you never
  /// allowed notifications" and "the server has never heard from this phone"
  /// are different problems with different fixes.
  var state: HCCPushState {
    switch authorization {
    case .denied:
      return .notAuthorized("not allowed in iOS Settings")
    case .notDetermined:
      return .notAuthorized("not asked yet")
    default:
      break
    }
    if let registeredAt, Date().timeIntervalSince(registeredAt) < Self.maxAge * 7 {
      return .registered(registeredAt)
    }
    if let lastError {
      return .authorizedNotRegistered(lastError)
    }
    return .authorizedNotRegistered(hasDeviceToken ? nil : "waiting for a device token")
  }

  func refreshAuthorization() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    authorization = settings.authorizationStatus
  }

  // ── Registration ───────────────────────────────────────────────────────────

  /// iOS handed us a token. Post it only if it is new or the last post is stale.
  func register(_ hex: String) {
    hasDeviceToken = true
    let defaults = UserDefaults.standard
    let cached = defaults.string(forKey: Self.tokenKey)
    let age = registeredAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    guard cached != hex || age > Self.maxAge else {
      // Same token, registered recently: nothing to tell the server.
      return
    }
    defaults.set(hex, forKey: Self.tokenKey)
    Task { await send(hex) }
  }

  /// `didFailToRegisterForRemoteNotificationsWithError`. Recorded rather than
  /// swallowed — without it the row would say "waiting for a device token"
  /// forever while the real answer is that the OS refused.
  func recordRegistrationFailure(_ error: Error) {
    lastError = error.localizedDescription
  }

  private func send(_ hex: String) async {
    guard !isRegistering else { return }
    isRegistering = true
    defer { isRegistering = false }

    let client = HCCSession.shared.client
    do {
      _ = try await client.registerPushDevice(apnsToken: hex, environment: Self.environment)
      let now = Date()
      registeredAt = now
      lastError = nil
      UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.registeredAtKey)
    } catch let error as HCCAPIError {
      if case .unauthorized = error {
        // A token that cannot be registered because the session is gone is not
        // a push failure; the session layer owns that.
        HCCSession.shared.handleUnauthorized()
      }
      lastError = error.errorDescription
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Best effort, called from sign-out BEFORE the credentials are cleared —
  /// the DELETE needs the bearer that is about to be deleted.
  func unregister(client: HCCAPIClient) async {
    guard let hex = UserDefaults.standard.string(forKey: Self.tokenKey) else { return }
    _ = try? await client.unregisterPushDevice(apnsToken: hex)
    UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    UserDefaults.standard.removeObject(forKey: Self.registeredAtKey)
    registeredAt = nil
    hasDeviceToken = false
    lastError = nil
  }

  // ── Environment ────────────────────────────────────────────────────────────

  /// Which APNs gateway minted this token. A Debug build talks to the sandbox
  /// gateway; saying so is what stops the server aiming a sandbox token at
  /// production and disabling the row when Apple rejects it.
  static var environment: String {
    #if DEBUG
    return "sandbox"
    #else
    return "production"
    #endif
  }
}

/// Wall-clock formatting for the push and widget rows.
///
/// In the INSTANCE's zone, not the phone's — a "Registered 07:12" that shifts
/// when the owner travels would be a different claim on each side of a flight
/// (docs/hcc-provider.md, "Civil days belong to the instance").
///
/// Its own type rather than a static on the registrar: the registrar is
/// `@MainActor`, and the rows that format a time are not all on it.
enum HCCPushClock {
  static func time(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = HCCInstanceZone.current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}
