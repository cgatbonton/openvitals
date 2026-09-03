import Darwin
import Foundation
import SwiftUI
import UIKit

enum OpenVitalsPacketScoreAlgorithmID {
  static let sleep = "open_vitals.sleep.v0"
}

@MainActor
final class HealthDataStore: ObservableObject {
  @Published var algorithmDefinitions: [HealthAlgorithmDefinition]
  @Published var referenceDefinitions: [HealthAlgorithmDefinition]
  @Published var selectedAlgorithmByFamily: [String: String]
  @Published var catalogStatus = "Metric catalog not loaded"
  @Published var catalogSource = HealthDataSource.unavailable("metric registry not loaded")
  @Published var packetInputStatus = "No run"
  @Published var packetScoreStatus = "No run"
  @Published var packetInputIsRunning = false
  @Published var packetScoreIsRunning = false
  @Published var healthMetricRefreshIsRunning = false
  @Published var healthMetricRefreshStatus = "No refresh"
  @Published var bandSleepImportStatus = "No band sync yet"
  @Published var externalSleepImportStatus = "External sleep imports disabled"
  @Published var referenceRunStatusByFamily: [String: String] = [:]
  @Published var primarySleepDetail: PrimarySleepDetail?
  @Published var calibrationTargetFamily = "recovery"
  @Published var calibrationLabelsImported = false
  @Published var calibrationRunComplete = false
  @Published var healthDashboardVitalSnapshots: [HealthMetricSnapshot] = []
  @Published var healthDashboardExploreSnapshots: [HealthMetricSnapshot] = []
  @Published var healthDashboardAlgorithmSnapshots: [HealthMetricSnapshot] = []
  @Published var healthDashboardStepsText = "--"
  @Published var healthDashboardStepsStatus = "Needs device packet extract"
  @Published var healthDashboardStepsSource = HealthDataSource.unavailable("Device step extraction pending")
  @Published var healthDashboardActiveEnergyText = "-- kcal"
  @Published var healthDashboardActiveEnergyStatus = "Needs device packet extract"
  @Published var healthDashboardActiveEnergySource = HealthDataSource.unavailable("metrics.energy_daily_rollup not run")
  @Published var healthDashboardCardioLoadDays: [CardioLoadDay] = []
  @Published var heartRateHourlyRanges: [HeartRateHourlyRange] = []
  @Published var heartRateTimelineStatus = "No HR samples stored"

  let bridge = OpenVitalsRustBridge()
  // HCC: cloud-mode cache. Extensions cannot add stored properties, so the one
  // box `HealthDataStore+HCC.swift` needs lives here. Untouched in bridge mode.
  var hcc = HCCStoreState()
  let heartRateSeriesStore = HeartRateSeriesStore.shared
  var attemptedCatalogLoad = false
  var previewMissingData = false
  var packetInputReports: [String: [String: Any]] = [:]
  var packetScoreReports: [String: [String: Any]] = [:]
  var referenceComparisonReports: [String: [String: Any]] = [:]
  var packetInputWindow = HealthDataStore.currentDailyMetricWindow()
  var packetScoreWindow = HealthDataStore.currentDailyMetricWindow()
  var packetInputRefreshWorkItem: DispatchWorkItem?
  var packetInputRunID: UUID?
  var packetScoreRunID: UUID?
  var pendingPacketScoreDate: Date?
  var heartRateTimelineRefreshID: UUID?
  var heartRateSeriesUpdateObserver: NSObjectProtocol?
  var hrvSeriesUpdateObserver: NSObjectProtocol?
  let packetInputQueue = DispatchQueue(label: "com.open_vitals.swift.health.packet-inputs", qos: .utility)
  let packetScoreQueue = DispatchQueue(label: "com.open_vitals.swift.health.packet-scores", qos: .utility)
  let heartRateTimelineQueue = DispatchQueue(label: "com.open_vitals.swift.health.heart-rate-timeline", qos: .utility)
  lazy var databasePath = HealthDataStore.defaultDatabasePath()

  static let liveHRVRMSSDDefaultsKey = "open_vitals.swift.liveHRVRMSSD"
  static let liveHRVRRIntervalCountDefaultsKey = "open_vitals.swift.liveHRVRRIntervalCount"
  static let liveHRVRMSSDSampleCountDefaultsKey = "open_vitals.swift.liveHRVRMSSDSampleCount"
  static let liveHRVUpdatedAtDefaultsKey = "open_vitals.swift.liveHRVUpdatedAt"
  static let liveHRVSourceDefaultsKey = "open_vitals.swift.liveHRVSource"
  static let restingHeartRateEstimateBPMDefaultsKey = "open_vitals.swift.restingHeartRateEstimateBPM"
  static let restingHeartRateEstimateSampleCountDefaultsKey = "open_vitals.swift.restingHeartRateEstimateSampleCount"
  static let restingHeartRateEstimateUpdatedAtDefaultsKey = "open_vitals.swift.restingHeartRateEstimateUpdatedAt"
  static let restingHeartRateEstimateSourceDefaultsKey = "open_vitals.swift.restingHeartRateEstimateSource"

  init() {
    algorithmDefinitions = []
    referenceDefinitions = []
    selectedAlgorithmByFamily = [:]
    primarySleepDetail = nil
    refreshHealthDashboardSnapshots()
    // HCC: the heart-rate timeline is a BLE/SQLite read; cloud mode has no
    // local sample store to walk.
    if !HCCProviderSettings.isCloud {
      refreshHeartRateTimeline()
    }
    heartRateSeriesUpdateObserver = NotificationCenter.default.addObserver(
      forName: HeartRateSeriesStore.didUpdateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshHeartRateTimeline()
        self?.refreshHealthDashboardSnapshots()
      }
    }
    hrvSeriesUpdateObserver = NotificationCenter.default.addObserver(
      forName: HRVSeriesStore.didUpdateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshHealthDashboardSnapshots()
      }
    }
  }

  deinit {
    if let heartRateSeriesUpdateObserver {
      NotificationCenter.default.removeObserver(heartRateSeriesUpdateObserver)
    }
    if let hrvSeriesUpdateObserver {
      NotificationCenter.default.removeObserver(hrvSeriesUpdateObserver)
    }
  }

  static func defaultDatabasePath() -> String {
    let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = baseDirectory.appendingPathComponent("OpenVitals", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("open_vitals.sqlite").path
  }

  var usesSampleData: Bool {
    false
  }

  var localDataSupportsExport: Bool {
    !packetInputReports.isEmpty || !packetScoreReports.isEmpty || !referenceComparisonReports.isEmpty
  }

  var localHealthExportText: String {
    [
      "OpenVitals Health Export",
      "Catalog: \(catalogStatus)",
      "Band sleep import: \(bandSleepImportStatus)",
      "HealthKit metric import: disabled; profile weight only",
      "Packet inputs: \(packetInputStatus)",
      "Packet scores: \(packetScoreStatus)",
      "Readiness: \(metricInputReadinessSummary())",
      "Sleep: \(sleepFeatureScoreSummary())",
      "Recovery: \(recoveryFeatureScoreSummary())",
      "Strain: \(strainFeatureScoreSummary())",
      "Stress: \(stressFeatureScoreSummary())",
    ].joined(separator: "\n")
  }

  var healthMetricWorkIsRunning: Bool {
    healthMetricRefreshIsRunning || packetInputIsRunning || packetScoreIsRunning
  }

  func resetAfterLocalDataWipe() {
    packetInputRefreshWorkItem?.cancel()
    packetInputRefreshWorkItem = nil
    packetInputRunID = nil
    packetScoreRunID = nil
    pendingPacketScoreDate = nil
    heartRateTimelineRefreshID = nil
    packetInputReports = [:]
    packetScoreReports = [:]
    referenceComparisonReports = [:]
    primarySleepDetail = nil
    referenceRunStatusByFamily = [:]
    packetInputIsRunning = false
    packetScoreIsRunning = false
    healthMetricRefreshIsRunning = false
    packetInputStatus = "No run"
    packetScoreStatus = "No run"
    healthMetricRefreshStatus = "Local app data wiped"
    bandSleepImportStatus = "No band sync yet"
    externalSleepImportStatus = "External sleep imports disabled"
    heartRateHourlyRanges = []
    heartRateTimelineStatus = "No HR samples stored"
    calibrationLabelsImported = false
    calibrationRunComplete = false
  }

  func loadBridgeCatalogsIfNeeded() {
    // HCC: no Rust metric registry is involved in cloud mode.
    guard !HCCProviderSettings.isCloud else {
      return
    }
    guard !attemptedCatalogLoad else {
      return
    }
    attemptedCatalogLoad = true
    refreshBridgeCatalogs()
  }

  func refreshPacketInputsIfNeeded(for date: Date = Date()) {
    // HCC: there are no packets to extract from in cloud mode.
    guard !HCCProviderSettings.isCloud else {
      return
    }
    let inputWindow = Self.dailyMetricWindow(containing: date)
    guard packetInputReports.isEmpty || packetInputWindow.dateKey != inputWindow.dateKey || packetInputStatus == "No run" else {
      return
    }
    runPacketInputs(for: date)
  }

  func latestPacketEvidenceDate(completion: @escaping (Date?) -> Void) {
    let databasePath = databasePath
    packetInputQueue.async {
      let result = Self.rawEvidenceBoundsBridgeReport(databasePath: databasePath)
      let latestDateValue: Any?
      switch result {
      case .success(let report):
        latestDateValue = report["last_packet_captured_at"] ?? report["last_captured_at"]
      case .failure:
        latestDateValue = nil
      }
      DispatchQueue.main.async {
        completion(Self.bridgeDate(latestDateValue))
      }
    }
  }

  func refreshHealthMetrics(for date: Date = Date()) {
    // HCC: in cloud mode the whole extract/score pipeline is one read.
    if HCCProviderSettings.isCloud {
      Task { await refreshFromHCC(date: date) }
      return
    }
    guard !healthMetricWorkIsRunning else {
      healthMetricRefreshStatus = "Health metric refresh already running"
      return
    }

    healthMetricRefreshIsRunning = true
    healthMetricRefreshStatus = "Extracting packet-derived inputs..."
    refreshBridgeCatalogs()
    refreshHeartRateTimeline()
    runPacketInputs(for: date) { [weak self] in
      guard let self else {
        return
      }
      self.healthMetricRefreshStatus = "Recomputing packet-derived scores..."
      self.runPacketScores(for: date) { [weak self] in
        guard let self else {
          return
        }
        self.healthMetricRefreshIsRunning = false
        self.healthMetricRefreshStatus = self.packetScoreStatus
      }
    }
  }

  func refreshHeartRateTimeline(for date: Date = Date()) {
    let refreshID = UUID()
    heartRateTimelineRefreshID = refreshID
    let store = heartRateSeriesStore
    heartRateTimelineQueue.async { [weak self] in
      let snapshot = store.timelineSnapshot(forDayContaining: date)
      Task { @MainActor in
        guard let self,
              self.heartRateTimelineRefreshID == refreshID else {
          return
        }
        self.heartRateHourlyRanges = snapshot.ranges
        self.heartRateTimelineStatus = snapshot.status
      }
    }
  }

  func heartRateHourlyTimelineRows(maxRows: Int = 8) -> [HealthSummaryRow] {
    let ranges = Array(heartRateHourlyRanges.suffix(maxRows)).reversed()
    guard !ranges.isEmpty else {
      return []
    }

    return ranges.map { range in
      let hour = range.hourStart.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)))
      return HealthSummaryRow(
        "HR \(hour)",
        value: "\(range.minBPM)-\(range.maxBPM) bpm | avg \(range.averageBPM) | \(range.sampleCount) samples",
        source: .live("BLE heart-rate sample store"),
        systemImage: "heart"
      )
    }
  }

  func refreshPacketInputsAfterCapture() {
    packetInputRefreshWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.runPacketInputs()
    }
    packetInputRefreshWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
  }

  func refreshBridgeCatalogs() {
    catalogStatus = "Loading bridge catalog..."
    OpenVitalsRustBridge.performInBackground(qos: .utility, {
      let bridge = OpenVitalsRustBridge()
      let algorithmsValue = try bridge.requestValue(method: "metrics.built_in_definitions")
      let referencesValue = try bridge.requestValue(method: "metrics.reference_definitions")
      let preferencesValue = try bridge.requestValue(method: "metrics.default_preferences")

      let parsedAlgorithms = Self.algorithmRows(from: algorithmsValue)
        .map { HealthAlgorithmDefinition(row: $0, source: .bridge("metrics.built_in_definitions")) }
      let parsedReferences = Self.algorithmRows(from: referencesValue)
        .map { HealthAlgorithmDefinition(row: $0, source: .bridge("metrics.reference_definitions")) }
      let parsedPreferences = Self.preferenceRows(from: preferencesValue)

      return (parsedAlgorithms, parsedReferences, parsedPreferences)
    }) { [weak self] result in
      guard let self else {
        return
      }
      switch result {
      case .success(let (parsedAlgorithms, parsedReferences, parsedPreferences)):
        if !parsedAlgorithms.isEmpty {
          algorithmDefinitions = parsedAlgorithms
        }
        if !parsedReferences.isEmpty {
          referenceDefinitions = parsedReferences
        }
        if !parsedPreferences.isEmpty {
          selectedAlgorithmByFamily = parsedPreferences
        } else {
          selectedAlgorithmByFamily = Dictionary(
            uniqueKeysWithValues: algorithmDefinitions.map { ($0.family, $0.id) }
          )
        }
        catalogSource = .bridge("Rust metric registry")
        catalogStatus = "Bridge catalog loaded"
        refreshHealthDashboardSnapshots()
      case .failure(let error):
        algorithmDefinitions = []
        referenceDefinitions = []
        selectedAlgorithmByFamily = [:]
        catalogSource = .unavailable("Rust catalog unavailable")
        catalogStatus = "Metric catalog unavailable: \(Self.shortError(error))"
        refreshHealthDashboardSnapshots()
      }
    }
  }

  func selectAlgorithm(_ algorithmID: String, for family: String) {
    selectedAlgorithmByFamily[family] = algorithmID
  }

  func runPacketInputs(for date: Date = Date(), completion: (() -> Void)? = nil) {
    guard !packetInputIsRunning else {
      packetInputStatus = "Packet-derived input extraction already running..."
      completion?()
      return
    }
    packetInputRefreshWorkItem?.cancel()
    let runID = UUID()
    let inputWindow = Self.dailyMetricWindow(containing: date)
    packetInputRunID = runID
    packetInputWindow = inputWindow
    packetInputIsRunning = true
    let databasePath = databasePath
    packetInputStatus = "Extracting packet-derived inputs..."

    packetInputQueue.async { [weak self] in
      let result = HealthDataStore.packetInputBridgeReports(databasePath: databasePath, date: date)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.packetInputRunID == runID else {
          return
        }
        self.packetInputIsRunning = false
        switch result {
        case .success(let reports):
          self.packetInputReports = reports
          self.packetInputStatus = "Bridge packet-derived inputs extracted"
        case .failure(let error):
          self.packetInputStatus = "Bridge input extraction blocked: \(HealthDataStore.shortError(error))"
        }
        self.refreshHealthDashboardSnapshots()
        completion?()
      }
    }
  }

  func markBandSleepSyncRequested(automatic: Bool, canSync: Bool, detail: String) {
    if canSync {
      bandSleepImportStatus = automatic ? "Auto-syncing band sleep packets..." : "Syncing band sleep packets..."
    } else {
      bandSleepImportStatus = "Band sync unavailable: \(detail)"
    }
  }

  func markBandSleepSyncFailed(_ detail: String) {
    bandSleepImportStatus = "Band sync failed: \(detail)"
  }

  func refreshSleepAfterBandSync(packetCount: Int) {
    bandSleepImportStatus = "Band sync captured \(packetCount) packets | extracting sleep inputs..."
    runPacketInputs { [weak self] in
      guard let self else {
        return
      }
      self.runSleepScore { [weak self] in
        guard let self else {
          return
        }
        self.bandSleepImportStatus = "Band sync captured \(packetCount) packets | \(self.packetScoreStatus)"
      }
    }
  }
}
