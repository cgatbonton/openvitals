import Darwin
import Foundation
import SwiftUI
import UIKit

enum HealthMetricGroup: String, CaseIterable {
  case today = "Today"
  case vitals = "Vitals"
  case training = "Training"
  case algorithms = "Algorithms"
}

struct HealthTrendModel: Identifiable {
  let id: String
  let title: String
  let rangeLabel: String
  let summary: String
  let analysis: String
  let resources: [String]
  let points: [HealthTrendPoint]

  var hasData: Bool {
    !points.isEmpty
  }
}

struct HealthTrendPoint: Identifiable {
  let id = UUID()
  let label: String
  let value: Double
}

enum MetricSourceKind: String, Codable, CaseIterable, Equatable {
  case deviceCounter = "device_counter"
  case deviceSensor = "device_sensor"
  case localEstimate = "local_estimate"
  case unavailable
}

struct HealthDataSource: Equatable {
  enum Kind: String {
    case bridge = "Bridge"
    case local = "Local"
    case live = "Live"
    // HCC: a value the user's own self-hosted Command Center already scored.
    // Distinct from `.bridge` on purpose — the number was computed off-device,
    // and a row must be able to say so.
    case cloud = "Cloud"
    case unavailable = "Unavailable"
  }

  let kind: Kind
  let metricSourceKind: MetricSourceKind
  let detail: String

  init(kind: Kind, metricSourceKind: MetricSourceKind, detail: String) {
    self.kind = kind
    self.metricSourceKind = metricSourceKind
    self.detail = detail
  }

  static func bridge(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .bridge, metricSourceKind: .localEstimate, detail: detail)
  }

  static func bridgeDeviceSensor(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .bridge, metricSourceKind: .deviceSensor, detail: detail)
  }

  static func bridgeDeviceCounter(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .bridge, metricSourceKind: .deviceCounter, detail: detail)
  }

  static func local(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .local, metricSourceKind: .localEstimate, detail: detail)
  }

  static func live(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .live, metricSourceKind: .deviceSensor, detail: detail)
  }

  static func unavailable(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .unavailable, metricSourceKind: .unavailable, detail: detail)
  }

  // HCC: a score the Command Center's own engine produced — an estimate made
  // off this device, so `.localEstimate` is the honest metric-source kind.
  static func cloud(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .cloud, metricSourceKind: .localEstimate, detail: detail)
  }

  // HCC: a vital the Command Center relayed from a wearable's sensor rather
  // than derived itself.
  static func cloudDeviceSensor(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .cloud, metricSourceKind: .deviceSensor, detail: detail)
  }

  static func deviceCounter(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .live, metricSourceKind: .deviceCounter, detail: detail)
  }

  static func deviceSensor(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .live, metricSourceKind: .deviceSensor, detail: detail)
  }

  static func localEstimate(_ detail: String) -> HealthDataSource {
    HealthDataSource(kind: .local, metricSourceKind: .localEstimate, detail: detail)
  }

  var label: String {
    "\(kind.rawValue): \(detail)"
  }
}

struct HealthSummaryRow: Identifiable {
  let id: String
  let label: String
  let value: String
  let status: String
  let source: HealthDataSource
  let systemImage: String

  init(
    _ label: String,
    value: String,
    status: String = "",
    source: HealthDataSource,
    systemImage: String = "circle"
  ) {
    self.id = label
    self.label = label
    self.value = value
    self.status = status
    self.source = source
    self.systemImage = systemImage
  }
}

struct HealthSleepStageSegment: Identifiable {
  let id: String
  let stage: String
  let startLabel: String
  let endLabel: String
  let durationMinutes: Double
  let confidence: Double?
  let source: HealthDataSource

  var displayStage: String {
    stage.capitalized
  }

  var durationText: String {
    HealthDataStore.minutesText(durationMinutes)
  }
}

struct PrimarySleepDetail: Identifiable {
  let id: String
  let dateLabel: String
  let startLabel: String
  let endLabel: String
  let durationText: String
  let timeInBedText: String
  let scoreText: String
  let qualityText: String
  let source: HealthDataSource
  let stages: [HealthSleepStageSegment]

  var scoreDisplayText: String {
    scoreText == "--" ? "--" : "\(scoreText)%"
  }
}

struct CardioLoadDay: Identifiable {
  let id: String
  let dateLabel: String
  let load: Double
  let status: String
  let durationText: String
  let percent: Double
  let source: HealthDataSource
}

struct CardioLoadAlgorithmSummary {
  let points: [CardioLoadDay]
  let status: String
  let freshness: String
  let source: HealthDataSource
  let sessionCount: Int
  let activityDayCount: Int
  let hasBaseline: Bool

  var latestPoint: CardioLoadDay? {
    points.last
  }

  var hasData: Bool {
    !points.isEmpty
  }
}

struct CardioLoadSessionContribution {
  let sessionID: String
  let start: Date
  let end: Date
  let dayStart: Date
  let load: Double
  let durationMinutes: Double
}

struct CardioLoadDailyComputation {
  let dayStart: Date
  let load: Double
  let durationMinutes: Double
  let status: String
}

struct EnergyStressPoint: Identifiable {
  let id: String
  let timeLabel: String
  let energy: Double
  let stress: Double
  let usage: Double
  let isSleepWindow: Bool
  let isChargeEvent: Bool
}

struct StressWindowPoint: Identifiable {
  let id: String
  let start: Date
  let end: Date
  let timeLabel: String
  let stress: Double
  let averageHeartRate: Double
  let sampleCount: Int
  let isSleepWindow: Bool

  var durationMinutes: Double {
    max(end.timeIntervalSince(start) / 60.0, 0)
  }
}

struct StressZoneSummary {
  let label: String
  let percent: Double
  let durationMinutes: Double
}

struct StressAlgorithmSummary {
  let score: Double?
  let status: String
  let averageHeartRate: Double?
  let averageHRV: Double?
  let windows: [StressWindowPoint]
  let high: StressZoneSummary
  let medium: StressZoneSummary
  let low: StressZoneSummary
  let sampleCount: Int
  let source: HealthDataSource
  let freshness: String
  let confidence: Double?
  let inputSummary: String

  var hasData: Bool {
    score != nil && !windows.isEmpty
  }
}

struct EnergyBankAlgorithmSummary {
  let percent: Double?
  let status: String
  let points: [EnergyStressPoint]
  let totalCharged: Double
  let totalDrained: Double
  let primarySleepCharge: Double
  let source: HealthDataSource
  let freshness: String
  let confidence: Double?
  let inputSummary: String

  var hasData: Bool {
    percent != nil && !points.isEmpty
  }
}

struct DailyMetricWindow {
  let dateKey: String
  let timezone: String
  let start: Date
  let end: Date
  let startISO: String
  let endISO: String
  let startTimeUnixMS: Int64
  let endTimeUnixMS: Int64
}

enum HealthPreviewState {
  case populated
  case missing
  case recoveryNoData
  case recoveryBridgeData
  case recoveryPacketRunBlocked
}

struct RecoveryDailyMetric: Identifiable {
  let id: String
  let dateKey: String?
  let timezone: String?
  let startTimeUnixMS: Int64?
  let endTimeUnixMS: Int64?
  let restingHRBPM: Double?
  let hrvRMSSDMS: Double?
  let respiratoryRateRPM: Double?
  let oxygenSaturationPercent: Double?
  let skinTemperatureDeltaC: Double?
  let sourceKind: MetricSourceKind
  let confidence: Double?
  let inputs: [String: Any]
  let qualityFlags: [String]
  let provenance: [String: Any]
  let rawRow: [String: Any]

  init?(row: [String: Any]) {
    guard let rawSourceKind = row["source_kind"] as? String,
          let sourceKind = MetricSourceKind(rawValue: rawSourceKind) else {
      return nil
    }
    rawRow = row
    id = row["daily_metric_id"] as? String
      ?? row["metric_id"] as? String
      ?? "\(row["date_key"] as? String ?? "unknown")-\(rawSourceKind)"
    dateKey = row["date_key"] as? String ?? row["date"] as? String
    timezone = row["timezone"] as? String
    startTimeUnixMS = Self.int64Value(row["start_time_unix_ms"])
    endTimeUnixMS = Self.int64Value(row["end_time_unix_ms"])
    restingHRBPM = Self.doubleValue(row["resting_hr_bpm"])
    hrvRMSSDMS = Self.doubleValue(row["hrv_rmssd_ms"])
    respiratoryRateRPM = Self.doubleValue(row["respiratory_rate_rpm"])
    oxygenSaturationPercent = Self.doubleValue(row["oxygen_saturation_percent"])
    skinTemperatureDeltaC = Self.doubleValue(row["skin_temperature_delta_c"])
    self.sourceKind = sourceKind
    confidence = Self.doubleValue(row["confidence"])
    inputs = Self.jsonObject(fromJSONString: row["inputs_json"]) ?? [:]
    qualityFlags = Self.jsonArray(fromJSONString: row["quality_flags_json"]) as? [String] ?? []
    provenance = Self.jsonObject(fromJSONString: row["provenance_json"]) ?? [:]
  }

  var isDeviceSensor: Bool {
    sourceKind == .deviceSensor
  }

  var hasAnyValue: Bool {
    restingHRBPM != nil
      || hrvRMSSDMS != nil
      || respiratoryRateRPM != nil
      || oxygenSaturationPercent != nil
      || skinTemperatureDeltaC != nil
  }

  var metricID: String {
    inputs["metric_id"] as? String
      ?? provenance["metric_id"] as? String
      ?? id
  }

  var metricName: String {
    inputs["metric_name"] as? String
      ?? provenance["metric_name"] as? String
      ?? Self.displayName(for: metricID)
  }

  var blockerReasons: [String] {
    let inputBlockers = inputs["blocker_reasons"] as? [String] ?? []
    let provenanceBlockers = provenance["blocker_reasons"] as? [String] ?? []
    let flagBlockers = qualityFlags.filter {
      !$0.contains("unavailable") && !$0.contains("source_kind")
    }
    return Array(Set(inputBlockers + provenanceBlockers + flagBlockers)).sorted()
  }

  func value(for key: String) -> Double? {
    switch key {
    case "resting_hr_bpm":
      return restingHRBPM
    case "hrv_rmssd_ms":
      return hrvRMSSDMS
    case "respiratory_rate_rpm":
      return respiratoryRateRPM
    case "oxygen_saturation_percent":
      return oxygenSaturationPercent
    case "skin_temperature_delta_c":
      return skinTemperatureDeltaC
    default:
      return Self.doubleValue(rawRow[key])
    }
  }

  static func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double {
      return double
    }
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let text = value as? String {
      return Double(text)
    }
    return nil
  }

  static func int64Value(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 {
      return int64
    }
    if let int = value as? Int {
      return Int64(int)
    }
    if let number = value as? NSNumber {
      return number.int64Value
    }
    if let text = value as? String {
      return Int64(text)
    }
    return nil
  }

  static func jsonObject(fromJSONString value: Any?) -> [String: Any]? {
    guard let string = value as? String,
          let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object
  }

  static func jsonArray(fromJSONString value: Any?) -> [Any]? {
    guard let string = value as? String,
          let data = string.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
      return nil
    }
    return array
  }

  static func displayName(for metricID: String) -> String {
    switch metricID {
    case "resting_hr_bpm":
      return "Resting HR"
    case "hrv_rmssd_ms":
      return "Resting HRV"
    case "respiratory_rate_rpm":
      return "Respiratory Rate"
    case "oxygen_saturation_percent":
      return "Oxygen Saturation"
    case "skin_temperature_delta_c":
      return "Wrist Temperature"
    default:
      return metricID
    }
  }
}

struct RecoveryTimelineRow: Identifiable {
  enum Kind {
    case score
    case sleep
    case metric
    case blocker
  }

  let id: String
  let kind: Kind
  let title: String
  let value: String
  let detail: String
  let source: HealthDataSource
  let systemImage: String
  let sortTimeUnixMS: Int64
}

struct HealthAlgorithmDefinition: Identifiable {
  let id: String
  let displayName: String
  let family: String
  let status: String
  let provider: String
  let source: HealthDataSource

  init(row: [String: Any], source: HealthDataSource) {
    let algorithmID = row["algorithm_id"] as? String ?? row["id"] as? String ?? "unknown.algorithm"
    id = algorithmID
    displayName = row["display_name"] as? String ?? algorithmID
    family = row["metric_family"] as? String ?? "metric"
    status = row["status"] as? String ?? "ready"
    provider = row["provider"] as? String ?? row["implementation"] as? String ?? "openVitals"
    self.source = source
  }

  init(id: String, displayName: String, family: String, status: String, provider: String, source: HealthDataSource) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.status = status
    self.provider = provider
    self.source = source
  }
}
