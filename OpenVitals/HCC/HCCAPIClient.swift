import Foundation

/// Everything that can go wrong on the wire, in the vocabulary the screens
/// need: a signed-out session, a second factor, the server saying no, the
/// network failing, or a payload that did not match the contract.
enum HCCAPIError: Error, LocalizedError {
  case unauthorized
  case totpRequired
  case http(status: Int, message: String)
  case transport(Error)
  case decoding(Error, path: String)

  var errorDescription: String? {
    switch self {
    case .unauthorized:
      "Signed out. Sign in to your Command Center again."
    case .totpRequired:
      "Enter the 6-digit code from your authenticator app."
    case let .http(status, message):
      message.isEmpty ? "Server error (\(status))." : message
    case let .transport(error):
      "Could not reach your Command Center: \(error.localizedDescription)"
    case let .decoding(_, path):
      "Your Command Center sent something this app could not read (\(path))."
    }
  }
}

/// HTTP client for one Health Command Center instance.
///
/// Immutable: the base URL is fixed at construction and the bearer token is
/// pulled through a closure on every request, so a token rotation or a sign-out
/// takes effect on the next call without anyone rebuilding the client. Changing
/// the base URL means building a new client — see `HCCSession`.
///
/// `@unchecked Sendable`: the stored state is two `let`s and a `URLSession`,
/// all of which are safe to share; the token closure is required to be
/// `@Sendable` for the same reason.
final class HCCAPIClient: @unchecked Sendable {
  let baseURL: URL

  private let tokenProvider: @Sendable () -> String?
  private let session: URLSession

  /// GET retries. Idempotent reads only — a POST is never replayed.
  private static let retryDelays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]

  init(baseURL: URL, tokenProvider: @escaping @Sendable () -> String?) {
    self.baseURL = baseURL
    self.tokenProvider = tokenProvider

    let config = URLSessionConfiguration.ephemeral
    // The phone is often on a dying connection when a screen appears; waiting
    // for connectivity beats a spurious "could not reach" the moment Wi-Fi
    // hands over to cellular.
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 60
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: config)
  }

  // ── Requests ───────────────────────────────────────────────────────────────

  /// A `/api/mobile/v1/*` read: decodes the envelope and hands back `.data`.
  func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("GET", path, query: query, body: nil, retryable: true)
    return envelope.data
  }

  /// A route that answers with a bare object rather than the envelope
  /// (`/api/protocols`, `/api/training/plan`, `/api/journal/*`, the auth routes).
  func getBare<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    try await send("GET", path, query: query, body: nil, retryable: true)
  }

  @discardableResult
  func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("POST", path, query: [:], body: try encode(body), retryable: false)
    return envelope.data
  }

  @discardableResult
  func post<T: Decodable>(_ path: String) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("POST", path, query: [:], body: nil, retryable: false)
    return envelope.data
  }

  /// Bare-object POST — the auth routes answer with `ok()`, not the envelope.
  @discardableResult
  func postBare<T: Decodable>(_ path: String) async throws -> T {
    try await send("POST", path, query: [:], body: nil, retryable: false)
  }

  /// Bare-object POST with a body — the web write routes (`/api/journal/*`,
  /// `/api/training/*`, `/api/measurements`) answer with `ok()`.
  @discardableResult
  func postBare<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    try await send("POST", path, query: [:], body: try encode(body), retryable: false)
  }

  /// Bare-object PUT with a body (`/api/journal/day/{date}`, `/api/training/plan`).
  @discardableResult
  func putBare<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    try await send("PUT", path, query: [:], body: try encode(body), retryable: false)
  }

  /// Bare-object DELETE (`/api/journal/doses?id=`, `/api/conversations/{id}`).
  @discardableResult
  func deleteBare<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    try await send("DELETE", path, query: query, body: nil, retryable: false)
  }

  @discardableResult
  func put<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("PUT", path, query: [:], body: try encode(body), retryable: false)
    return envelope.data
  }

  @discardableResult
  func patch<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("PATCH", path, query: [:], body: try encode(body), retryable: false)
    return envelope.data
  }

  /// Bare-object PATCH — `/api/insights/{id}` answers with `ok()`, which is the
  /// object itself rather than the read API's `{data, generatedAt, instance}`.
  @discardableResult
  func patchBare<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
    try await send("PATCH", path, query: [:], body: try encode(body), retryable: false)
  }

  @discardableResult
  func delete<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    let envelope: HCCEnvelope<T> = try await send("DELETE", path, query: query, body: nil, retryable: false)
    return envelope.data
  }

  // ── Plumbing ───────────────────────────────────────────────────────────────

  private func encode<Body: Encodable>(_ body: Body) throws -> Data {
    do {
      return try JSONEncoder().encode(body)
    } catch {
      throw HCCAPIError.decoding(error, path: "request body")
    }
  }

  private func send<T: Decodable>(
    _ method: String,
    _ path: String,
    query: [String: String],
    body: Data?,
    retryable: Bool,
    timeout: TimeInterval? = nil
  ) async throws -> T {
    let request = try makeRequest(method, path, query: query, body: body, timeout: timeout)
    var attempt = 0

    while true {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw HCCAPIError.http(status: -1, message: "Malformed response.")
        }
        if (200..<300).contains(http.statusCode) {
          return try decode(data, path: path)
        }
        // 5xx is the server having a bad moment; everything else is an answer.
        if retryable, http.statusCode >= 500, attempt < Self.retryDelays.count {
          try await Task.sleep(nanoseconds: Self.retryDelays[attempt])
          attempt += 1
          continue
        }
        throw Self.failure(status: http.statusCode, data: data)
      } catch let error as HCCAPIError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if retryable, attempt < Self.retryDelays.count {
          try await Task.sleep(nanoseconds: Self.retryDelays[attempt])
          attempt += 1
          continue
        }
        throw HCCAPIError.transport(error)
      }
    }
  }

  private func makeRequest(
    _ method: String,
    _ path: String,
    query: [String: String],
    body: Data?,
    timeout: TimeInterval? = nil
  ) throws -> URLRequest {
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw HCCAPIError.http(status: -1, message: "Invalid server address.")
    }
    if !query.isEmpty {
      components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else {
      throw HCCAPIError.http(status: -1, message: "Invalid server address.")
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    // The session's 20s default is sized for reads. A route that goes out to a
    // vendor on our behalf needs longer, and says so per request rather than
    // slackening the timeout every screen depends on. The session's
    // `timeoutIntervalForResource` (60s) is still the ceiling.
    if let timeout { request.timeoutInterval = timeout }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token = tokenProvider() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
    // A 200 with an empty body is still a success for the routes that answer
    // `{ok:true}`-shaped nothing; only bother the decoder when there is JSON.
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw HCCAPIError.decoding(error, path: path)
    }
  }

  /// Non-2xx → the typed error, reading the server's own message where it sent
  /// one. `TOTP_REQUIRED` arrives as a 401 and is a prompt, not a sign-out.
  static func failure(status: Int, data: Data) -> HCCAPIError {
    let message = (try? JSONDecoder().decode(HCCErrorBody.self, from: data))?.error ?? ""
    if status == 401 {
      return message == "TOTP_REQUIRED" ? .totpRequired : .unauthorized
    }
    return .http(status: status, message: message)
  }
}

// ── Typed endpoints ──────────────────────────────────────────────────────────

/// One function per route the app reads, so a path string appears exactly once.
/// Login and logout are not here: login is unauthenticated and both change
/// session state, so they live on `HCCSession`.
extension HCCAPIClient {
  private static let v1 = "/api/mobile/v1"

  func home(date: String? = nil) async throws -> HCCHome {
    try await get("\(Self.v1)/home", query: date.map { ["date": $0] } ?? [:])
  }

  func scores(days: Int = 90) async throws -> HCCScoresResponse {
    try await get("\(Self.v1)/scores", query: ["days": String(days)])
  }

  func sleepLatest() async throws -> HCCSleepNight {
    try await get("\(Self.v1)/sleep/latest")
  }

  func sleep(date: String) async throws -> HCCSleepNight {
    try await get("\(Self.v1)/sleep/\(date)")
  }

  func vitals(days: Int = 90) async throws -> HCCVitalsResponse {
    try await get("\(Self.v1)/vitals", query: ["days": String(days)])
  }

  func deck() async throws -> HCCDeckResponse {
    try await get("\(Self.v1)/deck")
  }

  /// The open cards.
  ///
  /// `date` narrows to the cards written ABOUT that civil day — the server
  /// matches `citations.date`, which the rule engine stamps on each card. Two
  /// consequences worth knowing at the call site: a card whose citations carry
  /// no date (an LLM analysis, a manual flag) matches no day and drops out
  /// entirely, so a dated read is a strict subset and can legitimately be
  /// empty; and omitting `date` is the general feed, not "today".
  func insights(status: String = "open", limit: Int = 50, date: String? = nil) async throws -> HCCInsightsResponse {
    var query = ["status": status, "limit": String(limit)]
    if let date { query["date"] = date }
    return try await get("\(Self.v1)/insights", query: query)
  }

  func weeklyInsights(limit: Int = 8) async throws -> HCCWeeklyInsightsResponse {
    try await get("\(Self.v1)/insights/weekly", query: ["limit": String(limit)])
  }

  func metrics() async throws -> HCCMetricsResponse {
    try await get("\(Self.v1)/metrics")
  }

  func instance() async throws -> HCCInstance {
    try await get("\(Self.v1)/instance")
  }

  func activities(date: String? = nil) async throws -> HCCActivitiesResponse {
    try await get("\(Self.v1)/activities", query: date.map { ["date": $0] } ?? [:])
  }

  func devices() async throws -> HCCDeviceList {
    try await get("\(Self.v1)/devices")
  }

  func dashboard() async throws -> HCCDashboardPrefs {
    try await get("\(Self.v1)/dashboard")
  }

  func alarm() async throws -> HCCAlarmResponse {
    try await get("\(Self.v1)/alarm")
  }

  func sleepPlan(date: String? = nil) async throws -> HCCSleepPlan {
    try await get("\(Self.v1)/sleep/plan", query: date.map { ["date": $0] } ?? [:])
  }

  func activity(id: String) async throws -> HCCActivityResponse {
    try await get("\(Self.v1)/activities/\(id)")
  }

  func biomarkers() async throws -> HCCBiomarkerPanels {
    try await get("\(Self.v1)/biomarkers")
  }

  func genetics() async throws -> HCCGenetics {
    try await get("\(Self.v1)/genetics")
  }

  /// `/api/protocols` is a web route, so it answers with a bare `ok()` object.
  func protocols() async throws -> HCCProtocolsResponse {
    try await getBare("/api/protocols")
  }

  // ── Writes ─────────────────────────────────────────────────────────────────

  /// Move an insight out of the open feed. `DISMISSED` is what the card's ✓
  /// button sends; the server also records it as feedback.
  @discardableResult
  func setInsightStatus(id: String, status: String) async throws -> HCCInsightStatusUpdate {
    try await patchBare("/api/insights/\(id)", body: HCCInsightStatusBody(status: status))
  }

  /// Pull every connected integration now, instead of waiting for the box's
  /// schedule. Answers per-source, so the button can name what failed.
  ///
  /// Long timeout because this route goes out to WHOOP, Google and Withings
  /// before it answers; `retryable: false` because a POST is never replayed and
  /// this one least of all — the server enforces a cooldown and a replay would
  /// simply come back 429.
  @discardableResult
  func triggerSync() async throws -> HCCSyncResult {
    let envelope: HCCEnvelope<HCCSyncResult> = try await send(
      "POST", "\(Self.v1)/sync", query: [:], body: nil, retryable: false, timeout: 55
    )
    return envelope.data
  }

  /// Front one wrist source when two report the same stream. `nil` clears the
  /// override and restores the standing priority order.
  @discardableResult
  func setPreferredSource(_ source: String?) async throws -> HCCPreferredSourceResponse {
    try await put("\(Self.v1)/devices/preferred", body: HCCPreferredSourceBody(source: source))
  }

  /// Save the Home tile order. The answer carries the stored list AND the
  /// catalog, so the customize sheet can rebuild itself from one round trip.
  @discardableResult
  func saveDashboard(tiles: [String]) async throws -> HCCDashboardPrefs {
    try await put("\(Self.v1)/dashboard", body: HCCDashboardTilesBody(tiles: tiles))
  }

  @discardableResult
  func saveAlarm(_ alarm: HCCAlarm) async throws -> HCCAlarmResponse {
    try await put("\(Self.v1)/alarm", body: alarm)
  }

  @discardableResult
  func createActivity(_ body: HCCActivityCreate) async throws -> HCCActivityResponse {
    try await post("\(Self.v1)/activities", body: body)
  }

  @discardableResult
  func updateActivity(id: String, _ body: HCCActivityPatch) async throws -> HCCActivityResponse {
    try await patch("\(Self.v1)/activities/\(id)", body: body)
  }

  /// Only a manually logged activity can be deleted — a provider row comes back
  /// on the next sync, so the server answers 409 rather than pretending.
  @discardableResult
  func deleteActivity(id: String) async throws -> HCCActivityDeleted {
    try await delete("\(Self.v1)/activities/\(id)")
  }
}

#if DEBUG
/// Decode check against a real instance.
///
/// The DTOs in `HCCModels.swift` are a hand-copy of the server's types, and a
/// hand-copy is only as good as the last time someone ran it against the actual
/// JSON. This hits the five reads the Home and Health screens are built on and
/// prints one line each — DEBUG only, opt-in through `HCC_DEBUG_SMOKE=1`, and
/// it never prints a metric value, only whether the shape decoded.
enum HCCAPIClientSmoke {
  static func run(client: HCCAPIClient) async {
    print("[hcc-smoke] base=\(client.baseURL.absoluteString)")

    // Whether the bundled faces actually made it into the app. A silent
    // fallback to a system font looks fine on screen and is the whole reason
    // this is printed rather than assumed.
    for line in HCCTheme.Font.debugResolutionReport() {
      print("[hcc-smoke] font \(line)")
    }

    await check("/instance") {
      let instance = try await client.instance()
      // Adopt the zone before the day-key checks below, exactly as a refresh
      // does — the smoke runs at session init, before any refresh has.
      HCCInstanceZone.set(instance.timezone)
      return "id=\(instance.id) tz=\(instance.timezone) sources=\(instance.sources.count)"
    }
    // The civil day the app will ASK the server for, next to the device's own.
    // These differ whenever the phone is in another zone, and the server buckets
    // in the instance's — so this line is what proves the client is asking for
    // the right day rather than the phone's.
    await check("civil day") {
      let day = HealthDataStore.hccDayKey(Date())
      return "instance=\(HealthDataStore.hccInstanceTimeZone.identifier) "
        + "device=\(TimeZone.current.identifier) asksFor=\(day)"
    }
    await check("/home") {
      let home = try await client.home()
      return "date=\(home.date) scores=\(home.scores.count) vitals=\(home.vitals.count) flags=\(home.flags.count)"
    }
    await check("/scores?days=7") {
      let scores = try await client.scores(days: 7)
      let withData = scores.days.filter { $0.recovery != nil || $0.strain != nil }.count
      return "days=\(scores.days.count) withData=\(withData)"
    }
    await check("/sleep/latest") {
      let night = try await client.sleepLatest()
      return "date=\(night.date) source=\(night.source ?? "none") segments=\(night.segments?.count ?? 0)"
    }
    await check("/vitals?days=7") {
      let vitals = try await client.vitals(days: 7)
      let points = vitals.vitals.reduce(0) { $0 + $1.series.count }
      return "streams=\(vitals.vitals.count) points=\(points)"
    }

    // The reads the design screens added. Same job: prove the hand-copied DTOs
    // still match the server's JSON. Counts and flags only, never a value.
    await check("/insights?status=open") {
      let insights = try await client.insights(status: "open")
      return "cards=\(insights.insights.count) open=\(insights.openCount)"
    }
    await check("/insights?status=open&date=today") {
      let day = HealthDataStore.hccDayKey(Date())
      let insights = try await client.insights(status: "open", date: day)
      return "day=\(day) cards=\(insights.insights.count)"
    }
    await check("/activities") {
      let activities = try await client.activities()
      return "date=\(activities.date) rows=\(activities.activities.count)"
    }
    await check("/sleep/plan") {
      let plan = try await client.sleepPlan()
      return "date=\(plan.date) hasNeed=\(plan.needH != nil) alarmMode=\(plan.alarm.mode)"
    }
    await check("/dashboard") {
      let dashboard = try await client.dashboard()
      return "tiles=\(dashboard.tiles.count) default=\(dashboard.isDefault) catalog=\(dashboard.catalog.count)"
    }
    await check("/alarm") {
      let alarm = try await client.alarm()
      return "mode=\(alarm.alarm.mode) on=\(alarm.alarm.on) default=\(alarm.isDefault)"
    }
    await check("/devices") {
      let devices = try await client.devices()
      let driving = devices.devices.filter(\.drives).count
      return "devices=\(devices.devices.count) driving=\(driving)"
    }
    await check("/biomarkers") {
      let biomarkers = try await client.biomarkers()
      let rows = biomarkers.panels.reduce(0) { $0 + $1.metrics.count }
      return "panels=\(biomarkers.panels.count) rows=\(rows) insights=\(biomarkers.insightCount)"
    }
    await check("/genetics") {
      let genetics = try await client.genetics()
      return "markers=\(genetics.markers.count) count=\(genetics.count)"
    }
    await check("/api/protocols") {
      let protocols = try await client.protocols()
      let active = protocols.protocols.filter { $0.status == "ACTIVE" }.count
      return "protocols=\(protocols.protocols.count) active=\(active)"
    }
  }

  private static func check(_ label: String, _ work: () async throws -> String) async {
    do {
      let detail = try await work()
      print("[hcc-smoke] \(label) OK \(detail)")
    } catch {
      print("[hcc-smoke] \(label) FAIL \(String(describing: error))")
    }
  }
}
#endif
