import SwiftUI
import UIKit

/// Sign in to a self-hosted Health Command Center instance.
///
/// Standalone by design: it owns nothing but its own fields and calls
/// `onSignedIn` when the session flips. Where it appears in the flow is the
/// onboarding step's business, not this screen's.
struct HCCSignInScreen: View {
  @ObservedObject var session: HCCSession
  let onSignedIn: () -> Void

  @State private var serverAddress = ""
  @State private var email = ""
  @State private var password = ""
  @State private var totp = ""
  @State private var needsTOTP = false
  @State private var isSubmitting = false
  @State private var errorMessage: String?

  private enum Field: Hashable {
    case server, email, password, totp
  }

  @FocusState private var focusedField: Field?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        form
        footnote
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .openVitalsScreenBackground()
    .onAppear {
      if serverAddress.isEmpty {
        serverAddress = session.baseURL.absoluteString
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      OpenVitalsLogoMark(size: 54, cornerRadius: 10)

      Text("Connect to your Command Center")
        .font(.title2.bold())
        .foregroundStyle(OpenVitalsTheme.textPrimary)
      Text("Sign in to the health server you host yourself. This app reads the metrics it has already scored; it does not analyse or interpret them on its own.")
        .font(.subheadline)
        .foregroundStyle(OpenVitalsTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 12) {
      field(title: "Server address", systemImage: "network") {
        TextField("https://health.example.com", text: $serverAddress)
          .textContentType(.URL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focusedField, equals: .server)
          .submitLabel(.next)
          .onSubmit { focusedField = .email }
      }

      field(title: "Email", systemImage: "envelope") {
        TextField("you@example.com", text: $email)
          .textContentType(.username)
          .keyboardType(.emailAddress)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focusedField, equals: .email)
          .submitLabel(.next)
          .onSubmit { focusedField = .password }
      }

      field(title: "Password", systemImage: "lock") {
        SecureField("Password", text: $password)
          .textContentType(.password)
          .focused($focusedField, equals: .password)
          .submitLabel(needsTOTP ? .next : .go)
          .onSubmit {
            if needsTOTP {
              focusedField = .totp
            } else {
              submit()
            }
          }
      }

      if needsTOTP {
        field(title: "Two-factor code", systemImage: "shield") {
          TextField("123456", text: $totp)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .focused($focusedField, equals: .totp)
        }
      }

      if let errorMessage, !errorMessage.isEmpty {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button(action: submit) {
        HStack(spacing: 8) {
          if isSubmitting {
            ProgressView()
              .controlSize(.small)
          }
          Text(isSubmitting ? "Signing in…" : "Sign in")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(isSubmitting || !canSubmit)
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var footnote: some View {
    Text("Your credentials are exchanged for two tokens that are stored in this iPhone's Keychain — one for the app, one for the Apple Watch upload. Sign out here, or revoke the device on the server, to end the session.")
      .font(.footnote)
      .foregroundStyle(OpenVitalsTheme.textTertiary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
  }

  private func field(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(OpenVitalsTheme.textSecondary)
      content()
        .textFieldStyle(.plain)
        .font(.body)
        .foregroundStyle(OpenVitalsTheme.textPrimary)
        .padding(10)
        .background(OpenVitalsTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(OpenVitalsTheme.border, lineWidth: 1)
        }
    }
  }

  private var canSubmit: Bool {
    !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !password.isEmpty
      && (!needsTOTP || !totp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func submit() {
    guard !isSubmitting, canSubmit else { return }

    switch HCCSession.validate(baseURL: serverAddress) {
    case let .invalid(message):
      errorMessage = message
      focusedField = .server
      return
    case let .valid(url):
      session.setBaseURL(url)
    }

    focusedField = nil
    errorMessage = nil
    isSubmitting = true

    Task {
      defer { isSubmitting = false }
      do {
        try await session.signIn(
          email: email,
          password: password,
          totp: needsTOTP ? totp : nil,
          deviceName: UIDevice.current.name
        )
        password = ""
        totp = ""
        onSignedIn()
      } catch HCCAPIError.totpRequired {
        // Not a failure: the account has a second factor and the server is
        // asking for it. Reveal the field and keep everything else typed.
        needsTOTP = true
        errorMessage = "Enter the 6-digit code from your authenticator app."
        focusedField = .totp
      } catch {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }
}
