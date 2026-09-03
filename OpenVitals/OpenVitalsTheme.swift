import SwiftUI
import UIKit

enum OpenVitalsAppearancePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "openVitals.appearancePreference"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var detail: String {
    switch self {
    case .system: "Follow the appearance selected on this iPhone."
    case .light: "Use the brighter OpenVitals interface."
    case .dark: "Use the darker OpenVitals interface."
    }
  }

  var systemImage: String {
    switch self {
    case .system: "iphone"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  static func preference(for rawValue: String) -> OpenVitalsAppearancePreference {
    OpenVitalsAppearancePreference(rawValue: rawValue) ?? .dark
  }
}

enum OpenVitalsTheme {
  static let graphite = Color(red: 0.063, green: 0.063, blue: 0.063)
  static let soot = Color(red: 0.086, green: 0.082, blue: 0.082)
  static let charcoal = Color(red: 0.094, green: 0.094, blue: 0.094)
  static let ember = Color(red: 0.125, green: 0.094, blue: 0.094)
  static let bronze = Color(red: 0.722, green: 0.576, blue: 0.345)
  static let gold = Color(red: 0.910, green: 0.753, blue: 0.533)
  static let champagne = Color(red: 0.925, green: 0.788, blue: 0.592)
  static let ivory = Color(red: 0.973, green: 0.878, blue: 0.722)
  static let deviceBackground = graphite
  static let accent = champagne
  static let accentMuted = bronze
  static let accentDeep = gold
  static let textPrimary = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? ivoryUIColor : graphiteUIColor
  })
  static let textSecondary = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? champagneUIColor.withAlphaComponent(0.68)
      : graphiteUIColor.withAlphaComponent(0.68)
  })
  static let textTertiary = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? champagneUIColor.withAlphaComponent(0.42)
      : graphiteUIColor.withAlphaComponent(0.46)
  })
  static let surface = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? surfaceUIColor : lightSurfaceUIColor
  })
  static let elevatedSurface = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? elevatedSurfaceUIColor : lightElevatedSurfaceUIColor
  })
  static let border = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? champagneUIColor.withAlphaComponent(0.13)
      : graphiteUIColor.withAlphaComponent(0.13)
  })
  static let separator = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? champagneUIColor.withAlphaComponent(0.09)
      : graphiteUIColor.withAlphaComponent(0.12)
  })

  static let appBackground = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? graphiteUIColor : lightBackgroundUIColor
  })

  static let plainBackground = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? sootUIColor : lightPlainBackgroundUIColor
  })

  static func configureAppearance() {
    UIWindow.appearance().backgroundColor = appBackgroundUIColor
    UITableView.appearance().backgroundColor = appBackgroundUIColor
    UICollectionView.appearance().backgroundColor = appBackgroundUIColor
    UITableViewCell.appearance().backgroundColor = listCellBackgroundUIColor
    UIView.appearance().tintColor = champagneUIColor

    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithTransparentBackground()
    navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
    navigationAppearance.backgroundColor = navigationBarBackgroundUIColor
    navigationAppearance.shadowColor = .clear
    UINavigationBar.appearance().standardAppearance = navigationAppearance
    UINavigationBar.appearance().compactAppearance = navigationAppearance
    UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance

    let tabAppearance = UITabBarAppearance()
    tabAppearance.configureWithOpaqueBackground()
    tabAppearance.backgroundColor = appBackgroundUIColor
    tabAppearance.shadowColor = separatorUIColor
    tabAppearance.stackedLayoutAppearance.selected.iconColor = champagneUIColor
    tabAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: champagneUIColor]
    tabAppearance.stackedLayoutAppearance.normal.iconColor = mutedTextUIColor
    tabAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: mutedTextUIColor]
    UITabBar.appearance().standardAppearance = tabAppearance
    UITabBar.appearance().scrollEdgeAppearance = tabAppearance
  }

  static func statusTint(_ status: MoreStatusKind) -> Color {
    switch status {
    case .ready:
      gold
    case .pending, .waiting, .listening, .inProgress:
      champagne
    case .blocked, .stale:
      bronze
    case .notRun, .unavailable:
      textTertiary
    }
  }

  static func routeTint(_ route: HealthRoute) -> Color {
    switch route {
    case .sleep, .healthMonitor:
      champagne
    case .recovery, .packetInputs:
      gold
    case .strain, .algorithms, .referenceComparisons:
      bronze
    case .stress, .cardioLoad, .energyBank, .calibration:
      accentMuted
    }
  }

  static func sourceTint(_ source: HealthDataSource) -> Color {
    switch source.kind {
    case .bridge, .live:
      champagne
    case .local:
      gold
    // HCC: distinct from the on-device kinds so a cloud-scored row reads as
    // one at a glance.
    case .cloud:
      bronze
    case .unavailable:
      textTertiary
    }
  }

  private static let graphiteUIColor = UIColor(red: 0.063, green: 0.063, blue: 0.063, alpha: 1)
  private static let sootUIColor = UIColor(red: 0.086, green: 0.082, blue: 0.082, alpha: 1)
  private static let surfaceUIColor = UIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)
  private static let elevatedSurfaceUIColor = UIColor(red: 0.125, green: 0.094, blue: 0.094, alpha: 1)
  private static let bronzeUIColor = UIColor(red: 0.722, green: 0.576, blue: 0.345, alpha: 1)
  private static let goldUIColor = UIColor(red: 0.910, green: 0.753, blue: 0.533, alpha: 1)
  private static let champagneUIColor = UIColor(red: 0.925, green: 0.788, blue: 0.592, alpha: 1)
  private static let ivoryUIColor = UIColor(red: 0.973, green: 0.878, blue: 0.722, alpha: 1)
  private static let lightBackgroundUIColor = UIColor(red: 0.973, green: 0.878, blue: 0.722, alpha: 1)
  private static let lightPlainBackgroundUIColor = UIColor(red: 0.941, green: 0.816, blue: 0.596, alpha: 1)
  private static let lightSurfaceUIColor = UIColor(red: 0.925, green: 0.788, blue: 0.592, alpha: 1)
  private static let lightElevatedSurfaceUIColor = UIColor(red: 0.973, green: 0.878, blue: 0.722, alpha: 1)
  private static let mutedTextUIColor = champagneUIColor.withAlphaComponent(0.58)
  private static let separatorUIColor = champagneUIColor.withAlphaComponent(0.10)

  private static let appBackgroundUIColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? graphiteUIColor : lightBackgroundUIColor
  }

  private static let listCellBackgroundUIColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? surfaceUIColor : lightSurfaceUIColor
  }

  private static let navigationBarBackgroundUIColor = UIColor { traits in
    let alpha: CGFloat = traits.userInterfaceStyle == .dark ? 0.78 : 0.88
    return appBackgroundUIColor.resolvedColor(with: traits).withAlphaComponent(alpha)
  }
}

struct OpenVitalsLogoMark: View {
  let size: CGFloat
  let cornerRadius: CGFloat

  init(size: CGFloat = 44, cornerRadius: CGFloat = 8) {
    self.size = size
    self.cornerRadius = cornerRadius
  }

  var body: some View {
    Image("openvitals_logo")
      .resizable()
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
      .accessibilityHidden(true)
  }
}

extension View {
  func openVitalsScreenBackground() -> some View {
    background(OpenVitalsTheme.appBackground.ignoresSafeArea())
      .tint(OpenVitalsTheme.accent)
  }

  func openVitalsPlainBackground() -> some View {
    background(OpenVitalsTheme.plainBackground.ignoresSafeArea())
      .tint(OpenVitalsTheme.accent)
  }

  func openVitalsListBackground() -> some View {
    scrollContentBackground(.hidden)
      .background(OpenVitalsTheme.appBackground.ignoresSafeArea())
      .tint(OpenVitalsTheme.accent)
  }
}
