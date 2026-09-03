import SwiftUI

// Apple Watch upload — the More-tab row and the sheet behind it (plan §4.6).
//
// The sheet's job is to make one thing checkable: whether the Watch's readings
// are actually reaching the Command Center. So every line on it is a fact the
// uploader holds — what was asked of Health, when the last upload landed, what
// the server counted, what is still queued — and nothing on it is a promise.
//
// The copy has one hard rule of its own: HealthKit never tells an app whether a
// READ was granted, so this screen says what was REQUESTED and explains how to
// tell the difference in Health itself. Printing "Authorized" would be a claim
// the app cannot make.

// ── Row ──────────────────────────────────────────────────────────────────────

/// The "Apple Watch upload" row for the More screen's Devices & data card.
struct HCCWatchUploadRow: View {
  @ObservedObject var uploader: HCCHealthKitUploader
  var showsDivider: Bool = true
  let action: () -> Void

  /// `uploader` has no default on purpose: a default argument is evaluated
  /// outside the main actor, and `HCCHealthKitUploader.shared` is main-actor
  /// isolated. Callers pass `HCCHealthKitUploader.shared` from a view body.
  init(
    uploader: HCCHealthKitUploader,
    showsDivider: Bool = true,
    action: @escaping () -> Void
  ) {
    self.uploader = uploader
    self.showsDivider = showsDivider
    self.action = action
  }

  var body: some View {
    HCCMenuRow(
      title: "Apple Watch upload",
      detail: uploader.state.rowStatus,
      showsDivider: showsDivider,
      action: action
    )
  }
}

// ── Sheet ────────────────────────────────────────────────────────────────────

struct HCCWatchUploadSheet: View {
  @ObservedObject var uploader: HCCHealthKitUploader

  /// See the note on `HCCWatchUploadRow.init` for why there is no default.
  init(uploader: HCCHealthKitUploader) {
    self.uploader = uploader
  }

  private var state: HCCHealthKitUploadState { uploader.state }

  var body: some View {
    HCCScreen {
      HCCDetailHeader(
        title: "Apple Watch upload",
        subtitle: "Send Watch readings to your Command Center"
      )

      switchCard

      if let error = state.lastError {
        HCCErrorNote(error, title: "Last attempt failed")
      }

      statusCard

      HCCButtonRow(
        primary: HCCButtonSpec(
          title: state.isWorking ? "Syncing..." : "Sync now",
          isEnabled: state.enabled && !state.isWorking
        ) {
          Task { await uploader.syncNow() }
        }
      )

      if state.enabled {
        streamsCard
      }

      HCCFootnote(
        "Only readings Apple Health recorded from an Apple Watch are uploaded. Readings another app wrote into Health — a Fitbit mirrored in by Google Health, for example — and values typed in by hand are left where they are, so the two wrists are never scored as one."
      )

      HCCFootnote(
        "Health does not tell an app whether a read was allowed, so this screen says what was requested. If uploads stay empty, check Health → Sharing → Apps."
      )

      if let note = state.backgroundNote {
        HCCFootnote(note)
      }
    }
    .task { await uploader.refreshAuthorization() }
  }

  // ── Cards ──────────────────────────────────────────────────────────────────

  private var switchCard: some View {
    VStack(spacing: 0) {
      HCCToggleRow(
        title: "Upload Watch readings",
        isOn: Binding(
          get: { state.enabled },
          set: { newValue in Task { await uploader.setEnabled(newValue) } }
        ),
        showsDivider: false
      )
    }
    .hccCard()
    .disabled(state.isWorking)
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Status")
      VStack(spacing: 0) {
        HCCFieldRow(title: "Health access", value: state.authorization.label)
        HCCFieldRow(title: "Last upload", value: Self.timestamp(state.lastUploadAt))
        HCCFieldRow(title: "Readings written", value: Self.count(state.lastResult?.written))
        HCCFieldRow(title: "Already on file", value: Self.count(state.lastResult?.skipped))
        HCCFieldRow(title: "Workouts and nights", value: Self.count(state.lastResult?.activities))
        HCCFieldRow(
          title: "Waiting to upload",
          value: "\(state.pendingBatches)",
          showsDivider: false
        )
      }
    }
    .hccCard()
  }

  private var streamsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Streams")
      VStack(spacing: 0) {
        let streams = state.streams
        ForEach(Array(streams.enumerated()), id: \.element.id) { index, stream in
          HCCFieldRow(
            title: stream.label,
            value: stream.hasAnchor ? "reading from last sync" : "first sync reads 30 days",
            showsDivider: index < streams.count - 1
          )
        }
      }
    }
    .hccCard()
  }

  // ── Formatting ─────────────────────────────────────────────────────────────

  /// A value the app does not have is "--", never a zero standing in for it.
  private static func count(_ value: Int?) -> String {
    guard let value else { return "--" }
    return "\(value)"
  }

  private static func timestamp(_ date: Date?) -> String {
    guard let date else { return "--" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = HCCInstanceZone.current
    formatter.dateFormat = "d MMM · HH:mm"
    return formatter.string(from: date)
  }
}
