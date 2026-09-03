import Foundation

/// The result of checking a typed server address, with the reason when it fails
/// so the field can say what is wrong rather than just refusing.
enum HCCBaseURLCheck {
  case valid(URL)
  case invalid(String)
}

/// The non-secret half of "who is signed in", cached so a cold launch can show
/// the account without a round trip. Deliberately holds no credential.
struct HCCAccountSummary: Codable, Equatable {
  let email: String
  let displayName: String
  let instanceId: String
  let timezone: String
}

/// Sign-in state for HCC provider mode: the base URL, whether a token exists,
/// who it belongs to, and the client built from all of that.
///
/// The tokens themselves never live on this object. `HCCAPIClient` pulls the
/// bearer through a closure that reads the Keychain on every request, so there
/// is exactly one copy of the credential in the process and signing out is a
/// Keychain delete rather than a hunt for stale references.
@MainActor
final class HCCSession: ObservableObject {
  static let shared = HCCSession()

  /// The instance this app talks to unless the user points it elsewhere.
  // `nonisolated`: read from the nonisolated Keychain/defaults helpers below,
  // and an immutable URL has no actor to protect.
  nonisolated static let defaultBaseURL = URL(string: "https://health.gatbontonlabs.com")!

  @Published private(set) var baseURL: URL
  @Published private(set) var isSignedIn: Bool
  @Published private(set) var account: HCCAccountSummary?
  @Published private(set) var lastError: String?

  /// Rebuilt whenever the base URL changes — a client is bound to one server.
  private(set) var client: HCCAPIClient

  init() {
    #if DEBUG
    Self.applyDebugLaunchDefaults()
    #endif

    let url = Self.storedBaseURL()
    baseURL = url
    client = HCCAPIClient(baseURL: url, tokenProvider: { HCCSession.currentToken() })
    isSignedIn = Self.currentToken() != nil
    account = Self.loadAccount()

    #if DEBUG
    startDebugSmokeIfRequested()
    #endif
  }

  // ── Base URL ───────────────────────────────────────────────────────────────

  func setBaseURL(_ url: URL) {
    guard url != baseURL else { return }
    UserDefaults.standard.set(url.absoluteString, forKey: HCCProviderSettings.baseURLKey)
    baseURL = url
    client = HCCAPIClient(baseURL: url, tokenProvider: { HCCSession.currentToken() })
  }

  /// `https` only, except on the loopback addresses a development server lives
  /// on — a self-hosted instance on the open internet has no excuse for plain
  /// HTTP, and health data is exactly the payload that must not travel in the
  /// clear.
  static func validate(baseURL raw: String) -> HCCBaseURLCheck {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed), let host = url.host else {
      return .invalid("Enter your server address, e.g. https://health.example.com")
    }
    let isLoopback = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost")
    switch url.scheme {
    case "https":
      return .valid(url)
    case "http" where isLoopback:
      return .valid(url)
    default:
      return .invalid("The address must start with https://")
    }
  }

  // ── Sign in / out ──────────────────────────────────────────────────────────

  /// Exchange credentials for the two tokens and switch the app to cloud mode.
  ///
  /// `POST /api/auth/mobile/login` answers with a bare object rather than the
  /// read API's envelope, and it is the one unauthenticated call the app makes,
  /// so it is built here instead of going through the client's typed helpers.
  func signIn(email: String, password: String, totp: String?, deviceName: String) async throws {
    lastError = nil

    let body = LoginBody(
      email: email.trimmingCharacters(in: .whitespacesAndNewlines),
      password: password,
      totp: totp?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      deviceName: deviceName
    )

    var request = URLRequest(url: baseURL.appendingPathComponent("/api/auth/mobile/login"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 20
    request.httpBody = try JSONEncoder().encode(body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      let failure = HCCAPIError.transport(error)
      lastError = failure.errorDescription
      throw failure
    }

    guard let http = response as? HTTPURLResponse else {
      let failure = HCCAPIError.http(status: -1, message: "Malformed response.")
      lastError = failure.errorDescription
      throw failure
    }
    guard (200..<300).contains(http.statusCode) else {
      let failure = HCCAPIClient.failure(status: http.statusCode, data: data)
      lastError = failure.errorDescription
      throw failure
    }

    let login: HCCLoginResponse
    do {
      login = try JSONDecoder().decode(HCCLoginResponse.self, from: data)
    } catch {
      let failure = HCCAPIError.decoding(error, path: "/api/auth/mobile/login")
      lastError = failure.errorDescription
      throw failure
    }

    do {
      try KeychainStore.write(login.token, account: HCCKeychainAccount.mobileToken)
      try KeychainStore.write(login.ingestToken, account: HCCKeychainAccount.ingestToken)
    } catch {
      // A token that could not be stored is a session that dies at the next
      // launch; say so now rather than looking signed in until then.
      KeychainStore.delete(HCCKeychainAccount.mobileToken)
      KeychainStore.delete(HCCKeychainAccount.ingestToken)
      lastError = error.localizedDescription
      throw error
    }

    let summary = HCCAccountSummary(
      email: login.user.email,
      displayName: login.user.name ?? login.instance.displayName,
      instanceId: login.instance.id,
      timezone: login.instance.timezone
    )
    Self.storeAccount(summary)
    account = summary
    isSignedIn = true
    // The instance's civil-day zone is what every `?date=` is bucketed in; set
    // it now rather than waiting for the next /instance read, so a same-launch
    // switch of instance can never bucket days in the previous one's zone.
    HCCInstanceZone.set(login.instance.timezone)
    HCCProviderSettings.current = .hccCloud
  }

  /// Best effort: tell the server to revoke this token, then forget it locally
  /// regardless. A phone that cannot reach the server must still be able to
  /// sign itself out.
  ///
  /// The provider switch is left on `.hccCloud` — signing out is not a decision
  /// to go back to reading a band over Bluetooth; redoing onboarding is.
  func signOut() async {
    if isSignedIn {
      let _: HCCLogoutResponse? = try? await client.postBare("/api/auth/mobile/logout")
    }
    clearCredentials()
  }

  /// A 401 from any call: the token is gone or revoked server-side.
  func handleUnauthorized() {
    clearCredentials()
    lastError = HCCAPIError.unauthorized.errorDescription
  }

  private func clearCredentials() {
    KeychainStore.delete(HCCKeychainAccount.mobileToken)
    KeychainStore.delete(HCCKeychainAccount.ingestToken)
    UserDefaults.standard.removeObject(forKey: HCCProviderSettings.accountKey)
    account = nil
    isSignedIn = false
  }

  // ── Credentials ────────────────────────────────────────────────────────────

  /// The bearer for outgoing requests. `nonisolated` on purpose: the client
  /// calls it from whatever thread a request is built on, and both the
  /// environment and the Keychain are safe to read from any of them.
  nonisolated static func currentToken() -> String? {
    #if DEBUG
    if let injected = debugLaunchToken() { return injected }
    #endif
    return KeychainStore.read(HCCKeychainAccount.mobileToken)
  }

  /// The HealthKit upload credential, for the Watch ingest path (Phase 4).
  nonisolated static func ingestToken() -> String? {
    KeychainStore.read(HCCKeychainAccount.ingestToken)
  }

  nonisolated static func storedBaseURL() -> URL {
    #if DEBUG
    if let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_BASE_URL"]?.nilIfEmpty,
       let url = URL(string: raw) {
      return url
    }
    #endif
    guard let raw = UserDefaults.standard.string(forKey: HCCProviderSettings.baseURLKey),
          let url = URL(string: raw)
    else {
      return defaultBaseURL
    }
    return url
  }

  private nonisolated static func loadAccount() -> HCCAccountSummary? {
    guard let data = UserDefaults.standard.data(forKey: HCCProviderSettings.accountKey) else { return nil }
    return try? JSONDecoder().decode(HCCAccountSummary.self, from: data)
  }

  private nonisolated static func storeAccount(_ summary: HCCAccountSummary) {
    guard let data = try? JSONEncoder().encode(summary) else { return }
    UserDefaults.standard.set(data, forKey: HCCProviderSettings.accountKey)
  }

  private struct LoginBody: Encodable {
    let email: String
    let password: String
    let totp: String?
    let deviceName: String
  }

  private struct HCCLogoutResponse: Decodable {
    let ok: Bool?
  }
}

// ── DEBUG launch bootstrap ───────────────────────────────────────────────────

#if DEBUG
extension HCCSession {
  /// Sign the simulator in from the launch environment instead of the UI.
  ///
  /// This is the verification path for the whole HCC workstream. Driving a
  /// password field with UI automation would mean a real credential sitting in
  /// a script, a log and a shell history; handing the process a token that was
  /// already minted by `POST /api/auth/mobile/login` keeps the password out of
  /// every one of those places. The token is used for this process only and is
  /// never written to the Keychain, so the injection dies with the process.
  ///
  ///   HCC_DEBUG_BASE_URL   base URL to talk to (default: the production one)
  ///   HCC_DEBUG_TOKEN      mobile bearer (`hccm_…`) to use for this launch
  ///   HCC_DEBUG_SMOKE=1    run the decode smoke against that instance at init
  ///
  /// DEBUG-only in every direction: the whole extension is compiled out of a
  /// Release build, so a shipped app has no env-var path to a signed-in state.
  nonisolated static func debugLaunchToken() -> String? {
    ProcessInfo.processInfo.environment["HCC_DEBUG_TOKEN"]?.nilIfEmpty
  }

  /// Called before SwiftUI reads `@AppStorage`, so the injected session lands
  /// on Home rather than on the onboarding flow.
  nonisolated static func applyDebugLaunchDefaults() {
    guard debugLaunchToken() != nil else { return }
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: OnboardingStorage.onboardingComplete)
    defaults.set(false, forKey: OnboardingStorage.onboardingRedoRequested)
    defaults.set(HealthMetricProvider.hccCloud.rawValue, forKey: HCCProviderSettings.storageKey)
  }

  /// The one entry point an app-launch touch point needs.
  nonisolated static func bootstrapForDebugLaunchIfNeeded() {
    guard debugLaunchToken() != nil else { return }
    applyDebugLaunchDefaults()
    Task { @MainActor in _ = HCCSession.shared }
  }

  fileprivate func startDebugSmokeIfRequested() {
    guard ProcessInfo.processInfo.environment["HCC_DEBUG_SMOKE"] == "1" else { return }
    let client = client
    Task { await HCCAPIClientSmoke.run(client: client) }
  }
}
#endif

private extension String {
  /// File-local: keeps the empty-string-means-absent rule in one place
  /// without adding a name to the app-wide String namespace.
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
