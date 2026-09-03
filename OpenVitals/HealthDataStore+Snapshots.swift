import Darwin
import Foundation
import SwiftUI
import UIKit

extension HealthDataStore {
  func runPacketScores(for date: Date = Date(), completion: (() -> Void)? = nil) {
    // HCC: cloud mode has no local score run — the server already scored the
    // day, so "recompute" means "read it again".
    if HCCProviderSettings.isCloud {
      Task {
        await refreshFromHCC(date: date)
        completion?()
      }
      return
    }
    guard !packetScoreIsRunning else {
      pendingPacketScoreDate = date
      packetScoreStatus = "Bridge score run already running; queued selected date..."
      completion?()
      return
    }

    let runID = UUID()
    let scoreWindow = Self.dailyMetricWindow(containing: date)
    packetScoreRunID = runID
    packetScoreWindow = scoreWindow
    packetScoreIsRunning = true
    packetScoreStatus = "Recomputing packet-derived scores..."
    let databasePath = databasePath

    packetScoreQueue.async {
      let result = Self.packetScoreBridgeReports(databasePath: databasePath, scoreDate: date)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.packetScoreRunID == runID else {
          return
        }
        self.packetScoreIsRunning = false
        switch result {
        case .success(let reports):
          self.packetScoreReports = reports
          self.refreshPrimarySleepFromScoreReport()
          self.packetScoreStatus = "Bridge packet-derived scores recomputed"
        case .failure(let error):
          self.packetScoreStatus = "Bridge score run blocked: \(Self.shortError(error))"
        }
        self.refreshHealthDashboardSnapshots()
        completion?()
        if let pendingDate = self.pendingPacketScoreDate {
          self.pendingPacketScoreDate = nil
          let pendingWindow = Self.dailyMetricWindow(containing: pendingDate)
          if pendingWindow.dateKey != self.packetScoreWindow.dateKey {
            self.runPacketScores(for: pendingDate)
          }
        }
      }
    }
  }

  func loadPersistedPacketScoresIfNeeded(
    for date: Date = Date(),
    recomputeIfMissing: Bool = false
  ) {
    // HCC: nothing is persisted locally in cloud mode.
    guard !HCCProviderSettings.isCloud else {
      return
    }
    let scoreWindow = Self.dailyMetricWindow(containing: date)
    let shouldLoadPersistedReports = packetScoreReports.isEmpty || packetScoreWindow.dateKey != scoreWindow.dateKey || packetScoreStatus == "No run"
    guard shouldLoadPersistedReports else {
      if recomputeIfMissing,
         !packetScoreIsRunning,
         !Self.strainScoreReportIsDisplayable(packetScoreReports["strain"], in: scoreWindow) {
        runPacketScores(for: date)
      }
      return
    }
    guard FileManager.default.fileExists(atPath: databasePath) else {
      packetScoreStatus = "No persisted packet-derived scores"
      return
    }

    let runID = UUID()
    packetScoreRunID = runID
    packetScoreWindow = scoreWindow
    packetScoreReports = [:]
    packetScoreIsRunning = true
    packetScoreStatus = "Loading persisted packet-derived scores..."
    let databasePath = databasePath

    packetScoreQueue.async {
      let result = Self.persistedPacketScoreBridgeReports(databasePath: databasePath, scoreDate: date)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.packetScoreRunID == runID else {
          return
        }
        self.packetScoreIsRunning = false
        switch result {
        case .success(let reports):
          if reports.isEmpty {
            self.packetScoreStatus = "No persisted packet-derived scores"
            if recomputeIfMissing {
              self.runPacketScores(for: date)
              return
            }
          } else {
            self.packetScoreReports = reports
            self.refreshPrimarySleepFromScoreReport()
            self.packetScoreStatus = "Loaded persisted packet-derived scores"
            if recomputeIfMissing,
               !Self.strainScoreReportIsDisplayable(reports["strain"], in: scoreWindow) {
              self.refreshHealthDashboardSnapshots()
              self.runPacketScores(for: date)
              return
            }
          }
        case .failure(let error):
          self.packetScoreStatus = "Persisted score load blocked: \(Self.shortError(error))"
        }
        self.refreshHealthDashboardSnapshots()
      }
    }
  }

  func runSleepScore(completion: (() -> Void)? = nil) {
    guard !packetScoreIsRunning else {
      packetScoreStatus = "Bridge sleep score already running..."
      completion?()
      return
    }

    let runID = UUID()
    packetScoreRunID = runID
    packetScoreIsRunning = true
    packetScoreStatus = "Recomputing sleep score..."
    let databasePath = databasePath

    packetScoreQueue.async {
      let result = Self.sleepScoreBridgeReport(databasePath: databasePath)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.packetScoreRunID == runID else {
          return
        }
        self.packetScoreIsRunning = false
        switch result {
        case .success(let report):
          self.packetScoreReports["sleep"] = report
          self.refreshPrimarySleepFromScoreReport()
          self.packetScoreStatus = "Bridge sleep score recomputed"
        case .failure(let error):
          self.packetScoreStatus = "Bridge sleep score blocked: \(Self.shortError(error))"
        }
        self.refreshHealthDashboardSnapshots()
        completion?()
      }
    }
  }

  func runReferenceComparisons() {
    referenceComparisonReports = [:]
    for family in ["hrv", "sleep", "strain", "stress"] {
      referenceRunStatusByFamily[family] = "blocked | real comparison inputs not wired"
    }
  }

  nonisolated static func packetScoreBridgeReports(
    databasePath: String,
    scoreDate: Date = Date()
  ) -> Result<[String: [String: Any]], Error> {
    let bridge = OpenVitalsRustBridge()
    let baseArgs = packetScoreBaseArgs(databasePath: databasePath, requireTrustedEvidence: false)
    let strainWindow = dailyMetricWindow(containing: scoreDate)
    var reports: [String: [String: Any]] = [:]
    var firstError: Error?

    do {
      reports["sleep"] = try sleepScoreBridgeReport(bridge: bridge, baseArgs: baseArgs)
    } catch {
      firstError = error
    }

    do {
      reports["strain"] = try bridge.request(
        method: "metrics.strain_score_from_features",
        args: baseArgs.merging([
          "start": strainWindow.startISO,
          "end": strainWindow.endISO,
          "resting_start": "0000",
          "resting_end": "9999",
          "resting_baseline_min_days": 3,
          "persist_algorithm_run": true,
        ]) { _, new in new }
      )
    } catch {
      if firstError == nil {
        firstError = error
      }
    }

    do {
      reports["recovery"] = try bridge.request(
        method: "metrics.recovery_score_from_features",
        args: baseArgs.merging(packetScoreRecoveryArgs()) { _, new in new }
      )
    } catch {
      if firstError == nil {
        firstError = error
      }
    }

    do {
      reports["stress"] = try bridge.request(
        method: "metrics.stress_score_from_features",
        args: baseArgs.merging([
          "resting_start": "0000",
          "resting_end": "9999",
          "hrv_start": "0000",
          "hrv_end": "9999",
          "hrv_baseline_start": "0000",
          "hrv_baseline_end": "9999",
          "resting_baseline_min_days": 3,
          "hrv_min_rr_intervals_to_compute": 2,
          "hrv_baseline_min_days": 3,
        ]) { _, new in new }
      )
    } catch {
      if firstError == nil {
        firstError = error
      }
    }

    if reports.isEmpty, let firstError {
      return .failure(firstError)
    }
    return .success(reports)
  }

  nonisolated static func persistedPacketScoreBridgeReports(
    databasePath: String,
    scoreDate: Date = Date()
  ) -> Result<[String: [String: Any]], Error> {
    let bridge = OpenVitalsRustBridge()
    let scoreWindow = dailyMetricWindow(containing: scoreDate)
    do {
      let value = try bridge.request(
        method: "metrics.persisted_score_reports",
        args: [
          "database_path": databasePath,
          "start": scoreWindow.startISO,
          "end": scoreWindow.endISO,
          "families": ["sleep", "recovery", "strain"],
        ]
      )
      let rawReports = value["reports"] as? [String: Any] ?? [:]
      let reports = rawReports.reduce(into: [String: [String: Any]]()) { output, element in
        if let report = element.value as? [String: Any] {
          output[element.key] = report
        }
      }
      return .success(reports)
    } catch {
      return .failure(error)
    }
  }

  nonisolated static func rawEvidenceBoundsBridgeReport(
    databasePath: String
  ) -> Result<[String: Any], Error> {
    let bridge = OpenVitalsRustBridge()
    do {
      return .success(try bridge.request(
        method: "storage.raw_evidence_bounds",
        args: [
          "database_path": databasePath,
        ]
      ))
    } catch {
      return .failure(error)
    }
  }

  nonisolated static func sleepScoreBridgeReport(databasePath: String) -> Result<[String: Any], Error> {
    let bridge = OpenVitalsRustBridge()
    let baseArgs = packetScoreBaseArgs(databasePath: databasePath, requireTrustedEvidence: false)
    do {
      return .success(try sleepScoreBridgeReport(bridge: bridge, baseArgs: baseArgs))
    } catch {
      return .failure(error)
    }
  }

  nonisolated static func sleepScoreBridgeReport(
    bridge: OpenVitalsRustBridge,
    baseArgs: [String: Any]
  ) throws -> [String: Any] {
    try bridge.request(
      method: "metrics.sleep_score_from_features",
      args: baseArgs.merging([
        "sleep_need_minutes": 480.0,
        "low_motion_threshold_0_to_1": 0.05,
        "disturbance_motion_threshold_0_to_1": 0.20,
        "target_midpoint_minutes_since_midnight": 180.0,
        "history_import_in_progress": false,
        "algorithm_id": OpenVitalsPacketScoreAlgorithmID.sleep,
        "persist_algorithm_run": true,
      ]) { _, new in new }
    )
  }

  nonisolated static func packetScoreBaseArgs(
    databasePath: String,
    requireTrustedEvidence: Bool
  ) -> [String: Any] {
    [
      "database_path": databasePath,
      "start": "0000",
      "end": "9999",
      "min_owned_captures": 2,
      "require_trusted_evidence": requireTrustedEvidence,
    ]
  }

  nonisolated static func packetScoreRecoveryArgs() -> [String: Any] {
    [
      "hrv_start": "0000",
      "hrv_end": "9999",
      "hrv_baseline_start": "0000",
      "hrv_baseline_end": "9999",
      "resting_start": "0000",
      "resting_end": "9999",
      "sleep_start": "0000",
      "sleep_end": "9999",
      "prior_strain_start": "0000",
      "prior_strain_end": "9999",
      "resting_baseline_min_days": 3,
      "hrv_min_rr_intervals_to_compute": 2,
      "hrv_baseline_min_days": 3,
      "sleep_need_minutes": 480.0,
      "low_motion_threshold_0_to_1": 0.05,
      "disturbance_motion_threshold_0_to_1": 0.20,
      "target_midpoint_minutes_since_midnight": 180.0,
      "prior_strain_resting_baseline_min_days": 3,
      "persist_algorithm_run": true,
    ]
  }

  func importCalibrationLabels() {
    calibrationLabelsImported = true
  }

  func calibrate() {
    calibrationRunComplete = true
  }

  var algorithmFamilies: [String] {
    let families = Set(algorithmDefinitions.map(\.family))
      .union(["recovery", "sleep", "strain", "stress", "hrv"])
    return families.sorted()
  }

  func algorithms(for family: String) -> [HealthAlgorithmDefinition] {
    algorithmDefinitions.filter { $0.family == family }
  }

  func landingSnapshots(
    liveHeartRateBPM: Int?,
    liveHeartRateSource: String,
    liveHeartRateUpdatedAt: Date?,
    stableDailyMetrics: Bool = false
  ) -> [HealthMetricSnapshot] {
    var snapshots = Self.baseLandingSnapshots
    if let index = snapshots.firstIndex(where: { $0.route == .sleep }) {
      snapshots[index] = sleepSnapshot(base: snapshots[index])
    }
    if let index = snapshots.firstIndex(where: { $0.route == .recovery }) {
      snapshots[index] = recoverySnapshot(base: snapshots[index])
    }
    if let index = snapshots.firstIndex(where: { $0.route == .strain }) {
      snapshots[index] = strainSnapshot(base: snapshots[index])
    }
    let stressSummary = stressAlgorithmSummary(allowLiveFallbacks: !stableDailyMetrics)
    if let index = snapshots.firstIndex(where: { $0.route == .stress }) {
      snapshots[index] = stressSnapshot(base: snapshots[index], summary: stressSummary)
    }
    if let index = snapshots.firstIndex(where: { $0.route == .cardioLoad }) {
      snapshots[index] = cardioLoadSnapshot(base: snapshots[index])
    }
    if let index = snapshots.firstIndex(where: { $0.route == .energyBank }) {
      snapshots[index] = energyBankSnapshot(base: snapshots[index], summary: energyBankAlgorithmSummary(from: stressSummary))
    }
    if let index = snapshots.firstIndex(where: { $0.route == .packetInputs }) {
      snapshots[index] = packetInputsSnapshot(base: snapshots[index])
    }
    if let index = snapshots.firstIndex(where: { $0.route == .algorithms }) {
      snapshots[index] = algorithmsSnapshot(base: snapshots[index])
    }
    if let index = snapshots.firstIndex(where: { $0.route == .calibration }) {
      snapshots[index] = calibrationSnapshot(base: snapshots[index])
    }
    if let liveHeartRateBPM,
       let index = snapshots.firstIndex(where: { $0.id == "health-monitor" }) {
      snapshots[index] = HealthMetricSnapshot(
        id: "health-monitor",
        route: .healthMonitor,
        group: .today,
        title: "Health Monitor",
        value: "\(liveHeartRateBPM)",
        unit: "bpm",
        status: "Live HR",
        freshness: Self.relativeText(for: liveHeartRateUpdatedAt) ?? "Now",
        provenance: liveHeartRateSource,
        source: .live("BLE heart rate stream"),
        systemImage: "heart.text.square",
        tint: .red,
        trend: snapshots[index].trend
      )
    }
    return snapshots
  }

  func refreshHealthDashboardSnapshots() {
    // HCC: rebuild from the cached cloud payloads instead of the bridge's
    // landing snapshots, which would run SQLite reads that cannot succeed here.
    if HCCProviderSettings.isCloud {
      rebuildHCCDashboardState()
      return
    }
    let landing = landingSnapshots(
      liveHeartRateBPM: nil,
      liveHeartRateSource: "",
      liveHeartRateUpdatedAt: nil,
      stableDailyMetrics: true
    )
    healthDashboardVitalSnapshots = trimmedHealthMonitorSnapshots(allowLiveFallbacks: false)
    healthDashboardExploreSnapshots = healthDashboardSnapshots(
      for: [.sleep, .recovery, .strain, .stress, .cardioLoad, .energyBank],
      in: landing
    )
    healthDashboardAlgorithmSnapshots = healthDashboardSnapshots(
      for: [.packetInputs, .algorithms, .calibration],
      in: landing
    )
    healthDashboardStepsText = whoopStepsDisplayText()
    healthDashboardStepsStatus = whoopStepsStatusText()
    healthDashboardStepsSource = whoopStepsSource()
    healthDashboardActiveEnergyText = whoopActiveCaloriesDisplayText()
    healthDashboardActiveEnergyStatus = whoopActiveCaloriesStatusText()
    healthDashboardActiveEnergySource = whoopActiveCaloriesSource()
    healthDashboardCardioLoadDays = cardioLoadWeeklyPoints()
  }

  func healthDashboardSnapshots(
    for routes: [HealthRoute],
    in landingSnapshots: [HealthMetricSnapshot]
  ) -> [HealthMetricSnapshot] {
    routes.compactMap { route in
      landingSnapshots.first { $0.route == route } ?? snapshot(for: route)
    }
  }

  func trimmedHealthMonitorSnapshots(allowLiveFallbacks: Bool = true) -> [HealthMetricSnapshot] {
    // HCC: the cloud rows are already exactly the streams the server reports —
    // there is no live-BLE subset to trim down to.
    if HCCProviderSettings.isCloud {
      return hccVitalSnapshots()
    }
    let visibleIDs = ["respiratory-rate", "resting-hr", "resting-hrv"]
    return healthMonitorSnapshots(allowLiveFallbacks: allowLiveFallbacks).filter { snapshot in
      visibleIDs.contains(snapshot.id)
    }
  }

  func healthMonitorSnapshots(
    restingHeartRateEstimateBPM: Double? = nil,
    restingHeartRateEstimateSampleCount: Int = 0,
    restingHeartRateEstimateUpdatedAt: Date? = nil,
    restingHeartRateEstimateSource: String = "ble.hr.standard.low_quartile",
    allowLiveFallbacks: Bool = true
  ) -> [HealthMetricSnapshot] {
    // HCC: every vital comes off `/vitals`; none of the packet-feature or live
    // BLE fallbacks below have anything to read in cloud mode.
    if HCCProviderSettings.isCloud {
      return hccVitalSnapshots()
    }
    if previewMissingData {
      return Self.baseHealthMonitorSnapshots.map { snapshot in
        HealthMetricSnapshot(
          id: snapshot.id,
          route: snapshot.route,
          group: snapshot.group,
          title: snapshot.title,
          value: "--",
          unit: snapshot.unit,
          status: "Unavailable",
          freshness: "No local data",
          provenance: "preview missing data",
          source: .unavailable("preview missing data"),
          systemImage: snapshot.systemImage,
          tint: snapshot.tint,
          trend: HealthTrendModel(id: snapshot.trend.id, title: snapshot.trend.title, rangeLabel: "No data", summary: "No trend data", analysis: "No local data has been captured for this trend yet.", resources: snapshot.trend.resources, points: [])
        )
      }
    }
    var snapshots = Self.baseHealthMonitorSnapshots.map {
      packetBackedHealthMonitorSnapshot(base: $0, allowLiveFallbacks: allowLiveFallbacks)
    }
    if allowLiveFallbacks,
       let index = snapshots.firstIndex(where: { $0.id == "resting-hr" }),
       snapshots[index].source.kind == .unavailable,
       let sample = Self.liveHRDerivedRestingHeartRateSample(
        bpm: restingHeartRateEstimateBPM,
        sampleCount: restingHeartRateEstimateSampleCount,
        updatedAt: restingHeartRateEstimateUpdatedAt,
        source: restingHeartRateEstimateSource
       ) {
      snapshots[index] = liveHRDerivedRestingHeartRateHealthMonitorSnapshot(
        base: snapshots[index],
        sample: sample
      )
    }
    if let index = snapshots.firstIndex(where: { $0.id == "health-sleep" }) {
      snapshots[index] = sleepHealthMonitorSnapshot(base: snapshots[index])
    }
    return snapshots
  }

  func snapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    // HCC: every detail screen resolves its hero through here, so this is the
    // single place cloud mode has to answer for a route.
    if HCCProviderSettings.isCloud {
      return hccSnapshot(for: route)
    }
    let snapshot = Self.baseLandingSnapshots.first { $0.route == route }
      ?? Self.baseLandingSnapshots[0]
    if route == .sleep && !previewMissingData {
      return sleepSnapshot(base: snapshot)
    }
    if route == .recovery {
      return recoverySnapshot(base: snapshot)
    }
    if route == .strain && !previewMissingData {
      return strainSnapshot(base: snapshot)
    }
    if route == .stress && !previewMissingData {
      return stressSnapshot(base: snapshot)
    }
    if route == .cardioLoad && !previewMissingData {
      return cardioLoadSnapshot(base: snapshot)
    }
    if route == .energyBank && !previewMissingData {
      return energyBankSnapshot(base: snapshot)
    }
    if route == .packetInputs && !previewMissingData {
      return packetInputsSnapshot(base: snapshot)
    }
    if route == .algorithms && !previewMissingData {
      return algorithmsSnapshot(base: snapshot)
    }
    if route == .calibration && !previewMissingData {
      return calibrationSnapshot(base: snapshot)
    }
    guard previewMissingData else {
      return snapshot
    }
    return HealthMetricSnapshot(
      id: snapshot.id,
      route: snapshot.route,
      group: snapshot.group,
      title: snapshot.title,
      value: "--",
      unit: snapshot.unit,
      status: "No data",
      freshness: "Missing",
      provenance: "preview missing data",
      source: .unavailable("preview missing data"),
      systemImage: snapshot.systemImage,
      tint: snapshot.tint,
      trend: HealthTrendModel(id: snapshot.trend.id, title: snapshot.trend.title, rangeLabel: "No data", summary: "No trend data", analysis: "No local data has been captured for this trend yet.", resources: snapshot.trend.resources, points: [])
    )
  }

  func strainSnapshot(for date: Date, calendar: Calendar = .current) -> HealthMetricSnapshot {
    // HCC: the server dates its own strain, so a cached day answers directly;
    // an uncached one falls through to the unavailable cloud base rather than
    // to a local history that does not exist.
    if HCCProviderSettings.isCloud {
      return hccStrainSnapshot(for: date) ?? hccSnapshot(for: .strain)
    }
    let base = Self.baseLandingSnapshots.first { $0.route == .strain } ?? Self.baseLandingSnapshots[0]
    let snapshot = strainSnapshot(base: base)
    let selectedWindow = Self.dailyMetricWindow(containing: date, calendar: calendar)
    guard selectedWindow.dateKey == packetScoreWindow.dateKey else {
      return zeroStrainSnapshot(
        base: snapshot,
        freshness: ScoreDateTimeline.dateLabel(for: date, calendar: calendar),
        provenance: "No local strain history for selected date",
        sourceDetail: "selected date has no local strain history"
      )
    }
    return snapshot
  }

  func sleepSnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    let sleepReport = packetScoreReports["sleep"]
    if Self.sleepScoreReportIsDisplayable(sleepReport),
       let output = Self.map(sleepReport, "score_result", "output") {
      let scoreText = Self.numberText(output["score_0_to_100"], fractionDigits: 0) ?? snapshot.value
      let algorithmID = Self.map(sleepReport, "score_result")?["algorithm_id"] as? String
        ?? OpenVitalsPacketScoreAlgorithmID.sleep
      return HealthMetricSnapshot(
        id: snapshot.id,
        route: snapshot.route,
        group: snapshot.group,
        title: snapshot.title,
        value: scoreText,
        unit: "%",
        status: Self.sleepQualityLabel(score: Self.doubleValue(output["score_0_to_100"])),
        freshness: "Latest",
        provenance: "metrics.sleep_score_from_features",
        source: .bridge(algorithmID),
        systemImage: snapshot.systemImage,
        tint: snapshot.tint,
        trend: snapshot.trend
      )
    }
    if let primarySleepDetail {
      return HealthMetricSnapshot(
        id: snapshot.id,
        route: snapshot.route,
        group: snapshot.group,
        title: snapshot.title,
        value: primarySleepDetail.durationText,
        unit: "",
        status: primarySleepDetail.qualityText,
        freshness: primarySleepDetail.dateLabel,
        provenance: primarySleepDetail.source.detail,
        source: primarySleepDetail.source,
        systemImage: snapshot.systemImage,
        tint: snapshot.tint,
        trend: snapshot.trend
      )
    }
    return snapshot
  }

  func sleepHealthMonitorSnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    if let primarySleepDetail {
      return HealthMetricSnapshot(
        id: snapshot.id,
        route: snapshot.route,
        group: snapshot.group,
        title: snapshot.title,
        value: primarySleepDetail.durationText,
        unit: "",
        status: primarySleepDetail.qualityText,
        freshness: primarySleepDetail.dateLabel,
        provenance: primarySleepDetail.source.detail,
        source: primarySleepDetail.source,
        systemImage: snapshot.systemImage,
        tint: snapshot.tint,
        trend: snapshot.trend
      )
    }
    let sleepReport = packetScoreReports["sleep"]
    if Self.sleepScoreReportIsDisplayable(sleepReport),
       let output = Self.map(sleepReport, "score_result", "output"),
       let duration = Self.doubleValue(output["sleep_duration_minutes"]) {
      let algorithmID = Self.map(sleepReport, "score_result")?["algorithm_id"] as? String
        ?? OpenVitalsPacketScoreAlgorithmID.sleep
      return HealthMetricSnapshot(
        id: snapshot.id,
        route: snapshot.route,
        group: snapshot.group,
        title: snapshot.title,
        value: Self.minutesText(duration),
        unit: "",
        status: Self.sleepQualityLabel(score: Self.doubleValue(output["score_0_to_100"])),
        freshness: "Latest",
        provenance: "metrics.sleep_score_from_features",
        source: .bridge(algorithmID),
        systemImage: snapshot.systemImage,
        tint: snapshot.tint,
        trend: snapshot.trend
      )
    }
    return snapshot
  }

  func recoverySnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    guard !usesPreviewPacketData,
          let score = recoveryScoreValue(),
          let scoreText = Self.numberText(score, fractionDigits: 0) else {
      return HealthMetricSnapshot(
        id: snapshot.id,
        route: snapshot.route,
        group: snapshot.group,
        title: snapshot.title,
        value: "--",
        unit: "%",
        status: "No data",
        freshness: "No recovery score",
        provenance: "metrics.recovery_score_from_features",
        source: .unavailable("recovery score not available"),
        systemImage: snapshot.systemImage,
        tint: snapshot.tint,
        trend: Self.emptyTrend(from: snapshot.trend, packetCount: packetEvidenceFrameCount())
      )
    }

    return HealthMetricSnapshot(
      id: snapshot.id,
      route: snapshot.route,
      group: snapshot.group,
      title: snapshot.title,
      value: scoreText,
      unit: "%",
      status: Self.recoveryQualityLabel(score: score),
      freshness: "Latest",
      provenance: "metrics.recovery_score_from_features",
      source: .bridge("open_vitals.recovery.v0"),
      systemImage: snapshot.systemImage,
      tint: snapshot.tint,
      trend: recoveryScoreTrend(base: snapshot.trend, currentScore: score)
    )
  }

  func packetInputsSnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    guard !packetInputReports.isEmpty else {
      if packetInputIsRunning {
        return replacingHealthMonitorSnapshot(
          snapshot,
          value: "--",
          unit: "",
          status: "Extracting",
          freshness: "Running",
          provenance: "metrics.packet_input_summary",
          source: .bridge("packet input extraction running"),
          trend: snapshot.trend
        )
      }
      if packetInputStatus != "No run" {
        return replacingHealthMonitorSnapshot(
          snapshot,
          value: "--",
          unit: "",
          status: "Blocked",
          freshness: packetInputStatus,
          provenance: "metrics.packet_input_summary",
          source: .unavailable(packetInputStatus),
          trend: snapshot.trend
        )
      }
      return snapshot
    }

    let ready = Self.intValue(packetInputReports["readiness"]?["ready_family_count"])
    let total = Self.intValue(packetInputReports["readiness"]?["family_count"])
      ?? Self.array(packetInputReports["readiness"]?["families"]).count
    let readyText = ready.map { readyValue in
      total > 0 ? "\(readyValue)/\(total) ready" : "\(readyValue) ready"
    } ?? "\(packetInputReports.count) reports"

    return replacingHealthMonitorSnapshot(
      snapshot,
      value: "\(packetInputReports.count)",
      unit: "reports",
      status: readyText,
      freshness: "Latest",
      provenance: metricInputReadinessSummary(),
      source: .bridge("metrics.packet_input_summary"),
      trend: Self.emptyTrend(from: snapshot.trend, packetCount: packetEvidenceFrameCount())
    )
  }

  func algorithmsSnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    let familyCount = algorithmFamilies.count
    guard !algorithmDefinitions.isEmpty else {
      if catalogStatus.hasPrefix("Loading") {
        return replacingHealthMonitorSnapshot(
          snapshot,
          value: "--",
          unit: "families",
          status: "Loading",
          freshness: "Bridge catalog",
          provenance: "metrics.built_in_definitions",
          source: .bridge("metric registry loading"),
          trend: snapshot.trend
        )
      }
      if catalogStatus != "Metric catalog not loaded" {
        return replacingHealthMonitorSnapshot(
          snapshot,
          value: "--",
          unit: "families",
          status: "Unavailable",
          freshness: catalogStatus,
          provenance: "metrics.built_in_definitions",
          source: catalogSource,
          trend: snapshot.trend
        )
      }
      return snapshot
    }

    return replacingHealthMonitorSnapshot(
      snapshot,
      value: "\(familyCount)",
      unit: "families",
      status: "Loaded",
      freshness: "\(algorithmDefinitions.count) algorithms",
      provenance: "metrics.built_in_definitions",
      source: catalogSource,
      trend: HealthTrendModel(
        id: snapshot.trend.id,
        title: snapshot.trend.title,
        rangeLabel: "\(familyCount) families",
        summary: "\(algorithmDefinitions.count) local algorithm definitions loaded from the bridge catalog.",
        analysis: "Algorithms are available for local score and metric surfaces.",
        resources: snapshot.trend.resources,
        points: []
      )
    )
  }

  func calibrationSnapshot(base snapshot: HealthMetricSnapshot) -> HealthMetricSnapshot {
    let issues = calibrationIssues()
    if calibrationRunComplete {
      return replacingHealthMonitorSnapshot(
        snapshot,
        value: "Ready",
        unit: "",
        status: calibrationTargetFamily.capitalized,
        freshness: calibrationSummary(),
        provenance: calibratedScoreSummary(),
        source: .local("local calibration run"),
        trend: snapshot.trend
      )
    }
    if calibrationLabelsImported {
      return replacingHealthMonitorSnapshot(
        snapshot,
        value: "1",
        unit: "label",
        status: "Needs run",
        freshness: calibrationNextActionSummary(),
        provenance: calibrationLabelSummary(),
        source: .local("stored calibration labels"),
        trend: snapshot.trend
      )
    }
    return replacingHealthMonitorSnapshot(
      snapshot,
      value: "--",
      unit: "",
      status: issues.first ?? "No labels",
      freshness: calibrationNextActionSummary(),
      provenance: calibrationSummary(),
      source: .unavailable("calibration requires stored labels and a local run"),
      trend: snapshot.trend
    )
  }

  var usesPreviewPacketData: Bool {
    packetInputStatus.hasPrefix("Preview") || packetScoreStatus.hasPrefix("Preview")
  }

  func recoveryScoreValue() -> Double? {
    // HCC: the single root every recovery readout (hero, coach tip, missing-data
    // list) resolves through, so one branch keeps them all agreeing with the
    // server instead of reporting 0 next to the server's own number.
    if HCCProviderSettings.isCloud {
      return hccScoreValue(for: .recovery)
    }
    guard !usesPreviewPacketData else {
      return nil
    }
    guard let output = Self.map(packetScoreReports["recovery"], "score_result", "output"),
          output["score_status"] as? String != "blocked" else {
      return nil
    }
    return Self.doubleValue(output["score_0_to_100"])
  }

  func recoveryScoreTrend(base trend: HealthTrendModel, currentScore: Double) -> HealthTrendModel {
    HealthTrendModel(
      id: trend.id,
      title: trend.title,
      rangeLabel: "\(Self.numberText(currentScore, fractionDigits: 0) ?? "0")%",
      summary: "Latest packet-derived recovery score",
      analysis: "Packet-derived recovery score from the local bridge.",
      resources: trend.resources,
      points: []
    )
  }

  func strainScore0To100(for date: Date = Date(), calendar: Calendar = .current) -> Double {
    let selectedWindow = Self.dailyMetricWindow(containing: date, calendar: calendar)
    guard selectedWindow.dateKey == packetScoreWindow.dateKey else {
      return 0
    }
    return currentStrainScore0To21().map(Self.strainPercent) ?? 0
  }

  func strainScoreDisplayText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    let score = strainScore0To100(for: date, calendar: calendar)
    guard score > 0 else {
      return "--"
    }
    return Self.numberText(score, fractionDigits: 0) ?? "0"
  }

  func strainStatusText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    let selectedWindow = Self.dailyMetricWindow(containing: date, calendar: calendar)
    guard selectedWindow.dateKey == packetScoreWindow.dateKey,
          let rawScore = currentStrainScore0To21() else {
      return "No strain data"
    }
    return Self.strainStatusLabel(score: Self.strainPercent(rawScore))
  }

  func strainTargetDisplayText() -> String {
    "--"
  }

  func strainDurationDisplayText() -> String {
    "--"
  }

  func strainEnergyDisplayText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    whoopTotalCaloriesDisplayText(for: date, calendar: calendar)
  }

  func strainActivityCountText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    whoopStepsDisplayText(for: date, calendar: calendar)
  }

  func whoopStepsDisplayText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    guard let metric = stepMetric(for: date, calendar: calendar),
          let steps = Self.intValue(metric["steps"]) else {
      return "--"
    }
    return Self.groupedIntegerText(steps)
  }

  func whoopActiveCaloriesDisplayText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    energyKcalDisplayText(key: "active_kcal", date: date, calendar: calendar)
  }

  func whoopTotalCaloriesDisplayText(for date: Date = Date(), calendar: Calendar = .current) -> String {
    energyKcalDisplayText(key: "total_kcal", date: date, calendar: calendar)
  }

  func whoopStepsStatusText() -> String {
    if let metric = todayStepMetric() {
      return stepMetricStatus(metric)
    }

    if let latest = Self.preferredStepMetric(from: dailyActivityMetrics()),
       let dateKey = latest["date_key"] as? String {
      return "No today step metric | latest stored \(dateKey)"
    }

    if let report = packetInputReports["step_counter_rollup"] {
      return firstPacketAction(in: report) ?? "Device step counter rollup blocked"
    }

    if let report = packetInputReports["step_counter_ingest"] {
      let persisted = Self.intValue(report["persisted_sample_count"]) ?? 0
      let candidates = Self.intValue(report["counter_candidate_count"]) ?? 0
      if persisted > 0 {
        return "\(persisted) device counter samples stored; daily delta pending"
      }
      if candidates > 0 {
        return "\(candidates) device counter candidates found; ingest blocked"
      }
    }

    if let motionReport = packetInputReports["motion"] {
      let total = Self.intValue(motionReport["feature_count"]) ?? 0
      let trusted = Self.intValue(motionReport["trusted_feature_count"]) ?? 0
      if total > 0 {
        return "Device motion ready | \(trusted)/\(total) trusted inputs"
      }
      return "Device motion captured; step metric pending"
    }

    if packetInputStatus == "No run" {
      return "Needs device packet extract"
    }
    return packetInputStatus
  }

  func whoopStepsSource(for date: Date = Date(), calendar: Calendar = .current) -> HealthDataSource {
    if let metric = stepMetric(for: date, calendar: calendar) {
      switch metric["source_kind"] as? String {
      case "device_counter":
        return .bridgeDeviceCounter("daily_activity_metrics device step counter")
      case "local_estimate":
        return .localEstimate("daily_activity_metrics validated raw-motion steps")
      default:
        return .unavailable("unsupported step metric source")
      }
    }
    guard calendar.isDate(calendar.startOfDay(for: date), inSameDayAs: calendar.startOfDay(for: Date())) else {
      return .unavailable("selected date has no stored device step metric")
    }
    if let report = packetInputReports["step_counter_rollup"] {
      return .unavailable(firstPacketAction(in: report) ?? "Device step counter rollup blocked")
    }
    if packetInputReports["motion"] == nil {
      return .unavailable("Device step extraction pending")
    }
    return .unavailable("Device step counter or validated local estimate not available")
  }

  func whoopActiveCaloriesStatusText() -> String {
    if let metric = energyMetric(for: Date(), valueKey: "active_kcal") {
      return energyMetricStatus(metric)
    }

    guard let report = packetInputReports["energy_rollup"] else {
      if let latest = Self.preferredDailyActivityMetric(
        from: dailyActivityMetricsWithValue("active_kcal"),
        valueKey: "active_kcal"
      ),
         let dateKey = latest["date_key"] as? String {
        return "No today calorie metric | latest stored \(dateKey)"
      }
      if packetInputStatus == "No run" {
        return "Needs device packet extract"
      }
      return packetInputStatus
    }
    if Self.boolValue(report["pass"]) == true,
       let confidence = Self.numberText(report["confidence"], fractionDigits: 2) {
      return "Local estimate | confidence \(confidence)"
    }
    return firstPacketAction(in: report) ?? "Calorie estimator blocked"
  }

  func whoopActiveCaloriesSource(
    for date: Date = Date(),
    calendar: Calendar = .current
  ) -> HealthDataSource {
    whoopEnergySource(for: date, calendar: calendar, valueKey: "active_kcal")
  }

  func whoopTotalCaloriesSource(
    for date: Date = Date(),
    calendar: Calendar = .current
  ) -> HealthDataSource {
    whoopEnergySource(for: date, calendar: calendar, valueKey: "total_kcal")
  }

  func whoopEnergySource(
    for date: Date,
    calendar: Calendar,
    valueKey: String
  ) -> HealthDataSource {
    if let metric = energyMetric(for: date, calendar: calendar, valueKey: valueKey) {
      return energyMetricSource(metric)
    }
    if let unavailable = preferredDailyActivityUnavailableMetric(metricID: valueKey, for: date, calendar: calendar) {
      return .unavailable(Self.activityUnavailableSourceDetail(unavailable))
    }
    guard calendar.isDate(calendar.startOfDay(for: date), inSameDayAs: calendar.startOfDay(for: Date())) else {
      return .unavailable("selected date has no stored device energy metric")
    }
    guard let report = packetInputReports["energy_rollup"] else {
      return .unavailable("metrics.energy_daily_rollup not run")
    }
    guard Self.boolValue(report["pass"]) == true else {
      return .unavailable("metrics.energy_daily_rollup blocked")
    }
    return .localEstimate("metrics.energy_daily_rollup")
  }

  func energyRollupSummary() -> String {
    guard let report = packetInputReports["energy_rollup"] else {
      return packetInputStatus == "No run" ? "No run" : packetInputStatus
    }
    let active = Self.numberText(report["active_kcal"], fractionDigits: 0) ?? "--"
    let resting = Self.numberText(report["resting_kcal"], fractionDigits: 0) ?? "--"
    let total = Self.numberText(report["total_kcal"], fractionDigits: 0) ?? "--"
    let confidence = Self.numberText(report["confidence"], fractionDigits: 2) ?? "0"
    return "\(Self.passStatus(report)) | active \(active) kcal | resting \(resting) kcal | total \(total) kcal | confidence \(confidence)"
  }

  func energyRollupProvenanceSummary() -> String {
    guard let report = packetInputReports["energy_rollup"] else {
      return ""
    }
    let written = Self.boolValue(report["daily_metric_written"]) == true ? "stored" : "not stored"
    let hrSamples = Self.intValue(report["heart_rate_sample_count"]) ?? 0
    let motionSamples = Self.intValue(report["motion_sample_count"]) ?? 0
    let coverage = Self.percentText(report["coverage_fraction"]) ?? "unknown"
    return "daily_metric=\(written) | HR=\(hrSamples) | motion=\(motionSamples) | coverage=\(coverage)"
  }

  func energyKcalDisplayText(
    key: String,
    date: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    if let metric = energyMetric(for: date, calendar: calendar, valueKey: key),
       let value = Self.doubleValue(metric[key]),
       value.isFinite {
      return "\(Self.groupedIntegerText(Int(value.rounded()))) kcal"
    }
    guard let report = packetInputReports["energy_rollup"],
          calendar.isDate(calendar.startOfDay(for: date), inSameDayAs: calendar.startOfDay(for: Date())),
          Self.boolValue(report["pass"]) == true,
          let value = Self.doubleValue(report[key]),
          value.isFinite else {
      return "-- kcal"
    }
    return "\(Self.groupedIntegerText(Int(value.rounded()))) kcal"
  }

  func todayStepMetric() -> [String: Any]? {
    stepMetric(for: Date())
  }

  func stepMetric(for date: Date, calendar: Calendar = .current) -> [String: Any]? {
    Self.preferredStepMetric(
      from: dailyActivityMetrics(forDateKey: Self.metricDateKey(for: date, calendar: calendar))
    )
  }

  func energyMetric(
    for date: Date,
    calendar: Calendar = .current,
    valueKey: String
  ) -> [String: Any]? {
    Self.preferredDailyActivityMetric(
      from: dailyActivityMetrics(forDateKey: Self.metricDateKey(for: date, calendar: calendar)),
      valueKey: valueKey
    )
  }

  func dailyActivityMetrics() -> [[String: Any]] {
    Self.array(packetInputReports["daily_activity"]?["metrics"])
      .filter { Self.localHealthMetricRowIsDisplaySafe($0) }
  }

  func dailyActivityMetrics(forDateKey dateKey: String) -> [[String: Any]] {
    dailyActivityMetrics().filter { $0["date_key"] as? String == dateKey }
  }

  func dailyActivityMetricsWithValue(_ valueKey: String) -> [[String: Any]] {
    dailyActivityMetrics().filter { Self.doubleValue($0[valueKey]) != nil }
  }

  func hourlyActivityMetrics() -> [[String: Any]] {
    Self.array(packetInputReports["hourly_activity"]?["metrics"])
      .filter { Self.localHealthMetricRowIsDisplaySafe($0) }
  }

  func hourlyActivityMetrics(forDateKey dateKey: String) -> [[String: Any]] {
    hourlyActivityMetrics().filter { $0["date_key"] as? String == dateKey }
  }

  func hourlyActivityMetricsWithValue(_ valueKey: String) -> [[String: Any]] {
    hourlyActivityMetrics().filter { Self.doubleValue($0[valueKey]) != nil }
  }

  func dailyActivityUnavailableMetrics(metricID: String? = nil) -> [[String: Any]] {
    dailyActivityMetrics()
      .filter { metric in
        guard metric["source_kind"] as? String == "unavailable",
              Self.doubleValue(metric["confidence"]) != nil else {
          return false
        }
        if let metricID {
          return Self.dailyActivityUnavailableMetric(metric, matches: metricID)
        }
        return true
      }
  }

  func preferredDailyActivityUnavailableMetric(
    metricID: String,
    for date: Date? = nil,
    calendar: Calendar = .current
  ) -> [String: Any]? {
    let dateKey = date.map { Self.metricDateKey(for: $0, calendar: calendar) }
    return dailyActivityUnavailableMetrics(metricID: metricID)
      .filter { metric in
        if let dateKey, metric["date_key"] as? String != dateKey {
          return false
        }
        return true
      }
      .sorted { lhs, rhs in
        let lhsEnd = Self.int64Value(lhs["end_time_unix_ms"]) ?? 0
        let rhsEnd = Self.int64Value(rhs["end_time_unix_ms"]) ?? 0
        if lhsEnd != rhsEnd {
          return lhsEnd > rhsEnd
        }
        let lhsUpdated = lhs["updated_at"] as? String ?? ""
        let rhsUpdated = rhs["updated_at"] as? String ?? ""
        return lhsUpdated > rhsUpdated
      }
      .first
  }

  static func dailyActivityUnavailableMetric(_ metric: [String: Any], matches metricID: String) -> Bool {
    if let inputsMetricID = jsonObject(fromJSONString: metric["inputs_json"])?["metric_id"] as? String,
       inputsMetricID == metricID {
      return true
    }
    let sanitizedMetricID = metricIDToken(metricID)
    let dailyMetricID = (metric["daily_metric_id"] as? String ?? "").lowercased()
    return dailyMetricID.contains(sanitizedMetricID)
  }

  static func activityUnavailableSourceDetail(_ metric: [String: Any]) -> String {
    let metricID = jsonObject(fromJSONString: metric["inputs_json"])?["metric_id"] as? String
      ?? metric["daily_metric_id"] as? String
      ?? "activity_metric"
    let blocker = firstActivityUnavailableBlocker(metric) ?? "metric unavailable"
    return "\(metricID) unavailable: \(blocker)"
  }

}
