import ActivityKit
import Foundation

// The strain Live Activity's contract, compiled into both the app (which starts
// and updates the activity) and the widget extension (which draws it).
//
// Every field is optional except the day and the stamp, for the same reason the
// widget summary's are: a Live Activity that showed `0.0` for "no strain yet"
// would be inventing a reading. Nil renders as "--" with the server's reason.
//
// `day` is on the attributes rather than the state because it is what makes an
// activity *this day's*: a day rollover ends the activity and starts a new one
// rather than silently repointing yesterday's banner at today's numbers.

struct HCCStrainActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// 0–21, the server's scale. Nil = not scored yet.
    var strain: Double?
    /// Today's target strain, from this morning's recovery.
    var target: Double?
    /// 0–100, used only for the small band chip.
    var recovery: Int?
    /// When the app last pushed this state.
    var updatedAt: Date
    /// The server's sentence for a missing value. Shown verbatim.
    var reason: String?

    init(
      strain: Double? = nil,
      target: Double? = nil,
      recovery: Int? = nil,
      updatedAt: Date = Date(),
      reason: String? = nil
    ) {
      self.strain = strain
      self.target = target
      self.recovery = recovery
      self.updatedAt = updatedAt
      self.reason = reason
    }
  }

  /// The instance's civil day (`YYYY-MM-DD`) this activity belongs to.
  var day: String

  init(day: String) {
    self.day = day
  }
}
