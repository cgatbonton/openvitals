import SwiftUI

// Shared plumbing for the detail and Health screens: how a page that the store
// does not cache loads itself, how the sheets other workstreams own are reached,
// and the handful of number formats the mockup uses.
//
// Nothing here renders a metric. Formatting a value that does not exist is the
// one thing these helpers refuse to do: every function that takes an optional
// answers "--" for nil rather than 0, and no caller can pass a default in.

// ── Page loading ─────────────────────────────────────────────────────────────

/// One network-backed page's lifecycle.
///
/// `/biomarkers`, `/genetics`, `/insights` and `/api/protocols` are NOT part of
/// the store's refresh, so each page fetches its own payload. The phases are
/// explicit — and `.idle`/`.loading` are distinct from `.loaded` — so a view can
/// say "loading" instead of drawing an empty list that reads as "you have none".
@MainActor
final class HCCPageLoad<Value>: ObservableObject {
  enum Phase {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle

  var value: Value? {
    if case let .loaded(value) = phase { return value }
    return nil
  }

  /// True until the first answer of any kind arrives.
  var isPending: Bool {
    switch phase {
    case .idle, .loading: true
    case .loaded, .failed: false
    }
  }

  var errorText: String? {
    if case let .failed(message) = phase { return message }
    return nil
  }

  /// Fetch once per view lifetime. A `.task` fires again on every reappearance,
  /// and re-fetching a lab panel on each tab switch is cost with no answer
  /// attached.
  func loadIfNeeded(_ work: @escaping () async throws -> Value) async {
    guard case .idle = phase else { return }
    await reload(work)
  }

  func reload(_ work: () async throws -> Value) async {
    phase = .loading
    do {
      phase = .loaded(try await work())
    } catch let apiError as HCCAPIError {
      if case .unauthorized = apiError {
        HCCSession.shared.handleUnauthorized()
      }
      phase = .failed(apiError.errorDescription ?? "Could not load this page.")
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

// ── Sheets other workstreams own ─────────────────────────────────────────────

/// The modal surfaces these screens link to but do not build.
///
/// The Alarm sheet and the Activity detail belong to workstream D-C. Naming
/// them through this enum, and presenting them in the ONE view below, is what
/// makes wiring them a single-file edit instead of a hunt through five screens
/// for `.sheet` modifiers.
enum HCCDetailRoute: Identifiable, Hashable {
  case alarm
  case activity(id: String)

  var id: String {
    switch self {
    case .alarm: "alarm"
    case .activity(let activityId): "activity/\(activityId)"
    }
  }
}

/// The single place these screens present another workstream's sheet.
///
/// Both destinations belong to workstream D-C. Routing through one view means a
/// change to either of their signatures is a one-line edit here rather than a
/// hunt through five screens for `.sheet` modifiers.
struct HCCDetailRouteSheet: View {
  let route: HCCDetailRoute
  @ObservedObject var store: HealthDataStore

  @ViewBuilder
  var body: some View {
    switch route {
    case .alarm:
      HCCAlarmSheet(store: store)
    case let .activity(id):
      // Through the route resolver: a sleep row opens the night, not a workout.
      HCCActivityDestinationView(store: store, activityId: id)
    }
  }
}

// ── Formatting ───────────────────────────────────────────────────────────────

/// The number and duration formats the mockup uses, in one place.
///
/// Every entry point takes an optional and answers "--" for nil. That is the
/// fabrication guard: a screen cannot accidentally print "0h 00m" for a night
/// the server never scored, because there is no code path that turns nil into a
/// number.
enum HCCFormat {
  static let placeholder = "--"

  /// "7h 21m" from hours. Rounds to the minute, which is the resolution the
  /// server's hour floats actually carry.
  static func hours(_ value: Double?) -> String {
    guard let value, value.isFinite else { return placeholder }
    let totalMinutes = Int((abs(value) * 60).rounded())
    let sign = value < 0 ? "−" : ""
    return "\(sign)\(totalMinutes / 60)h \(String(format: "%02d", totalMinutes % 60))m"
  }

  /// "+0h 14m" — the sleep-need decomposition's added terms, which read wrong
  /// without their sign.
  static func signedHours(_ value: Double?) -> String {
    guard let value, value.isFinite else { return placeholder }
    let text = hours(abs(value))
    return value < 0 ? "−\(text)" : "+\(text)"
  }

  static func decimal(_ value: Double?, _ fractionDigits: Int) -> String {
    guard let value, value.isFinite else { return placeholder }
    return String(format: "%.\(fractionDigits)f", value)
  }

  /// A metric value with its unit, e.g. "74 ms", "96%".
  static func measurement(_ value: Double?, unit: String?, fractionDigits: Int) -> String {
    guard let value, value.isFinite else { return placeholder }
    let text = decimal(value, fractionDigits)
    guard let unit, !unit.isEmpty else { return text }
    return unit == "%" ? "\(text)%" : "\(text) \(unit)"
  }

  /// "Aug 25" for a server day key; the key itself if it will not parse.
  static func shortDay(_ dayKey: String?) -> String {
    guard let dayKey else { return placeholder }
    return HealthDataStore.hccShortDayLabel(dayKey)
  }

  /// "10:40 pm" from an ISO instant.
  static func clock(_ iso: String?) -> String? {
    guard let instant = HCCTime.instant(iso) else { return nil }
    return instant.formatted(date: .omitted, time: .shortened)
  }

  /// The mockup's `.actv .tm` pair: start over end, both wall-clock.
  static func clockRange(start: String?, end: String?) -> (String, String) {
    (clock(start) ?? placeholder, clock(end) ?? placeholder)
  }
}

// ── Small shared pieces ──────────────────────────────────────────────────────

/// The muted sentence a card shows while its payload is in flight.
///
/// Distinct from `HCCEmptyNote` on purpose: "Loading" and "you have none" are
/// different claims and must not share a rendering.
struct HCCLoadingNote: View {
  var text = "Loading from your Command Center..."

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .tint(HCCTheme.Color.muted)
      Text(text)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.muted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
  }
}

/// The muted footnote under a card — the mockup's small grey `<p>`.
struct HCCFootnote: View {
  let text: String
  var size: CGFloat = 11

  init(_ text: String, size: CGFloat = 11) {
    self.text = text
    self.size = size
  }

  var body: some View {
    Text(text)
      .font(HCCTheme.Font.body(size: size))
      .foregroundStyle(HCCTheme.Color.muted)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A card standing in for a value that is not there, saying why in the server's
/// own words.
///
/// The heading is a parameter because "not loaded" and "no score yet" are
/// different claims: the first says the app failed, the second says the server
/// has nothing to give — and printing the wrong one is telling the user
/// something untrue about their data.
struct HCCErrorNote: View {
  let text: String
  var title: String
  /// Offered when the failure is worth another go — a dev server still warming
  /// up, a phone that came back on network. A screen with no retry leaves the
  /// user with a dead page until they switch tabs, which is not an answer.
  var retry: (() async -> Void)?

  @State private var isRetrying = false

  init(_ text: String, title: String = "Not loaded", retry: (() async -> Void)? = nil) {
    self.text = text
    self.title = title
    self.retry = retry
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HCCLabel(title)
      Text(text)
        .font(HCCTheme.Font.body(size: 12.5))
        .foregroundStyle(HCCTheme.Color.text)
        .fixedSize(horizontal: false, vertical: true)
      if let retry {
        Button {
          guard !isRetrying else { return }
          isRetrying = true
          Task {
            await retry()
            isRetrying = false
          }
        } label: {
          Text(isRetrying ? "Retrying…" : "Try again")
            .font(HCCTheme.Font.body(size: 11, weight: .semibold))
            .tracking(0.88)
            .textCase(.uppercase)
            .foregroundStyle(HCCTheme.Color.accent)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
      }
    }
    .hccCard()
  }
}

// ── Screen scaffold ──────────────────────────────────────────────────────────

/// The `.content` box: 12/16/18 padding, hidden indicators, the screen ground,
/// and no system navigation bar — these screens draw their own header.
struct HCCScreen<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollView {
      // The mockup's `.card{margin-bottom:10px}`, expressed once as stack
      // spacing rather than as a margin on each card. Stack spacing is the
      // single mechanism for vertical rhythm on these screens: anything that
      // needs a DIFFERENT gap (tiles and activity rows at 8) sets it on its own
      // stack, and nothing adds a bottom padding that would stack on top of it.
      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 18)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .hccBackground()
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .navigationBar)
  }
}

// ── Vitals ───────────────────────────────────────────────────────────────────

/// The five wearable streams these screens read, in the order the mockup shows
/// them. The slugs are the server's; the labels come from the payload, so an
/// instance that renamed a metric is reflected rather than overridden.
enum HCCVitalSlug {
  static let hrv = "hrv_sdnn"
  static let restingHR = "resting_hr"
  static let respiratoryRate = "respiratory_rate"
  static let bloodOxygen = "blood_oxygen"
  static let wristTemp = "wrist_temp"

  /// Health-monitor order.
  static let monitorOrder = [hrv, restingHR, respiratoryRate, bloodOxygen, wristTemp]

  /// Display precision per stream — a resting HR of "50.0" reads as false
  /// precision it does not have.
  static func fractionDigits(_ slug: String) -> Int {
    slug == restingHR ? 0 : 1
  }

  /// The label to print, with the HRV kind folded in: the slug says SDNN and
  /// the rows hold RMSSD, so the server's `hrvKind` is what the user is shown.
  static func label(_ series: HCCVitalSeries) -> String {
    guard series.slug == hrv, let kind = series.hrvKind, !kind.isEmpty else {
      return series.label
    }
    return series.label.contains(kind) ? series.label : "\(series.label) (\(kind))"
  }
}
