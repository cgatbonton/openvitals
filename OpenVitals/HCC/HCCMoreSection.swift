import SwiftUI

// `S.more` from the approved mockup: the whole More tab in cloud mode.
//
// The bridge path keeps its inset-grouped `List` — that screen is upstream's
// and stays upstream's. Cloud mode gets the Command design's glass cards and
// menu rows instead, because half of its rows are not settings at all: they are
// statements about what this phase does and does not do yet, and a system
// switch beside one of those would promise a behaviour that has not shipped.
//
// Nothing on this screen fakes a control. Every Phase 4 row is a muted line
// saying when it arrives; the rows that DO something open a sheet or navigate.

struct HCCMoreScreen: View {
  @ObservedObject var healthStore: HealthDataStore
  @ObservedObject private var session = HCCSession.shared

  @EnvironmentObject private var model: OpenVitalsAppModel
  @EnvironmentObject private var router: AppRouter
  @AppStorage(OnboardingStorage.onboardingComplete) private var onboardingComplete = false
  @AppStorage(OnboardingStorage.onboardingRedoRequested) private var onboardingRedoRequested = false

  @State private var sheet: HCCMoreSheet?
  @State private var showSignOutConfirmation = false
  @State private var isSigningOut = false
  @State private var didApplyDebugScreen = false

  var body: some View {
    HCCScreen {
      HCCDetailHeader(title: "More", showsBack: false)
      accountCard
      devicesCard
      notificationsCard
      appCard
    }
    .sheet(item: $sheet) { destination in
      sheetContent(destination)
    }
    .confirmationDialog(
      "Sign out of your Command Center?",
      isPresented: $showSignOutConfirmation,
      titleVisibility: .visible
    ) {
      Button("Sign out", role: .destructive, action: signOut)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This revokes the session on the server and deletes it from this iPhone. You will be taken back to setup to choose a source again.")
    }
    .onAppear(perform: applyDebugScreenIfRequested)
    // More reads the account-scoped payloads (devices, tiles, alarm) that the
    // refresh loop fetches once per session. Home normally triggers that, but
    // this screen must not depend on Home having been visited — a restored tab
    // or a deep link can land here first, and "None yet" would then be a claim
    // about the account rather than about what has been read.
    .task {
      guard !healthStore.hcc.hasSessionReads else { return }
      await healthStore.refreshFromHCC(force: true)
    }
  }

  // ── Cards ──────────────────────────────────────────────────────────────────

  private var accountCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Account")
      VStack(spacing: 0) {
        HCCMenuRow(title: "Command center", detail: session.baseURL.host ?? session.baseURL.absoluteString)
        HCCMenuRow(title: "Signed in as", detail: signedInAs)
        // There is no created-at on the token this app holds — the server does
        // not send one with the session — so the row says what IS known.
        HCCMenuRow(title: "Mobile token", detail: session.isSignedIn ? "Active" : "Not signed in", showsDivider: false)
        // The card ends here. No "Refresh now" row: this screen carries only
        // what `S.more` shows, and Home's pull-to-refresh is the manual reread.
      }
    }
    .hccCard()
  }

  private var devicesCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Devices & data")
      VStack(spacing: 0) {
        HCCMenuRow(title: "Devices", detail: deviceCount) { sheet = .devices }
        HCCMenuRow(title: "Apple Watch upload", detail: "Not set up yet")
        HCCMenuRow(title: "Log a reading", detail: "Weight, BP, glucose") {
          sheet = .comingSoon("Logging a reading")
        }
        HCCMenuRow(title: "Dashboard tiles", detail: tileCount, showsDivider: false) { sheet = .customize }
      }
    }
    .hccCard()
  }

  private var notificationsCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("Notifications")
      VStack(spacing: 0) {
        HCCMenuRow(title: "Morning recovery", detail: Self.phase4)
        HCCMenuRow(title: "Insight alerts", detail: Self.phase4)
        HCCMenuRow(title: "Alarm", detail: alarmSummary) { sheet = .alarm }
        HCCMenuRow(title: "Strain Live Activity", detail: Self.phase4, showsDivider: false)
      }
    }
    .hccCard()
  }

  private var appCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HCCLabel("App")
      VStack(spacing: 0) {
        // A plain row that pushes, rather than a `NavigationLink` wrapping one:
        // `HCCMenuRow` owns its own tap, and nesting the two would give the row
        // two hit targets that disagree about what a tap does.
        HCCMenuRow(title: "Appearance", detail: "System") {
          router.morePath.append(.appearance)
        }
        HCCMenuRow(title: "Widgets", detail: "Later")
        HCCMenuRow(title: "Privacy & data flow") { sheet = .consent }
        HCCMenuRow(title: "Sign out", detail: isSigningOut ? "Signing out…" : nil, showsDivider: false) {
          guard !isSigningOut else { return }
          showSignOutConfirmation = true
        }
      }
    }
    .hccCard()
  }

  // ── Values ─────────────────────────────────────────────────────────────────

  private static let phase4 = "Arrives with push (Phase 4)"

  private var signedInAs: String {
    session.account?.displayName.nilIfBlank
      ?? session.account?.email.nilIfBlank
      ?? healthStore.hcc.instance?.displayName.nilIfBlank
      ?? (session.isSignedIn ? "Signed in" : "Not signed in")
  }

  private var deviceCount: String {
    let count = healthStore.hcc.devices.count
    return count == 0 ? "None yet" : "\(count) connected"
  }

  private var tileCount: String {
    guard let dashboard = healthStore.hcc.dashboard else { return "Not loaded" }
    return "\(dashboard.tiles.count) shown"
  }

  /// "7:30 a.m. · exact", from the row the server holds. `--` when it has not
  /// been read yet: this screen never guesses a wake time.
  private var alarmSummary: String {
    guard let alarm = healthStore.hcc.alarm else { return "--" }
    let split = HCCWallClock.split(alarm.time)
    let clock = split.map { "\($0.time) \($0.suffix)" } ?? alarm.time
    let mode = alarm.mode == "exact" ? "exact" : "by sleep goal"
    return alarm.on ? "\(clock) · \(mode)" : "Off"
  }

  // ── Sheets ─────────────────────────────────────────────────────────────────

  @ViewBuilder
  private func sheetContent(_ destination: HCCMoreSheet) -> some View {
    switch destination {
    case .devices:
      HCCDevicesSheet(store: healthStore)
    case .customize:
      HCCCustomizeSheet(store: healthStore)
    case .alarm:
      HCCAlarmSheet(store: healthStore)
    case .addActivity:
      HCCAddActivitySheet(store: healthStore)
    case let .activity(id):
      HCCActivityDetailView(store: healthStore, activityId: id)
    case .consent:
      HCCConsentSheet { sheet = nil }
    case let .comingSoon(feature):
      HCCComingSoonSheet(feature: feature)
    }
  }

  // ── Sign out ───────────────────────────────────────────────────────────────

  /// Sign out, then hand the user back to the first onboarding step.
  ///
  /// Signing out on its own is not a decision to go back to reading a band over
  /// Bluetooth — redoing setup is what asks that question, so the redo request
  /// is what actually moves the app. Same three writes the Debug screen's
  /// "Re-do Onboarding" makes, so both routes leave identical state.
  private func signOut() {
    guard !isSigningOut else { return }
    isSigningOut = true
    model.recordUIAction("ui.hcc.sign_out")

    Task {
      await session.signOut()
      isSigningOut = false
      OnboardingProfilePersistence.requestRedoFromDefaults()
      model.onboardingComplete = false
      onboardingComplete = false
      onboardingRedoRequested = true
    }
  }

  // ── Verification hook ──────────────────────────────────────────────────────

  /// DEBUG only. `HCC_DEBUG_OPEN_SCREEN=<screen>` on the launch environment
  /// opens one of this workstream's sheets as soon as More appears, so each can
  /// be screenshotted without UI automation.
  ///
  ///   more | devices | customize | alarm | addActivity | activity:<id>
  ///
  /// `gallery` is D-A1's value and is handled on the Home tab; anything this
  /// screen does not recognise is ignored, so the two switches share one
  /// variable without either having to know about the other.
  #if DEBUG
  /// The values of `HCC_DEBUG_OPEN_SCREEN` this screen answers to. `gallery` is
  /// D-A1's and belongs to the Home tab, so it is deliberately not here.
  static var debugLaunchScreen: String? {
    guard let raw = ProcessInfo.processInfo.environment["HCC_DEBUG_OPEN_SCREEN"], !raw.isEmpty else {
      return nil
    }
    let known = ["more", "devices", "customize", "alarm", "addActivity"]
    return known.contains(raw) || raw.hasPrefix("activity:") ? raw : nil
  }

  /// Whether the launch environment asks the app to open on the More tab.
  static var debugLaunchWantsMoreTab: Bool { debugLaunchScreen != nil }
  #endif

  private func applyDebugScreenIfRequested() {
    #if DEBUG
    guard !didApplyDebugScreen else { return }
    didApplyDebugScreen = true
    guard let raw = Self.debugLaunchScreen else { return }
    if raw.hasPrefix("activity:") {
      let id = String(raw.dropFirst("activity:".count))
      if !id.isEmpty { sheet = .activity(id) }
      return
    }
    switch raw {
    case "devices": sheet = .devices
    case "customize": sheet = .customize
    case "alarm": sheet = .alarm
    case "addActivity": sheet = .addActivity
    default: break
    }
    #endif
  }
}

/// The sheets More can present.
enum HCCMoreSheet: Identifiable {
  case devices
  case customize
  case alarm
  case addActivity
  case activity(String)
  case consent
  case comingSoon(String)

  var id: String {
    switch self {
    case .devices: "devices"
    case .customize: "customize"
    case .alarm: "alarm"
    case .addActivity: "addActivity"
    case let .activity(id): "activity:\(id)"
    case .consent: "consent"
    case let .comingSoon(feature): "comingSoon:\(feature)"
    }
  }
}

private extension String {
  /// File-local: an empty or whitespace-only server string is an absent one.
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
