import SwiftUI

// The one place Home names another screen.
//
// Home pushes three ring details and an activity detail, and presents four
// sheets. Every one of those screens is owned by a different workstream and
// lands on its own schedule, so Home refers to them ONLY through the two
// builders at the bottom of this file. That is the whole point of the file:
// integrating a screen is an edit here, not a hunt through Home's layout for
// the tap handler that constructs it.
//
// Every screen Home reaches is now wired: workstream D-B's three ring details
// and D-C's five sheets and the activity detail. `HCCPendingScreen` is kept as
// the stand-in a future route uses before its screen lands — a themed page that
// says nothing is there yet, rather than an empty version of a real screen.
// ─────────────────────────────────────────────────────────────────────────────

/// A screen Home pushes onto its navigation stack.
enum HCCHomeRoute: Hashable {
  // The three ring routes carry the SERVER day key Home was showing when the
  // ring was tapped. Passing it rather than letting the detail follow "whatever
  // day the store last read" is what stops a tap on Monday's recovery from
  // opening today's once something else refreshes the store mid-push.
  case recovery(day: String)
  case sleep(day: String)
  case strain(day: String)
  case activity(id: String)

  /// The `HealthRoute` a ring corresponds to, for the debug launch hook and for
  /// anything else that already speaks in the app's route vocabulary.
  init?(healthRoute: HealthRoute, day: String) {
    switch healthRoute {
    case .recovery: self = .recovery(day: day)
    case .sleep: self = .sleep(day: day)
    case .strain: self = .strain(day: day)
    default: return nil
    }
  }

  var title: String {
    switch self {
    case .recovery: "Recovery"
    case .sleep: "Sleep"
    case .strain: "Strain"
    case .activity: "Activity"
    }
  }
}

/// A sheet Home presents.
enum HCCHomeSheet: Identifiable, Hashable {
  case devices
  case alarm
  case customize
  case addActivity
  /// HCC: the live workout's setup sheet, which then presents the running
  /// screen full-screen over itself.
  case live
  /// A surface that belongs to a later phase; the string is what the sheet
  /// names ("Coach", "Live activity").
  case comingSoon(String)

  var id: String {
    switch self {
    case .devices: "devices"
    case .alarm: "alarm"
    case .customize: "customize"
    case .addActivity: "addActivity"
    case .live: "live"
    case let .comingSoon(feature): "comingSoon:\(feature)"
    }
  }
}

// ── Builders ─────────────────────────────────────────────────────────────────

/// The pushed screens.
struct HCCHomeDestination: View {
  let route: HCCHomeRoute
  @ObservedObject var store: HealthDataStore

  var body: some View {
    switch route {
    case let .recovery(day):
      HCCRecoveryView(store: store, dayKey: day)
    case let .sleep(day):
      HCCSleepView(store: store, dayKey: day)
    case let .strain(day):
      HCCStrainView(store: store, dayKey: day)
    case let .activity(id):
      // Through the route resolver, not straight to the workout detail: a sleep
      // row on Home is a night and opens `HCCSleepView` instead.
      HCCActivityDestinationView(store: store, activityId: id)
    }
  }
}

/// The presented sheets.
struct HCCHomeSheetHost: View {
  let sheet: HCCHomeSheet
  @ObservedObject var store: HealthDataStore

  var body: some View {
    switch sheet {
    case .devices:
      HCCDevicesSheet(store: store)
    case .alarm:
      HCCAlarmSheet(store: store)
    case .customize:
      HCCCustomizeSheet(store: store)
    case .addActivity:
      HCCAddActivitySheet(store: store)
    case .live:
      HCCLiveSetupSheet(store: store)
    case let .comingSoon(feature):
      HCCComingSoonSheet(feature: feature)
    }
  }
}

/// The stand-in a route shows while the screen that owns it is still being
/// built. It says plainly that nothing is there yet rather than rendering an
/// empty version of a screen, which would read as a screen with no data.
///
/// This view disappears at integration — every case above stops pointing at it.
struct HCCPendingScreen: View {
  let title: String
  let owner: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(HCCTheme.Font.display(size: 20, weight: .medium))
        .tracking(-0.4)
        .foregroundStyle(HCCTheme.Color.text)

      VStack(alignment: .leading, spacing: 8) {
        HCCLabel("Not wired up yet")
        Text("This build does not include \(owner). Nothing was logged or changed.")
          .font(HCCTheme.Font.body(size: 12.5))
          .foregroundStyle(HCCTheme.Color.text)
      }
      .hccCard()

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .hccBackground()
  }
}
