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

  // HCC: DEBUG-only verification hook. When the launch environment names one of
  // the More tab's screens (`HCC_DEBUG_OPEN_SCREEN=alarm|devices|customize|…`)
  // the app opens on More, which is where that switch is read. Compiled out of
  // Release; the default tab is unchanged in every other case.
  init() {
    #if DEBUG
    if HCCMoreScreen.debugLaunchWantsMoreTab {
      selectedTab = .more
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

  func reselect(_ tab: OpenVitalsAppTab) {
    switch tab {
    case .coach:
      coachScrollToBottomRequestID += 1
    default:
      break
    }
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
