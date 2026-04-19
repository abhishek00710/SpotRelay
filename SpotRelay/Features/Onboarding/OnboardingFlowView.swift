import SwiftUI

struct OnboardingFlowView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        .init(
            title: "Find parking before you arrive",
            subtitle: "SpotRelay helps nearby drivers coordinate parking handoffs without the circling and guessing.",
            buttonTitle: "Get Started",
            symbol: "parkingsign.circle.fill"
        ),
        .init(
            title: "See spots near you",
            subtitle: "Location keeps the experience fast, local, and easy to trust.",
            buttonTitle: "Enable Location",
            symbol: "location.circle.fill"
        ),
        .init(
            title: "Don't miss your spot",
            subtitle: "Notifications keep countdowns, claims, and arrivals visible in real time.",
            buttonTitle: "Enable Notifications",
            symbol: "bell.badge.circle.fill"
        )
    ]

    var body: some View {
        ZStack {
            SpotRelayTheme.background.ignoresSafeArea()
            SpotRelayTheme.mapGlow.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: pages[page].symbol)
                    .font(.system(size: 74, weight: .semibold))
                    .foregroundStyle(SpotRelayTheme.primary, SpotRelayTheme.accent)

                VStack(spacing: 12) {
                    Text(pages[page].title)
                        .font(.system(size: 33, weight: .bold, design: .rounded))
                        .foregroundStyle(SpotRelayTheme.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(pages[page].subtitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? SpotRelayTheme.primary : SpotRelayTheme.primary.opacity(0.18))
                            .frame(width: index == page ? 28 : 8, height: 8)
                    }
                }

                Spacer()

                Button {
                    advance()
                } label: {
                    Text(pages[page].buttonTitle)
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
            .padding(24)
        }
    }

    private func advance() {
        if page == pages.count - 1 {
            onFinish()
        } else {
            page += 1
        }
    }
}

private struct OnboardingPage {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let symbol: String
}
