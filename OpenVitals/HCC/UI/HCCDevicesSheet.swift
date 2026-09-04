import SwiftUI

// `S.devices` from the approved mockup: which device the rings and vitals are
// read from today.
//
// This is a TIEBREAK, not a filter — the server's own word for it. Every
// connected device keeps syncing; the radio only fronts one source when two
// report the same stream, and clearing it restores the server's standing
// priority order. The copy on the screen has to keep that distinction, because
// a user who reads it as "turn the other one off" will draw the wrong
// conclusion from a flat line later.

struct HCCDevicesSheet: View {
  @ObservedObject var store: HealthDataStore
  @Environment(\.dismiss) private var dismiss

  @State private var isSaving = false
  @State private var errorText: String?

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "Devices", subtitle: "Which device drives the rings today")

      deviceCard

      if let errorText {
        HCCEmptyNote(errorText).hccCard()
      }

      HCCFootnote("During co-wear all devices keep syncing; this only chooses which one the rings and vitals display. Once a device stops reporting, the server falls back automatically.")
        .padding(.bottom, 10)

      batteryCard
    }
  }

  // ── Rows ───────────────────────────────────────────────────────────────────

  private var devices: [HCCDevice] { store.hcc.devices }

  /// The row the radio marks: the explicit override if the account has one,
  /// otherwise whichever device the server currently believes.
  ///
  /// DECISION (Chris, this phase): the sheet lists ONLY the devices the server
  /// reports, exactly as in the mockup. There is no "Automatic" row and no
  /// other control for clearing the override — `setPreferredSource(nil)` stays
  /// available on the store because the API supports it, but nothing on this
  /// screen sends it. Do not re-add one.
  private var selectedSource: String? {
    store.hcc.preferredSource ?? store.hccDrivingDevice()?.source
  }

  private var deviceCard: some View {
    VStack(spacing: 0) {
      if devices.isEmpty {
        HCCEmptyNote("No connected devices on this account yet.")
      } else {
        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
          deviceRow(device, showsDivider: index < devices.count - 1)
            .id(index)
        }
      }
    }
    .hccCard()
    .disabled(isSaving)
  }

  private func deviceRow(_ device: HCCDevice, showsDivider: Bool) -> some View {
    row(
      glyph: Self.glyph(for: device.source),
      name: Self.name(for: device),
      status: status(for: device),
      isSelected: selectedSource == device.source,
      showsDivider: showsDivider
    ) {
      select(device.source)
    }
  }

  private func row(
    glyph: String,
    name: String,
    status: String,
    isSelected: Bool,
    showsDivider: Bool,
    action: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(glyph)
          .font(.system(size: 16))
          .foregroundStyle(HCCTheme.Color.text)
          .frame(width: 38, height: 38)
          .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(HCCTheme.Color.card2)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .strokeBorder(HCCTheme.Color.line, lineWidth: 1)
          )

        VStack(alignment: .leading, spacing: 3) {
          Text(name)
            .font(HCCTheme.Font.body(size: 13.5, weight: .semibold))
            .foregroundStyle(HCCTheme.Color.text)
          Text(status)
            .font(HCCTheme.Font.data(size: 11))
            .foregroundStyle(HCCTheme.Color.muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        ZStack {
          Circle()
            .strokeBorder(isSelected ? HCCTheme.Color.accent : HCCTheme.Color.muted, lineWidth: 1.5)
            .frame(width: 20, height: 20)
          if isSelected {
            Circle().fill(HCCTheme.Color.accent).frame(width: 10, height: 10)
          }
        }
      }
      .padding(.vertical, 11)
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      if showsDivider { HCCDivider() }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  // ── Battery availability ───────────────────────────────────────────────────

  private var batteryCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Battery availability")
      HCCKeyValueGrid(rows: [
        HCCKeyValue("Fitbit", "Google Health API"),
        HCCKeyValue("WHOOP", "not exposed"),
        HCCKeyValue("Apple Watch", "needs Watch app"),
      ])
    }
    .hccCard()
  }

  // ── Composition ────────────────────────────────────────────────────────────

  /// "Battery 75% · Synced 07:12 · drives rings", with each clause present only
  /// when the server actually sent the thing behind it.
  private func status(for device: HCCDevice) -> String {
    var parts: [String] = []
    if let level = device.battery?.level {
      parts.append("Battery \(Int(level.rounded()))%")
    }
    if let synced = device.lastSyncAt,
       let clock = HCCWallClock.clock(iso: synced, timezone: store.hcc.instance?.timezone) {
      parts.append("Synced \(clock)")
    } else if device.lastSyncAt == nil {
      // Push-only sources have no pull to time — say so rather than leaving a
      // gap that reads as "never synced".
      parts.append("Pushes to your server")
    }
    switch device.status {
    case "NEEDS_REAUTH": parts.append("needs reconnecting")
    case "REVOKED": parts.append("access revoked")
    default: break
    }
    if device.drives { parts.append("drives rings") }
    return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
  }

  /// The band's row is named by `HCCCopy`, which owns device naming; every
  /// other source keeps the server's own label (the Fitbit row carries the
  /// real hardware name Google reports).
  private static func name(for device: HCCDevice) -> String {
    device.source.uppercased() == "WHOOP" ? HCCCopy.sourceLabel(device.source) : device.label
  }

  private static func glyph(for source: String) -> String {
    switch source.uppercased() {
    case "FITBIT": "◐"
    case "WHOOP": "◎"
    case "APPLE_HEALTH": "◔"
    case "WITHINGS": "◍"
    default: "◌"
    }
  }

  /// Front one device. Tapping the row that is already selected is a no-op —
  /// there is no "unset" gesture on this screen (see `selectedSource`).
  private func select(_ source: String) {
    guard !isSaving, source != selectedSource else { return }
    isSaving = true
    errorText = nil
    Task {
      if await store.setPreferredSource(source) {
        isSaving = false
        return
      }
      errorText = store.hcc.lastError ?? "That did not save. The device choice is unchanged."
      isSaving = false
    }
  }
}
