import SwiftUI

/// The first screen of onboarding: where this phone gets its numbers.
///
/// Two answers, presented symmetrically — neither is the upgrade. Picking the
/// band leaves the rest of onboarding exactly as upstream built it; picking the
/// Command Center starts the consent path. The copy for both lives on
/// `HealthMetricProvider` so the picker and any later settings screen can never
/// drift apart.
struct OnboardingProviderStep: View {
  let selected: HealthMetricProvider?
  let onSelect: (HealthMetricProvider) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("How do you want to get your numbers?")
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 12) {
        ForEach(HealthMetricProvider.allCases) { provider in
          OnboardingProviderCard(
            provider: provider,
            isSelected: selected == provider
          ) {
            onSelect(provider)
          }
        }
      }

      Text("You can change this later by redoing setup.")
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }
  }
}

/// One of the two choices. A whole-card button rather than a radio row: the
/// pick is the action, so there is no separate Continue to miss.
private struct OnboardingProviderCard: View {
  let provider: HealthMetricProvider
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: systemImage)
          .font(.headline)
          .foregroundStyle(OpenVitalsTheme.accent)
          .frame(width: 36, height: 36)
          .background(
            OpenVitalsTheme.accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 4) {
          Text(provider.title)
            .font(.headline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
          Text(provider.detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(isSelected ? OpenVitalsTheme.accent : Color.secondary)
          .padding(.top, 2)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(
            isSelected ? OpenVitalsTheme.accent : Color(.separator).opacity(0.35),
            lineWidth: isSelected ? 1.5 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(provider.title)
    .accessibilityHint(provider.detail)
  }

  private var systemImage: String {
    switch provider {
    case .bridge: "sensor.tag.radiowaves.forward"
    case .hccCloud: "server.rack"
    }
  }
}
