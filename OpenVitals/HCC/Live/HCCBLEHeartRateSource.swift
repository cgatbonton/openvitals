import Foundation
import CoreBluetooth

// HCC: a live heart-rate stream from any device broadcasting the standard
// Bluetooth Heart Rate service (0x180D / 0x2A37).
//
// Why this does NOT reuse `OpenVitalsBLEClient`: that client is the fork's
// band pipeline and is brand-gated on purpose. It scans for vendor services,
// checks identity evidence, and DISCONNECTS a peripheral that has no vendor
// service even when that peripheral is also advertising 0x180D
// (`OpenVitalsBLEClient+PeripheralDelegate.swift:20-43`,
// `rejectNonWhoopPeripheral`). A chest strap is exactly such a peripheral, so
// routing this through that client would mean loosening its identity checks —
// a change to upstream code, for a feature upstream does not have.
//
// This class is modelled on `OpenVitalsRRReferenceCapture`, the fork's own
// standalone 0x180D reader: its own `CBCentralManager`, its own scan, its own
// parse of the Heart Rate Measurement layout. That file is left untouched;
// this is a separate reader with a different job (stream bpm for a workout
// rather than store RR intervals for validation).
//
// Copy rule: this file names no manufacturer. A device is a "Bluetooth
// heart-rate device" and is listed by whatever name it advertises.

/// One peripheral the scan found. Shown in the setup sheet's picker.
struct HCCLiveBLEDevice: Identifiable, Equatable {
  let id: UUID
  let name: String
  let rssi: Int
}

/// The stream half of a standard Bluetooth heart-rate connection.
///
/// `@unchecked Sendable` for the same reason the fork's other CoreBluetooth
/// classes are: `CBCentralManager` calls back on its own queue, and every
/// mutable field here is touched only from that queue or from the main actor
/// before scanning starts. The published state is republished onto the main
/// actor by the state box that owns this object, never read across queues here.
final class HCCBLEHeartRateSource: NSObject, HCCLiveHeartRateSource, @unchecked Sendable {
  /// The standard service and the measurement characteristic on it. Same two
  /// UUIDs the fork already names in two places; this is a third reader of the
  /// same public spec, not a new protocol.
  private static let heartRateService = CBUUID(string: "180D")
  private static let heartRateMeasurement = CBUUID(string: "2A37")

  /// The device chosen last time, so a second session does not re-pick from a
  /// list. Stored as the peripheral's identifier, which is stable per install.
  private static let rememberedKey = "hcc.live.ble.device"

  static var rememberedDeviceId: UUID? {
    guard let raw = UserDefaults.standard.string(forKey: rememberedKey) else { return nil }
    return UUID(uuidString: raw)
  }

  static func remember(_ id: UUID?) {
    if let id {
      UserDefaults.standard.set(id.uuidString, forKey: rememberedKey)
    } else {
      UserDefaults.standard.removeObject(forKey: rememberedKey)
    }
  }

  /// What is connected, in the device's OWN advertised name.
  ///
  /// This reader speaks the standard heart-rate profile, so it will connect to
  /// a band, a chest strap or anything else that broadcasts it — "Bluetooth
  /// heart-rate device" is the honest name for the option, but a poor name for
  /// the thing on the wrist once one is actually connected. The name comes off
  /// the air from the peripheral, never from a table of brands here, which is
  /// also what the status lines have always shown.
  var label: String {
    connected.map(Self.displayName) ?? "Bluetooth heart-rate device"
  }

  /// Discovered peripherals, newest scan first. Read on the main actor by the
  /// setup sheet through the callback below rather than by reaching in here.
  private(set) var devices: [HCCLiveBLEDevice] = []

  /// Called whenever the discovered list or the connection state changes.
  /// The state box hops this onto the main actor.
  var onDevicesChanged: (@Sendable ([HCCLiveBLEDevice]) -> Void)?
  var onStatusChanged: (@Sendable (String) -> Void)?

  /// The device to connect to when `start()` is called. Nil means "the
  /// remembered one, else the strongest signal found".
  var preferredDeviceId: UUID?

  private var central: CBCentralManager?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var connected: CBPeripheral?
  /// One stream per consumer — see `HCCSampleFanout`. Switching the source
  /// away and back reads `samples` again, and a single stored stream would be
  /// spent by then.
  private let fanout = HCCSampleFanout()
  private var wantsConnection = false
  /// The energy field is cumulative since the sensor last reset, so the first
  /// value read becomes the session's zero.
  private var energyBaselineKJ: Double?

  var samples: AsyncStream<HCCHeartRateSample> { fanout.stream }

  // ── Scanning ───────────────────────────────────────────────────────────────

  /// Look for heart-rate devices. Safe to call before `start()`; the picker in
  /// the setup sheet runs this while the sheet is open.
  ///
  /// Scanning is scoped to the heart-rate service, so this never sees — and
  /// never lists — devices that are not offering heart rate.
  func startScanning() {
    ensureCentral()
    guard central?.state == .poweredOn else { return }
    devices = []
    publishDevices()
    central?.scanForPeripherals(
      withServices: [Self.heartRateService],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
    onStatusChanged?("Looking for heart-rate devices...")
  }

  func stopScanning() {
    central?.stopScan()
  }

  // ── The source contract ────────────────────────────────────────────────────

  func start() async throws {
    wantsConnection = true
    ensureCentral()
    guard let central else { throw HCCLiveSourceError.bluetoothUnavailable }
    switch central.state {
    case .poweredOn:
      connectToChosenDevice()
    case .unauthorized:
      throw HCCLiveSourceError.bluetoothDenied
    case .poweredOff:
      throw HCCLiveSourceError.bluetoothOff
    case .unsupported:
      throw HCCLiveSourceError.bluetoothUnavailable
    default:
      // Still resolving; `centralManagerDidUpdateState` finishes the job.
      onStatusChanged?("Waiting for Bluetooth...")
    }
  }

  func stop() {
    wantsConnection = false
    central?.stopScan()
    if let connected {
      central?.cancelPeripheralConnection(connected)
    }
    connected = nil
    fanout.finish()
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private func ensureCentral() {
    guard central == nil else { return }
    // No restore identifier: this reader lives for one workout and must not
    // take over state restoration from `OpenVitalsBLEClient`, which owns it.
    central = CBCentralManager(delegate: self, queue: nil, options: [:])
  }

  private func connectToChosenDevice() {
    let wanted = preferredDeviceId ?? Self.rememberedDeviceId
    if let wanted, let peripheral = peripherals[wanted] {
      connect(peripheral)
      return
    }
    if let wanted, let known = central?.retrievePeripherals(withIdentifiers: [wanted]).first {
      peripherals[known.identifier] = known
      connect(known)
      return
    }
    // Nothing chosen or nothing found yet: keep scanning and take the strongest
    // heart-rate device that appears.
    startScanning()
  }

  private func connect(_ peripheral: CBPeripheral) {
    central?.stopScan()
    connected = peripheral
    peripheral.delegate = self
    Self.remember(peripheral.identifier)
    onStatusChanged?("Connecting to \(Self.displayName(peripheral))...")
    central?.connect(peripheral, options: nil)
  }

  private func publishDevices() {
    let snapshot = devices
    onDevicesChanged?(snapshot)
  }

  private static func displayName(_ peripheral: CBPeripheral) -> String {
    let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (name?.isEmpty == false ? name : nil) ?? "Heart-rate device"
  }

  /// The standard Heart Rate Measurement layout (Bluetooth SIG):
  /// flag byte, then 8- or 16-bit bpm, then optional energy expended (kJ) and
  /// optional RR intervals. RR intervals are read past but not used — this is a
  /// workout stream, not the RR validation capture that already exists.
  static func parse(_ data: Data) -> (bpm: Int, energyKJ: Double?)? {
    let bytes = [UInt8](data)
    guard let flags = bytes.first else { return nil }
    var index = 1
    let bpm: Int
    if flags & 0x01 == 0x01 {
      guard index + 1 < bytes.count else { return nil }
      bpm = Int(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
      index += 2
    } else {
      guard index < bytes.count else { return nil }
      bpm = Int(bytes[index])
      index += 1
    }
    guard bpm > 0 else { return nil }

    var energyKJ: Double?
    if flags & 0x08 == 0x08, index + 1 < bytes.count {
      energyKJ = Double(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
      index += 2
    }
    return (bpm, energyKJ)
  }
}

// ── Central delegate ─────────────────────────────────────────────────────────

extension HCCBLEHeartRateSource: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      if wantsConnection { connectToChosenDevice() } else { startScanning() }
    case .poweredOff:
      onStatusChanged?("Bluetooth is off.")
    case .unauthorized:
      onStatusChanged?("Bluetooth access has not been granted.")
    case .unsupported:
      onStatusChanged?("This device has no Bluetooth heart-rate support.")
    default:
      onStatusChanged?("Bluetooth is starting up...")
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    peripherals[peripheral.identifier] = peripheral
    let entry = HCCLiveBLEDevice(
      id: peripheral.identifier,
      name: Self.displayName(peripheral),
      rssi: RSSI.intValue
    )
    if let existing = devices.firstIndex(where: { $0.id == entry.id }) {
      devices[existing] = entry
    } else {
      devices.append(entry)
    }
    devices.sort { $0.rssi > $1.rssi }
    publishDevices()

    // A session that is already asking for a connection takes the first device
    // that matches what it wanted, or the strongest one if it wanted none.
    guard wantsConnection, connected == nil else { return }
    let wanted = preferredDeviceId ?? Self.rememberedDeviceId
    if wanted == nil || wanted == peripheral.identifier {
      connect(peripheral)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    onStatusChanged?("Connected to \(Self.displayName(peripheral)).")
    peripheral.discoverServices([Self.heartRateService])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    connected = nil
    onStatusChanged?("Could not connect to \(Self.displayName(peripheral)).")
    if wantsConnection { startScanning() }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    connected = nil
    guard wantsConnection else { return }
    // A strap that drops mid-workout is a dropout, not the end of the workout:
    // the session keeps running with no current reading (the screen shows "--")
    // and this reconnects. The zone accumulator credits at most two minutes of
    // the gap, so a long dropout cannot invent zone time.
    onStatusChanged?("Heart-rate device disconnected. Looking for it again...")
    connectToChosenDevice()
  }
}

// ── Peripheral delegate ──────────────────────────────────────────────────────

extension HCCBLEHeartRateSource: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil,
          let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService })
    else {
      onStatusChanged?("That device is not offering heart rate.")
      return
    }
    peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil,
          let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.heartRateMeasurement })
    else {
      onStatusChanged?("That device is not broadcasting heart rate.")
      return
    }
    peripheral.setNotifyValue(true, for: characteristic)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil, characteristic.isNotifying else { return }
    onStatusChanged?("Receiving heart rate.")
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard error == nil,
          characteristic.uuid == Self.heartRateMeasurement,
          let value = characteristic.value,
          let parsed = Self.parse(value)
    else { return }

    var kcal: Double?
    if let energyKJ = parsed.energyKJ {
      // Cumulative since the sensor's own reset, so the first reading of a
      // session is its zero. kJ → kcal is the same 4.184 the server uses.
      let baseline = energyBaselineKJ ?? energyKJ
      energyBaselineKJ = min(baseline, energyKJ)
      kcal = max(0, energyKJ - (energyBaselineKJ ?? energyKJ)) / 4.184
    }
    fanout.yield(HCCHeartRateSample(at: Date(), bpm: parsed.bpm, activeKcal: kcal))
  }
}

// ── Errors ───────────────────────────────────────────────────────────────────

/// What a source can refuse to start with, in words the screen can show.
enum HCCLiveSourceError: LocalizedError {
  case bluetoothOff
  case bluetoothDenied
  case bluetoothUnavailable
  case watchUnavailable
  case watchNotMirroring

  var errorDescription: String? {
    switch self {
    case .bluetoothOff:
      "Bluetooth is off. Turn it on to use a heart-rate device."
    case .bluetoothDenied:
      "This app has not been allowed to use Bluetooth."
    case .bluetoothUnavailable:
      "Bluetooth is not available on this device."
    case .watchUnavailable:
      "Live heart rate from the watch needs Health access."
    case .watchNotMirroring:
      "Start the workout on the watch; this screen follows it."
    }
  }
}
