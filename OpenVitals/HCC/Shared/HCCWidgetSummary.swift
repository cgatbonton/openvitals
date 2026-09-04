import Foundation

// The one payload the app hands the widgets, and the only file both targets
// compile for it.
//
// A widget cannot read the Keychain-backed session or call the read API — an
// extension is woken with no credentials and a few hundred milliseconds of
// budget — so the app writes the three numbers it already has to a JSON file in
// the shared App Group container and the widgets read that file. Nothing is
// computed on the widget side; every value here came from the server.
//
// Nil is not zero. A missing score stays `nil` and renders as "--" beside the
// server's own `reason` sentence, exactly as it does on Home.

/// The rings, as of the last refresh the app completed.
struct HCCWidgetSummary: Codable, Equatable {
  /// The instance's civil day these values describe (`YYYY-MM-DD`).
  var day: String
  /// 0–100. Nil when the server has no recovery score for the day.
  var recovery: Int?
  /// `primed` | `moderate` | `rest`, from the server's own bands.
  var recoveryBand: String?
  /// Sleep performance, 0–100.
  var sleep: Int?
  /// 0–21, the server's scale.
  var strain: Double?
  var strainTarget: Double?
  var hrv: Double?
  var rhr: Double?
  /// When the app last wrote this file — not when the server computed it.
  var updatedAt: Date
  /// Why something is missing, in the server's words. Shown verbatim.
  var reason: String?

  /// A summary with nothing in it, for a widget that has never been fed.
  static func empty(day: String, reason: String?) -> HCCWidgetSummary {
    HCCWidgetSummary(day: day, updatedAt: Date(), reason: reason)
  }

  init(
    day: String,
    recovery: Int? = nil,
    recoveryBand: String? = nil,
    sleep: Int? = nil,
    strain: Double? = nil,
    strainTarget: Double? = nil,
    hrv: Double? = nil,
    rhr: Double? = nil,
    updatedAt: Date = Date(),
    reason: String? = nil
  ) {
    self.day = day
    self.recovery = recovery
    self.recoveryBand = recoveryBand
    self.sleep = sleep
    self.strain = strain
    self.strainTarget = strainTarget
    self.hrv = hrv
    self.rhr = rhr
    self.updatedAt = updatedAt
    self.reason = reason
  }
}

/// Where the summary lives, for both the writer and the readers.
///
/// The App Group container is the only directory the app and its widget
/// extension can both open. When it is unavailable — an unsigned simulator
/// build has no entitlement, so `containerURL` returns nil — this falls back to
/// each process's own Application Support directory rather than dropping the
/// write. That fallback means the two processes are then writing and reading
/// DIFFERENT files, so it is recorded in the summary's `reason` instead of
/// being papered over: a widget stuck on "--" in the simulator is the App Group
/// missing, not the data.
enum HCCWidgetStore {
  static let appGroup = "group.com.gatbontontech.openvitals-hcc"
  static let fileName = "summary.json"

  /// The note appended to `reason` when the shared container is not available.
  static let noGroupNote = "App Group container unavailable on this build; the widget reads a separate copy."

  static var usesAppGroup: Bool { groupContainer != nil }

  private static var groupContainer: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  static var directory: URL? {
    groupContainer ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }

  static var fileURL: URL? {
    directory?.appendingPathComponent(fileName)
  }

  static func read() -> HCCWidgetSummary? {
    guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(HCCWidgetSummary.self, from: data)
  }

  /// Write the summary, stamping the fallback note onto `reason` when the
  /// shared container is missing.
  @discardableResult
  static func write(_ summary: HCCWidgetSummary) -> URL? {
    guard let url = fileURL else { return nil }
    var stamped = summary
    if !usesAppGroup {
      stamped.reason = [summary.reason, noGroupNote].compactMap { $0 }.joined(separator: " · ")
    }
    guard let data = try? encoder.encode(stamped) else { return nil }
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
