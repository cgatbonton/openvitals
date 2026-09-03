import CoreBluetooth
import CoreLocation
import Foundation
import UserNotifications

enum OnboardingStep: Int, CaseIterable {
  // HCC: the provider choice leads the flow, and cloud mode adds two steps of
  // its own. Raw values no longer describe the order — `OnboardingFlow` does.
  case provider
  case hccConsent
  case hccSignIn
  case healthKit
  case location
  case bluetooth
  case notifications
  case connect
  case profile

  var title: String {
    switch self {
    // HCC:
    case .provider:
      return "Choose your source"
    case .hccConsent:
      return "What gets sent"
    case .hccSignIn:
      return "Sign in"
    case .healthKit:
      return "Import Weight"
    case .location:
      return "Enable Location"
    case .bluetooth:
      return "Enable Bluetooth"
    case .notifications:
      return "Enable Notifications"
    case .connect:
      return "Connect your wearable"
    case .profile:
      return "Personal details"
    }
  }

}

// HCC: order used to be `OnboardingStep`'s raw-value arithmetic, which can
// describe exactly one flow. There are two now, so the order is written out and
// everything derived from it — progress, the "Step n of m" label, next and
// previous — reads the list rather than doing sums on case numbers.
/// The ordered screens of onboarding for one provider.
struct OnboardingFlow {
  let steps: [OnboardingStep]

  /// The bridge path is upstream's sequence untouched, behind the one new
  /// choice screen; the cloud path drops the steps that only make sense for a
  /// Bluetooth device and adds consent and sign-in.
  static func forProvider(_ provider: HealthMetricProvider) -> OnboardingFlow {
    switch provider {
    case .bridge:
      OnboardingFlow(steps: [.provider, .healthKit, .location, .bluetooth, .notifications, .connect, .profile])
    case .hccCloud:
      OnboardingFlow(steps: [.provider, .hccConsent, .hccSignIn, .healthKit, .notifications, .profile])
    }
  }

  func contains(_ step: OnboardingStep) -> Bool {
    steps.contains(step)
  }

  func next(after step: OnboardingStep) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
      return nil
    }
    return steps[index + 1]
  }

  func previous(before step: OnboardingStep) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: step), index > 0 else {
      return nil
    }
    return steps[index - 1]
  }

  func progress(at step: OnboardingStep) -> Double {
    guard !steps.isEmpty else {
      return 1
    }
    return Double(position(of: step)) / Double(steps.count)
  }

  func stepLabel(at step: OnboardingStep) -> String {
    "Step \(position(of: step)) of \(steps.count)"
  }

  /// 1-based place in the flow. A step the current path does not contain — the
  /// instant between picking a provider and moving into its path — reads as the
  /// first, which is where the user is standing.
  private func position(of step: OnboardingStep) -> Int {
    (steps.firstIndex(of: step) ?? 0) + 1
  }
}

enum OnboardingInputField: Hashable {
  case firstName
  case heightCentimeters
  case heightFeet
  case heightInches
  case weight
}

enum OnboardingUnitSystem: String, CaseIterable, Identifiable {
  case imperial
  case metric

  var id: String { rawValue }

  var title: String {
    switch self {
    case .imperial:
      return "Imperial"
    case .metric:
      return "Metric"
    }
  }
}

enum OnboardingGender: String, CaseIterable, Identifiable {
  case female
  case male
  case nonBinary = "non_binary"
  case preferNotToSay = "prefer_not_to_say"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .female:
      return "Female"
    case .male:
      return "Male"
    case .nonBinary:
      return "Non-binary"
    case .preferNotToSay:
      return "Prefer not to say"
    }
  }
}

enum OnboardingPermissionState {
  static func locationResolved() -> Bool {
    let status = CLLocationManager().authorizationStatus
    switch status {
    case .notDetermined:
      return false
    case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
      return true
    @unknown default:
      return true
    }
  }

  static func bluetoothResolved() -> Bool {
    switch CBManager.authorization {
    case .notDetermined:
      return false
    case .allowedAlways, .denied, .restricted:
      return true
    @unknown default:
      return false
    }
  }

  static func notificationResolved() async -> Bool {
    await withCheckedContinuation { continuation in
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        continuation.resume(returning: settings.authorizationStatus != .notDetermined)
      }
    }
  }
}

enum OnboardingDate {
  static func parse(_ value: String) -> Date? {
    let formatter = dateFormatter
    guard let date = formatter.date(from: value) else {
      return nil
    }
    return Calendar.current.startOfDay(for: date)
  }

  static func dateOnlyString(_ date: Date) -> String {
    dateFormatter.string(from: date)
  }

  static func defaultDateOfBirth() -> Date {
    clamp(Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date())
  }

  static func minimumDateOfBirth() -> Date {
    Calendar.current.date(byAdding: .year, value: -120, to: Date()) ?? Date.distantPast
  }

  static func maximumDateOfBirth() -> Date {
    Calendar.current.date(byAdding: .year, value: -13, to: Date()) ?? Date()
  }

  static func clamp(_ date: Date) -> Date {
    let normalized = Calendar.current.startOfDay(for: date)
    let minimum = Calendar.current.startOfDay(for: minimumDateOfBirth())
    let maximum = Calendar.current.startOfDay(for: maximumDateOfBirth())
    if normalized < minimum {
      return minimum
    }
    if normalized > maximum {
      return maximum
    }
    return normalized
  }

  private static var dateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}
