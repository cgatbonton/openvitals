import Foundation
import SwiftUI

// HCC: the live workout's state box and the one write it makes.
//
// The live screen is the only screen in this app that produces numbers instead
// of only rendering them, so the rules it works under are stricter, not looser:
//
//   * every number on it is derived here from readings a source actually
//     delivered. A dropped connection shows "--", never the last value held;
//   * the running strain is the phone's own arithmetic and is labelled "est."
//     wherever it appears. The FINAL strain is the server's, read back off the
//     stored row — the phone's estimate is never written anywhere;
//   * the zone cuts come from `/instance`, so what the phone bins is what the
//     server would bin. Before that read lands they fall back to the values the
//     server currently publishes, and the screen says which ceiling it used.
//
// Views observe `HCCLiveState` and never touch the network or a radio: the
// source objects live here, the stream is drained here, and `finish()` is the
// only thing that talks to the server.

@MainActor
final class HCCLiveState: ObservableObject {
  enum Phase: Equatable {
    /// Nothing started; the setup sheet has not been opened.
    case idle
    /// The setup sheet is open and choosing.
    case setup
    case running
    case paused
    /// The upload is in flight.
    case ending
    /// Stored. `resultActivity` carries the server's row.
    case done
  }

  @Published private(set) var phase: Phase = .idle

  /// What is being recorded. The same slug vocabulary the manual sheet uses.
  @Published var type: String = HCCSportCatalog.slugs.first ?? "other"
  /// Set when the session was started from a Training conditioning day, so the
  /// stored row is named after that day rather than a generic slug.
  @Published var titleOverride: String?
  @Published var sourceKind: HCCLiveSourceKind = .watch {
    didSet {
      guard oldValue != sourceKind, !isDefaultingSourceKind else { return }
      sourceKindChosenByOwner = true
    }
  }
  /// True once the picker has been touched, so reopening the sheet does not
  /// overwrite a deliberate choice with the device pill's default.
  private var sourceKindChosenByOwner = false
  private var isDefaultingSourceKind = false

  /// The wrist device currently driving the display, in the server's own words
  /// ("Band", "Fitbit Air"), and whether it can stream a live reading at all.
  @Published private(set) var selectedDeviceLabel: String?
  @Published private(set) var selectedDeviceCanStream = true
  /// 1-based, as the chip reads it ("goal: Z2").
  @Published var goalZone: Int = 2

  @Published private(set) var startedAt: Date?
  /// Wall-clock seconds since the start, MINUS every paused stretch.
  @Published private(set) var elapsed: TimeInterval = 0

  @Published private(set) var currentBpm: Int?
  /// A reading taken while the setup sheet is open, before anything is being
  /// recorded. Tapping "Start activity" should show a heart rate immediately —
  /// that is the confirmation the right device is connected, and without it the
  /// only way to find out was to start a session and hope.
  @Published private(set) var previewBpm: Int?
  private var previewTask: Task<Void, Never>?
  private var previewStaleTask: Task<Void, Never>?
  /// The source the preview is currently draining.
  ///
  /// `samples` is a single `AsyncStream` with one continuation, so it supports
  /// exactly ONE iteration for its lifetime. Cancelling a drain and starting
  /// another on the same source tears the iterator down and the replacement
  /// receives nothing — while the device stays happily connected and keeps
  /// reporting that it is sending. Setup asks for a preview several times as
  /// the device list and zone config land, so this is what keeps those repeats
  /// from silently killing the readings.
  private weak var previewSource: AnyObject?
  #if DEBUG
  private var debugPreviewSource: HCCDebugHeartRateSource?
  #endif
  /// How long a preview reading stands after the last sample. A device that
  /// walks out of range stops sending without saying so, and a number still on
  /// screen a minute later is a reading nobody is taking.
  private static let previewStaleAfter: TimeInterval = 12
  /// 0-based, matching the server's zone indices.
  @Published private(set) var currentZone: Int?
  @Published private(set) var zoneMs: [Double] = Array(repeating: 0, count: HCCZones.zoneCount)
  /// Cumulative active kilocalories, only when a source reported them.
  @Published private(set) var kcal: Double?
  /// The watch's battery level (0–1) when it reports one. Kept here because the
  /// device pill that would render it belongs to another workstream; nothing in
  /// this feature draws it yet.
  @Published private(set) var watchBattery: Double?

  /// The last five minutes of readings — what the heart-rate card charts.
  @Published private(set) var recentSamples: [HCCHeartRateSample] = []

  /// Devices the Bluetooth scan has found, for the setup sheet's picker.
  @Published private(set) var bleDevices: [HCCLiveBLEDevice] = []
  @Published var chosenDeviceId: UUID?

  /// What the source is doing, in its own words. Never a number.
  @Published private(set) var sourceStatus: String?
  @Published var lastError: String?

  /// The row the server stored, once the session has been written.
  @Published private(set) var resultActivity: HCCActivityDetail?

  /// The zone cuts in force, and where they came from.
  @Published private(set) var zoneConfig: HCCZoneConfig = .fallback
  @Published private(set) var restingHr: Double?
  /// True once `/instance` has actually been read; until then the screen says
  /// the cuts are the published defaults rather than implying they are the
  /// instance's own.
  @Published private(set) var zoneConfigIsFromServer = false

  // ── Internals ──────────────────────────────────────────────────────────────

  /// Every reading, downsampled to at most 1 Hz, for the upload.
  private var uploadSamples: [HCCHeartRateSample] = []
  /// The route accepts at most 20 000 (`MAX_HR_SAMPLES`). At 1 Hz that is five
  /// and a half hours; past it the oldest are dropped rather than the request
  /// being refused.
  private static let uploadSampleCap = 20_000
  private static let chartWindow: TimeInterval = 300

  private var accumulator = HCCZoneAccumulator()
  private var source: HCCLiveHeartRateSource?
  /// The Bluetooth reader is kept between sessions so the picker's scan and the
  /// session that follows it use one `CBCentralManager` — a second one would
  /// re-prompt and re-discover.
  fileprivate var bleSource: HCCBLEHeartRateSource?
  private var drainTask: Task<Void, Never>?
  private var tickTask: Task<Void, Never>?
  private var pausedTotal: TimeInterval = 0
  private var pausedAt: Date?
  /// A reading older than this is not "current" any more — the screen falls
  /// back to "--" rather than holding a stale number under a live heading.
  private static let staleAfter: TimeInterval = 20
  private var lastSampleAt: Date?

  var isLive: Bool {
    switch phase {
    case .running, .paused, .ending, .done: true
    case .idle, .setup: false
    }
  }

  var isRunning: Bool { phase == .running }
  var isPaused: Bool { phase == .paused }

  /// The running strain, on the same curve the stored row will be on. Labelled
  /// "est." everywhere it is shown: it is the phone's arithmetic over the
  /// readings so far, not the number the server will store.
  var strainSoFar: Double { HCCZones.strain(zoneMs: zoneMs) }

  var zoneMinutes: [Double] { HCCZones.minutes(zoneMs: zoneMs) }

  /// The reading to show, or nil when the source has gone quiet.
  var displayBpm: Int? {
    guard let lastSampleAt, Date().timeIntervalSince(lastSampleAt) < Self.staleAfter else {
      return nil
    }
    return currentBpm
  }

  /// The name the stored row carries: the conditioning day's title when the
  /// session came from Training, otherwise the picked slug.
  var storedType: String {
    if let titleOverride, !titleOverride.trimmingCharacters(in: .whitespaces).isEmpty {
      return String(titleOverride.prefix(60))
    }
    return type
  }
}

// ── The slot ─────────────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// The live session's box. One per store, created on first use.
  var hccLive: HCCLiveState { hcc.slot { HCCLiveState() } }
}

// ── Session control ──────────────────────────────────────────────────────────

@MainActor
extension HealthDataStore {
  /// Open the setup sheet's state: adopt the instance's zone cuts and today's
  /// resting HR, and start looking for Bluetooth devices if that is the pick.
  func prepareHCCLive(titleOverride: String? = nil) {
    let state = hccLive
    state.beginSetup(titleOverride: titleOverride, drivingDevice: hccDrivingDevice())
    applyHCCLiveZoneConfig()
  }

  /// Re-read the zone cuts and the resting HR off whatever the store has.
  ///
  /// Both come from reads the store already does — `/instance` for the cuts,
  /// `/home` for the day's resting HR — so this never adds a request. A cut the
  /// server has not published yet falls back to the values it currently
  /// publishes, flagged as such.
  func applyHCCLiveZoneConfig() {
    let state = hccLive
    // `/devices` lands with the session reads, which on a cold launch finish
    // after this sheet is already on screen. Re-reading here is what lets the
    // pill pick the source; doing it only at setup left both silent.
    state.adoptDrivingDevice(hccDrivingDevice())
    let day = Self.hccDayKey(Date())
    state.adopt(
      zoneConfig: hcc.instance?.zones,
      restingHr: hcc.homeByDate[day]?.rhr
    )
  }

  /// Start recording. Throws nothing: a source that will not start puts its own
  /// sentence on `lastError` and the session does not begin.
  @discardableResult
  func startHCCLive() async -> Bool {
    applyHCCLiveZoneConfig()
    return await hccLive.start()
  }

  func pauseHCCLive() { hccLive.pause() }
  func resumeHCCLive() { hccLive.resume() }

  /// Stop recording, store the session, and hand back the server's row.
  ///
  /// No optimistic row: the strain on the stored activity is the server's, and
  /// inserting a placeholder would be showing a number nobody produced. The
  /// day's activity list is re-read afterwards so Home shows the new row.
  @discardableResult
  func finishHCCLive() async -> HCCActivityDetail? {
    let state = hccLive
    guard let draft = state.stopAndDraft() else {
      state.markDone(nil)
      return nil
    }
    do {
      let response = try await HCCSession.shared.client.createLiveActivity(draft)
      state.markDone(response.activity)
      await reloadHCCLiveDay(instant: response.activity.startAt)
      await refreshFromHCC(force: true)
      return response.activity
    } catch {
      if let apiError = error as? HCCAPIError, case .unauthorized = apiError {
        HCCSession.shared.handleUnauthorized()
      }
      state.markFailed(Self.hccLiveMessage(error))
      return nil
    }
  }

  /// Throw the session away without storing it. Used by the discard path on the
  /// end confirmation.
  func discardHCCLive() {
    hccLive.reset()
  }

  private func reloadHCCLiveDay(instant: String) async {
    let day = HCCTime.instant(instant).map(Self.hccDayKey) ?? Self.hccDayKey(Date())
    let isToday = day == Self.hccDayKey(Date())
    guard let response = try? await HCCSession.shared.client.activities(date: isToday ? nil : day)
    else { return }
    hccWillChange()
    hcc.activitiesByDate[response.date] = response.activities
  }

  private static func hccLiveMessage(_ error: Error) -> String {
    if let apiError = error as? HCCAPIError {
      return apiError.errorDescription ?? "Could not reach your Command Center."
    }
    return error.localizedDescription
  }
}

// ── The machine ──────────────────────────────────────────────────────────────

extension HCCLiveState {
  func beginSetup(titleOverride: String?, drivingDevice: HCCDevice? = nil) {
    guard !isLive else { return }
    self.titleOverride = titleOverride
    lastError = nil
    resultActivity = nil
    phase = .setup
    adoptDrivingDevice(drivingDevice)
    #if DEBUG
    if HCCDebugHeartRateSource.isRequested, sourceKind != .debug { sourceKind = .debug }
    #endif
    startPreview()
  }

  /// Point the live source at whatever the selected device can actually
  /// stream. Never overrides a pick the owner made themselves.
  func adoptDrivingDevice(_ device: HCCDevice?) {
    selectedDeviceLabel = device?.label
    let streaming = HCCLiveSourceKind.streaming(for: device?.source)
    selectedDeviceCanStream = device == nil || streaming != nil
    guard let streaming, !sourceKindChosenByOwner else { return }
    isDefaultingSourceKind = true
    sourceKind = streaming
    isDefaultingSourceKind = false
    // `/devices` usually lands AFTER the sheet is open, so this flip is what
    // decides the source most of the time. `beginSetup` has already run its own
    // scan check by then; without starting one here the screen sat waiting for
    // a device nothing was looking for.
    if phase == .setup { startPreview() }
  }

  func adopt(zoneConfig: HCCZoneConfig?, restingHr: Double?) {
    if let zoneConfig, zoneConfig.isUsable {
      self.zoneConfig = zoneConfig
      zoneConfigIsFromServer = true
    } else {
      self.zoneConfig = .fallback
      zoneConfigIsFromServer = false
    }
    self.restingHr = (restingHr ?? 0) > 0 ? restingHr : nil
  }

  /// Scan for Bluetooth heart-rate devices while the picker is open.
  /// Show a reading before anything is being recorded.
  ///
  /// Only for sources that can stream outside a session: a Bluetooth device is
  /// connectable any time, and the debug generator always runs. The watch
  /// cannot — it streams from a workout session the watch itself starts — so
  /// its preview stays a dash and the status line says what it is waiting for.
  func startPreview() {
    switch sourceKind {
    case .bluetooth:
      startBluetoothScan()
    #if DEBUG
    case .debug:
      let source = debugPreviewSource ?? HCCDebugHeartRateSource()
      debugPreviewSource = source
      previewFrom(source)
    #endif
    default:
      stopPreview()
    }
  }

  func stopPreview() {
    previewTask?.cancel()
    previewTask = nil
    previewSource = nil
    previewStaleTask?.cancel()
    previewStaleTask = nil
    previewBpm = nil
  }

  /// Drop the preview reading if the next sample does not arrive in time.
  private func armPreviewStaleness() {
    previewStaleTask?.cancel()
    previewStaleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.previewStaleAfter))
      guard !Task.isCancelled else { return }
      await MainActor.run { self?.previewBpm = nil }
    }
  }

  /// Drain a source into the preview only. Never touches the accumulator, so a
  /// reading taken while deciding cannot land in the session's zone time.
  private func previewFrom(_ source: HCCLiveHeartRateSource) {
    // Already draining this source: leave it alone. Restarting would cost the
    // readings, not refresh them (see `previewSource`).
    if previewSource === source, let task = previewTask, !task.isCancelled { return }
    previewTask?.cancel()
    previewSource = source
    previewTask = Task { [weak self] in
      try? await source.start()
      for await sample in source.samples {
        guard let self else { return }
        await MainActor.run {
          guard !self.isLive else { return }
          self.previewBpm = sample.bpm
          self.armPreviewStaleness()
        }
      }
    }
  }

  func startBluetoothScan() {
    let ble = bluetoothSource()
    ble.onDevicesChanged = { [weak self] devices in
      Task { @MainActor in self?.bleDevices = devices }
    }
    ble.onStatusChanged = { [weak self] status in
      Task { @MainActor in self?.sourceStatus = status }
    }
    ble.startScanning()
    // Scanning alone only lists devices. Connecting is what produces a reading,
    // and the reading is the whole point of the screen — so setup connects too,
    // and hands the samples to the preview rather than to the accumulator.
    previewFrom(ble)
  }

  func stopBluetoothScan() {
    bleSource?.stopScanning()
  }

  func start() async -> Bool {
    guard !isRunning else { return true }
    // One consumer of the stream at a time: the preview must let go before the
    // session's own drain takes over, or readings alternate between them.
    previewTask?.cancel()
    previewTask = nil
    previewSource = nil
    previewStaleTask?.cancel()
    previewStaleTask = nil
    previewBpm = nil
    lastError = nil
    let source = makeSource()
    self.source = source
    do {
      try await source.start()
    } catch {
      lastError = error.localizedDescription
      self.source = nil
      return false
    }

    startedAt = Date()
    elapsed = 0
    pausedTotal = 0
    pausedAt = nil
    accumulator = HCCZoneAccumulator()
    zoneMs = accumulator.zoneMs
    recentSamples = []
    uploadSamples = []
    currentBpm = nil
    currentZone = nil
    kcal = nil
    lastSampleAt = nil
    phase = .running

    drain(source)
    startTicking()
    return true
  }

  func pause() {
    guard phase == .running else { return }
    pausedAt = Date()
    accumulator.pause()
    phase = .paused
  }

  func resume() {
    guard phase == .paused else { return }
    if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
    pausedAt = nil
    phase = .running
  }

  /// Stop the source and build the upload body, or nil when there is nothing
  /// worth storing (no start, or a zero-length window the route would refuse).
  func stopAndDraft() -> HCCLiveActivityCreate? {
    let end = Date()
    tickTask?.cancel()
    tickTask = nil
    drainTask?.cancel()
    drainTask = nil
    source?.stop()
    source = nil
    if phase == .paused, let pausedAt { pausedTotal += end.timeIntervalSince(pausedAt) }
    pausedAt = nil
    phase = .ending

    guard let startedAt, end > startedAt else { return nil }

    let bpms = uploadSamples.map(\.bpm)
    let avg = bpms.isEmpty ? nil : Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
    let peak = bpms.max()

    return HCCLiveActivityCreate(
      type: storedType,
      startAt: HCCTime.isoInstant(startedAt),
      endAt: HCCTime.isoInstant(end),
      // The route requires an effort; `zoneMs` outranks it, so this is the
      // nominal value and not a claim about how hard the session felt.
      effort: 5,
      notes: nil,
      trainingSessionId: nil,
      // Only inside the range the route accepts — a sensor fault must not turn
      // the whole write into a 400.
      avgHr: avg.flatMap { (30...250).contains($0) ? $0 : nil },
      maxHr: peak.flatMap { (30...250).contains($0) ? $0 : nil },
      kcal: kcal.map { max(0, $0) },
      zoneMs: HCCZones.uploadZoneMs(zoneMs),
      hrSamples: uploadSamples.isEmpty
        ? nil
        : uploadSamples.map { HCCLiveHrSample(t: HCCTime.isoInstant($0.at), bpm: $0.bpm) }
    )
  }

  func markDone(_ activity: HCCActivityDetail?) {
    resultActivity = activity
    phase = .done
  }

  func markFailed(_ message: String) {
    lastError = message
    // Back to paused, not done: the session's readings are still in hand and
    // "End activity" can be tried again. A failed write must never look like a
    // stored one.
    phase = .paused
  }

  /// Back to nothing. Called when the screen closes, and by the discard path.
  func reset() {
    tickTask?.cancel()
    tickTask = nil
    drainTask?.cancel()
    drainTask = nil
    source?.stop()
    source = nil
    bleSource?.stopScanning()
    bleSource = nil
    phase = .idle
    startedAt = nil
    elapsed = 0
    pausedTotal = 0
    pausedAt = nil
    currentBpm = nil
    currentZone = nil
    lastSampleAt = nil
    kcal = nil
    watchBattery = nil
    accumulator = HCCZoneAccumulator()
    zoneMs = accumulator.zoneMs
    recentSamples = []
    uploadSamples = []
    resultActivity = nil
    sourceStatus = nil
    titleOverride = nil
  }

  // ── Sources ────────────────────────────────────────────────────────────────

  private func makeSource() -> HCCLiveHeartRateSource {
    switch sourceKind {
    case .watch:
      let watch = HCCWatchMirrorSource.shared
      watch.onStatusChanged = { [weak self] status in
        Task { @MainActor in self?.sourceStatus = status }
      }
      watch.onBatteryChanged = { [weak self] level in
        Task { @MainActor in self?.watchBattery = level }
      }
      return watch
    case .bluetooth:
      let ble = bluetoothSource()
      ble.preferredDeviceId = chosenDeviceId
      return ble
    #if DEBUG
    case .debug:
      return HCCDebugHeartRateSource()
    #endif
    }
  }

  private func bluetoothSource() -> HCCBLEHeartRateSource {
    if let bleSource { return bleSource }
    let made = HCCBLEHeartRateSource()
    bleSource = made
    return made
  }

  // ── The stream ─────────────────────────────────────────────────────────────

  private func drain(_ source: HCCLiveHeartRateSource) {
    drainTask = Task { [weak self] in
      for await sample in source.samples {
        guard let self else { return }
        await MainActor.run { self.ingest(sample) }
      }
    }
  }

  /// One reading: the zone it is in, the interval it closes, and the two lists.
  func ingest(_ sample: HCCHeartRateSample) {
    guard isLive, phase != .done else { return }
    let zone = HCCZones.zoneIndex(
      bpm: Double(sample.bpm),
      config: zoneConfig,
      restingHr: restingHr
    )
    accumulator.add(at: sample.at, zone: zone, isPaused: phase != .running)
    zoneMs = accumulator.zoneMs
    currentBpm = sample.bpm
    currentZone = zone
    lastSampleAt = sample.at
    if let reported = sample.activeKcal { kcal = reported }

    recentSamples.append(sample)
    let cutoff = sample.at.addingTimeInterval(-Self.chartWindow)
    if let firstKept = recentSamples.firstIndex(where: { $0.at >= cutoff }), firstKept > 0 {
      recentSamples.removeFirst(firstKept)
    }

    // The upload series is capped at 1 Hz: sources may report faster, and the
    // route caps the array at 20 000 points.
    if let last = uploadSamples.last, sample.at.timeIntervalSince(last.at) < 1 { return }
    uploadSamples.append(sample)
    if uploadSamples.count > Self.uploadSampleCap {
      uploadSamples.removeFirst(uploadSamples.count - Self.uploadSampleCap)
    }
  }

  private func startTicking() {
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard let self else { return }
        await MainActor.run { self.tick() }
      }
    }
  }

  /// The elapsed clock. Paused time is subtracted rather than the clock being
  /// stopped, so a pause that spans a suspension is still excluded.
  private func tick() {
    guard let startedAt, isLive else { return }
    let now = Date()
    var paused = pausedTotal
    if let pausedAt { paused += now.timeIntervalSince(pausedAt) }
    elapsed = max(0, now.timeIntervalSince(startedAt) - paused)
    // Nudge the view when a reading goes stale, so "--" appears on time.
    objectWillChange.send()
  }
}
