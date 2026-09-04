import Foundation

@MainActor
final class AppRouter: ObservableObject {
  @Published var selectedTab: OpenVitalsAppTab = .home
  @Published var healthPath: [HealthRoute] = []
  @Published var morePath: [MoreRoute] = []
  @Published var codexAuthCallbackURL: URL?
  @Published var codexEmbeddedLoginRequestID = 0
  @Published var coachPromptDraft = ""
  @Published var coachPromptRequestID = 0
  @Published var coachScrollToBottomRequestID = 0
  // HCC: in cloud mode the Coach is a sheet over the current screen, not a tab.
  // Bumping this asks the cloud shell to present it; the shell owns the sheet.
  @Published var hccCoachRequested = 0
  /// Bumped by `reselect`. Read by the cloud shell and by cloud Home, each of
  /// which pops its OWN stack and only while it is the selected tab.
  @Published var hccPopToRootRequestID = 0

  // HCC: where a push's deep link wants to land in cloud mode.
  //
  // `healthPath` cannot carry it: in cloud mode the Health tab has its own
  // navigation stack and Home has another, and neither is driven by that array
  // — so `openHealth(.recovery)` set a path nothing was reading and a tapped
  // notification did nothing. The Health tab consumes this instead and clears
  // it, so the same link tapped twice opens the screen twice.
  @Published var hccPendingHealthDestination: HCCDeepLinkTarget?

  // HCC: DEBUG-only verification hook. When the launch environment names one of
  // the More tab's screens (`HCC_DEBUG_OPEN_SCREEN=alarm|devices|customize|…`)
  // the app opens on More, which is where that switch is read. Compiled out of
  // Release; the default tab is unchanged in every other case.
  init() {
    #if DEBUG
    if HCCMoreScreen.debugLaunchWantsMoreTab {
      selectedTab = .more
    } else if HCCDebugScreen.requested != nil {
      // The Health tab reads the same variable for its own eight screens, but
      // only once it is on screen — without this the app opened on Home and a
      // `HCC_DEBUG_OPEN_SCREEN=health` launch silently screenshotted Home.
      selectedTab = .health
    }
    #endif
  }

  func openHealth(_ route: HealthRoute?) {
    selectedTab = .home
    if let route {
      healthPath = [route]
    } else {
      healthPath = []
    }
  }

  func openCoach(prompt: String? = nil) {
    // HCC: cloud mode has no Coach tab; hand the request to the sheet instead.
    if HCCProviderSettings.isCloud {
      if let prompt { coachPromptDraft = prompt }
      hccCoachRequested += 1
      return
    }
    selectedTab = .coach
    guard let prompt else {
      return
    }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      return
    }
    coachPromptDraft = trimmedPrompt
    coachPromptRequestID += 1
  }

  func openMore(_ route: MoreRoute?) {
    selectedTab = .more
    if let route {
      morePath = [route]
    } else {
      morePath = []
    }
  }

  /// Tapping the tab you are already on means "take me back to the top of this
  /// tab" — the standard iOS gesture. Each cloud tab owns its own navigation
  /// path, so this is a bump rather than a command: the stack that is currently
  /// on screen clears itself, and the others keep their state, exactly as a
  /// system `TabView` behaves.
  func reselect(_ tab: OpenVitalsAppTab) {
    switch tab {
    case .coach:
      coachScrollToBottomRequestID += 1
    default:
      break
    }
    hccPopToRootRequestID += 1
  }

  @discardableResult
  func handleDeepLink(_ url: URL) -> Bool {
    if isCodexAuthCallback(url) {
      selectedTab = .coach
      codexAuthCallbackURL = url
      return true
    }

    if isAppScheme(url), url.host == "coach" {
      selectedTab = .coach
      if url.pathComponents.dropFirst().first == "embedded-login" {
        codexEmbeddedLoginRequestID += 1
      }
      return true
    }

    if isAppScheme(url), url.host == "more" {
      let routeName = url.pathComponents.dropFirst().first ?? ""
      if routeName.isEmpty {
        openMore(nil)
        return true
      }
      guard let route = MoreRoute(rawValue: routeName) else {
        return false
      }
      openMore(route)
      return true
    }

    guard isAppScheme(url), url.host == "health" else {
      return false
    }
    let routeName = url.pathComponents.dropFirst().first ?? ""
    // HCC: cloud mode has real screens for all of these, on the Health tab.
    // Bridge mode keeps the behaviour below unchanged.
    if HCCProviderSettings.isCloud {
      // A bare `openvitals://health` is "show me Health", not a screen inside
      // it — that stays the tab's own landing.
      if routeName.isEmpty {
        selectedTab = .health
        hccPendingHealthDestination = nil
        return true
      }
      guard let target = HCCDeepLinkTarget(deepLinkPath: routeName) else { return false }
      if target == .settings {
        openMore(nil)
        return true
      }
      selectedTab = .health
      hccPendingHealthDestination = target
      return true
    }
    if routeName.isEmpty {
      openHealth(nil)
      return true
    }
    // HCC: the server's push notifications link to two destinations this app
    // has no screen for — `insights` (the weekly log) and `settings` (sent when
    // a session needs re-authenticating). Land them on the nearest real surface
    // so a tapped notification never does nothing.
    if routeName == "insights" {
      openHealth(nil)
      return true
    }
    if routeName == "settings" {
      openMore(nil)
      return true
    }
    guard let route = HealthRoute(rawValue: routeName) else {
      return false
    }
    openHealth(route)
    return true
  }

  private func isCodexAuthCallback(_ url: URL) -> Bool {
    isAppScheme(url) && url.host == "codex-auth"
  }

  private func isAppScheme(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else {
      return false
    }
    return scheme == "openvitals"
  }
}

// HCC: the destinations the instance's push notifications link to.
//
// The full list is `src/lib/push/payload.ts` in the server repo: recovery,
// sleep and strain rules link to their detail screens, everything else falls
// back to `insights`, and a session that needs re-authenticating links to
// `settings`. `healthMonitor` is the bridge's own route name and is mapped onto
// recovery rather than rejected, because that is the screen it means here.
enum HCCDeepLinkTarget: String, Hashable, Identifiable {
  case recovery
  case sleep
  case strain
  case insights
  case settings

  var id: String { rawValue }

  init?(deepLinkPath: String) {
    switch deepLinkPath {
    case "recovery", "healthMonitor": self = .recovery
    case "sleep": self = .sleep
    case "strain": self = .strain
    case "insights": self = .insights
    case "settings": self = .settings
    default: return nil
    }
  }
}
