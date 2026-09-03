import Foundation

// The "Log a reading" feature's state and its two actions.
//
// The metric catalog is NOT part of the store's refresh loop — 215 rows are
// worth one fetch when the sheet opens and nothing on any other screen reads
// them — so this box owns its own load, the way `HCCPageLoad` does for the
// reference pages.
//
// The recent-slug list is deliberately local to the phone. The server has no
// "what did I last log" endpoint, and inferring one from the timeline would
// make the shortcut disagree with itself the moment a reading arrived from a
// device. What this phone typed is a fact this phone owns.

@MainActor
final class HCCLogReadingState: ObservableObject {
  /// The catalog, once. Empty until the first load answers.
  @Published var metrics: [HCCMetric] = []
  @Published var isLoadingMetrics = false
  @Published var metricsError: String?

  /// Slugs logged from this phone, most recent first, capped at five.
  @Published var recentSlugs: [String] = HCCLogReadingState.storedRecents()

  @Published var isSaving = false
  /// The one-line confirmation the sheet shows after a write lands.
  @Published var lastSavedLine: String?
  @Published var errorText: String?

  private static let recentsKey = "hcc.readings.recentSlugs"
  private static let recentsLimit = 5

  fileprivate static func storedRecents() -> [String] {
    UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
  }

  fileprivate func rememberRecent(_ slug: String) {
    var next = recentSlugs.filter { $0 != slug }
    next.insert(slug, at: 0)
    next = Array(next.prefix(Self.recentsLimit))
    recentSlugs = next
    UserDefaults.standard.set(next, forKey: Self.recentsKey)
  }

  /// The value as the user would have typed it: up to three decimals, with
  /// trailing zeros dropped so "80.5" does not come back as "80.500".
  ///
  /// `HCCFormat.decimal` takes a fixed digit count, which is right for a metric
  /// whose precision is known and wrong for a free-form entry field where the
  /// user's own keystrokes are the precision.
  static func amount(_ value: Double) -> String {
    guard value.isFinite else { return HCCFormat.placeholder }
    var text = String(format: "%.3f", value)
    while text.contains("."), text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  /// The catalog row for a slug, for the picker and the confirmation line.
  func metric(_ slug: String) -> HCCMetric? {
    metrics.first { $0.slug == slug }
  }

  /// Catalog rows matching a query, in catalog order. An empty query is the
  /// whole list — this is a picker, not a search that hides things by default.
  func matches(_ query: String) -> [HCCMetric] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return metrics }
    return metrics.filter {
      $0.displayName.lowercased().contains(needle)
        || $0.slug.lowercased().contains(needle)
        || $0.category.lowercased().contains(needle)
    }
  }
}

extension HealthDataStore {
  /// The one "Log a reading" box, created on first use.
  var hccReadings: HCCLogReadingState { hcc.slot { HCCLogReadingState() } }
}

@MainActor
extension HealthDataStore {
  /// Fetch the metric catalog once per process.
  func loadReadingMetricsIfNeeded() async {
    let state = hccReadings
    guard state.metrics.isEmpty, !state.isLoadingMetrics else { return }
    state.isLoadingMetrics = true
    state.metricsError = nil
    do {
      let response = try await HCCSession.shared.client.metrics()
      state.metrics = response.metrics
    } catch let apiError as HCCAPIError {
      if case .unauthorized = apiError {
        HCCSession.shared.handleUnauthorized()
      }
      state.metricsError = apiError.errorDescription ?? "Could not load the metric list."
    } catch {
      state.metricsError = error.localizedDescription
    }
    state.isLoadingMetrics = false
  }

  /// Write one manual reading.
  ///
  /// Unlike the other writes on this store there is nothing to apply
  /// optimistically and therefore nothing to roll back: a measurement is not
  /// mirrored in `hcc`, so the timeline this reading joins only exists on the
  /// server. The reconcile step is therefore a forced re-read — the same one a
  /// pull-to-refresh does — so whatever the reading changed (a Home tile, a
  /// biomarker card) is the SERVER's version of it and not a guess made here.
  ///
  /// The server's own message is what surfaces on a failure: a 409 means a
  /// reading already exists at that exact instant, and saying so beats a
  /// generic "did not save" the user cannot act on.
  @discardableResult
  func logReading(
    metricSlug: String,
    value: Double,
    measuredAt: Date,
    notes: String?
  ) async -> Bool {
    let state = hccReadings
    guard !state.isSaving else { return false }
    state.isSaving = true
    state.errorText = nil

    let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = HCCMeasurementCreate(
      metricSlug: metricSlug,
      value: value,
      measuredAt: HCCTime.isoInstant(measuredAt),
      notes: (trimmed?.isEmpty ?? true) ? nil : trimmed
    )

    do {
      let written = try await HCCSession.shared.client.logMeasurement(body)
      state.rememberRecent(written.metric)
      // The unit comes from the catalog the SERVER sent, never from the field
      // the user typed into — the route stores the metric's canonical unit and
      // converts nothing.
      let unit = state.metric(written.metric)?.unit
      let name = state.metric(written.metric)?.displayName ?? written.metric
      let amount = HCCLogReadingState.amount(written.value)
      state.lastSavedLine = unit.map { "Logged \(amount) \($0) for \(name)" }
        ?? "Logged \(amount) for \(name)"
      state.isSaving = false
      // Not awaited. `refreshFromHCC` owns its own task and re-reads a dozen
      // payloads; holding the sheet's "saved" state behind all of them left the
      // confirmation line sitting above a form that still showed the reading
      // just written. The write is already acknowledged by the server at this
      // point, so the caller is told so now and the reconcile lands when it
      // lands.
      Task { await refreshFromHCC(force: true) }
      return true
    } catch let apiError as HCCAPIError {
      if case .unauthorized = apiError {
        HCCSession.shared.handleUnauthorized()
      }
      state.errorText = apiError.errorDescription ?? "That reading did not save."
      state.isSaving = false
      return false
    } catch {
      state.errorText = error.localizedDescription
      state.isSaving = false
      return false
    }
  }
}
