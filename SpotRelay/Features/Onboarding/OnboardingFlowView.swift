import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var spotStore: SpotStore
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
            SpotRelayTheme.canvasGradient.ignoresSafeArea()
            SpotRelayTheme.mapGlow.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 24) {
                    ZStack {
                        Circle()
                            .fill(SpotRelayTheme.orbGradient)
                            .frame(width: 86, height: 86)

                        Image(systemName: pages[page].symbol)
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                    }

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
                                .fill(index == page ? SpotRelayTheme.primary : SpotRelayTheme.primary.opacity(0.16))
                                .frame(width: index == page ? 28 : 8, height: 8)
                        }
                    }
                }
                .padding(28)
                .glassPanel(
                    cornerRadius: 34,
                    tint: SpotRelayTheme.strongGlassTint,
                    stroke: SpotRelayTheme.glassStroke,
                    shadow: SpotRelayTheme.shadow,
                    shadowRadius: 24,
                    shadowY: 12
                )

                Spacer()

                Button {
                    advance()
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(pages[page].buttonTitle)
                    }
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .foregroundStyle(.white)
                }
                .shadow(color: SpotRelayTheme.shadow, radius: 18, y: 10)
            }
            .padding(24)
        }
    }

    private func advance() {
        if page == 1 {
            spotStore.prepareLocationTracking(requestIfNeeded: true)
        }

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
