import SwiftUI

/// What cloud mode sends, where it goes, what stays on the phone, and how to
/// stop it — said once, before any credential is typed.
///
/// The screen is deliberately self-contained: there is no in-app viewer for
/// `docs/hcc-provider.md`, so linking to it would be a dead end. Everything a
/// user needs in order to agree is on this screen, and the same view backs the
/// read-only "Privacy & data flow" entry under More, so the two can never say
/// different things.
struct HCCConsentContent: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Cloud mode reads metrics your own server has already worked out. Here is exactly what moves, and what does not.")
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HCCConsentBlock(
        systemImage: "arrow.up.circle",
        title: "What this app sends",
        points: [
          "Your sign-in details, once, to get a session token.",
          "Later, and only after you turn each one on: health samples this phone reads from a paired Apple Watch, journal entries you type here, and a notification token so the server can send you alerts.",
        ]
      )

      HCCConsentBlock(
        systemImage: "network",
        title: "Where it goes",
        points: [
          "Only to the Command Center you host yourself, at the address you enter on the next screen.",
          "There is no analytics service, vendor backend, or other third party in the path.",
        ]
      )

      HCCConsentBlock(
        systemImage: "iphone",
        title: "What stays on this phone",
        points: [
          "A session token in the iPhone Keychain, kept out of iCloud and encrypted backups.",
          "Anything the Bluetooth path already collected stays local. Cloud mode never uploads it.",
        ]
      )

      HCCConsentBlock(
        systemImage: "xmark.shield",
        title: "How to stop it",
        points: [
          "Sign out under More in this app. That revokes the token on the server and deletes it from this phone.",
          "Or open Settings, then Mobile app sessions, on your server in a browser and revoke the device there.",
        ]
      )

      Text("This app shows what your server reports. It does not diagnose, treat, or give medical advice.")
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }
  }
}

/// The onboarding step. Just the content — the "I agree, continue" and "Back"
/// buttons are the flow's standard action bar, so they look and behave like
/// every other step's.
struct OnboardingHCCConsentStep: View {
  var body: some View {
    HCCConsentContent()
  }
}

/// The same text under More, read only: no agreement to give, just a Done.
struct HCCConsentSheet: View {
  let onDismiss: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        HCCConsentContent()
          .padding(.horizontal, 20)
          .padding(.vertical, 18)
      }
      .openVitalsScreenBackground()
      .navigationTitle("Privacy & data flow")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: onDismiss)
        }
      }
    }
  }
}

/// A back-only action bar, for the sign-in step: that screen owns its own
/// primary button, so the flow must not add a second one.
struct HCCOnboardingBackBar: View {
  let onBack: () -> Void

  var body: some View {
    Button(action: onBack) {
      Label("Back", systemImage: "chevron.left")
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .padding(16)
    .background(.regularMaterial)
  }
}

private struct HCCConsentBlock: View {
  let systemImage: String
  let title: String
  let points: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.headline)
          .foregroundStyle(OpenVitalsTheme.accent)
          .frame(width: 36, height: 36)
          .background(
            OpenVitalsTheme.accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
      }

      VStack(alignment: .leading, spacing: 10) {
        ForEach(points, id: \.self) { point in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
              .font(.system(size: 5))
              .foregroundStyle(.tertiary)
              .padding(.top, 6)
            Text(point)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(.separator).opacity(0.35))
    }
  }
}
