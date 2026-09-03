import SwiftUI

@main
struct OpenVitalsApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = OpenVitalsAppModel()
  @StateObject private var router = AppRouter()
  @AppStorage(OpenVitalsAppearancePreference.storageKey) private var appearancePreferenceRaw = OpenVitalsAppearancePreference.dark.rawValue

  init() {
    OpenVitalsTheme.configureAppearance()
    // HCC: DEBUG-only. When the process is launched with HCC_DEBUG_TOKEN the
    // session signs itself in from the environment, so simulator verification
    // never types a password into the UI. Compiled out of Release; no-op
    // without the variable. See docs/hcc-provider.md.
    #if DEBUG
    HCCSession.bootstrapForDebugLaunchIfNeeded()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .preferredColorScheme(OpenVitalsAppearancePreference.preference(for: appearancePreferenceRaw).colorScheme)
        .environmentObject(model)
        .environmentObject(model.packetMonitor)
        .environmentObject(model.ble.messageStore)
        .environmentObject(router)
        .onOpenURL { url in
          if model.handleDebugCommandDeepLink(url) {
            router.selectedTab = .more
          } else {
            _ = router.handleDeepLink(url)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          switch phase {
          case .active:
            model.handleAppLifecycleChange("active")
          case .inactive:
            model.handleAppLifecycleChange("inactive")
          case .background:
            model.handleAppLifecycleChange("background")
          @unknown default:
            model.handleAppLifecycleChange("unknown")
          }
        }
    }
  }
}
