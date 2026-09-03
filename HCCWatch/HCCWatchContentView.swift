import SwiftUI

// HCC: the watch app's only screen (plan §4.7a).
//
// Three things and no fourth: the current heart rate, the elapsed clock, and
// one button that starts or ends the workout. Everything else this app could
// show — zones, strain, the day's numbers — is on the phone, which is the only
// device with the server's ceilings and the server's history. A watch screen
// that guessed at any of them would be a second, quieter source of truth.
//
// The look is deliberately plain watchOS rather than the phone's HCC design
// system: that system is built on registered custom fonts and a card chassis
// that belong to the iPhone target, and dragging it across for two labels and
// a button would tie a thin companion to a large dependency for no gain.

struct HCCWatchContentView: View {
  @ObservedObject private var workout = HCCWatchWorkoutManager.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(spacing: 8) {
      heartRate
      Text(Self.clock(workout.elapsed))
        .font(.system(.title3, design: .rounded).monospacedDigit())
        .foregroundStyle(.secondary)
      Text(workout.status)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
      button
    }
    .padding(.horizontal, 4)
    .onChange(of: scenePhase) { _, phase in
      // Every activation relays the battery, which is the cadence the phone
      // side documents. Cheap: one coalesced dictionary, not a message queue.
      if phase == .active { HCCWatchBattery.shared.activate() }
    }
  }

  private var heartRate: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: "heart.fill")
        .foregroundStyle(.red)
        .font(.title3)
      // No reading yet, or a session that has not started, shows "--".
      // The watch never holds the last number under a live heading.
      Text(workout.bpm.map(String.init) ?? "--")
        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
      Text("bpm")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var button: some View {
    Button {
      Task {
        if workout.isActive {
          await workout.stop()
        } else {
          await workout.start()
        }
      }
    } label: {
      Text(workout.isActive ? "End" : "Start")
        .frame(maxWidth: .infinity)
    }
    .tint(workout.isActive ? .red : .accentColor)
  }

  /// `m:ss` under an hour, `h:mm:ss` over it.
  static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }
}

#Preview {
  HCCWatchContentView()
}
