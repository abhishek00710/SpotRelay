import SwiftUI

struct SpotRelayErrorBannerState: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct SpotRelayErrorBanner: View {
    let banner: SpotRelayErrorBannerState
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(SpotRelayTheme.danger.opacity(0.14))
                    .frame(width: 38, height: 38)

                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SpotRelayTheme.danger)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(banner.message)
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(SpotRelayTheme.badgeFill, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .glassPanel(
            cornerRadius: 24,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 18,
            shadowY: 10
        )
    }
}

private struct SpotRelayConnectivityBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(SpotRelayTheme.warning.opacity(0.16))
                    .frame(width: 38, height: 38)

                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SpotRelayTheme.warning)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("No internet connection")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("SpotRelay won't be able to load live handoffs or complete claims until you're back online.")
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .glassPanel(
            cornerRadius: 24,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 18,
            shadowY: 10
        )
    }
}

private struct SpotRelayErrorBannerModifier: ViewModifier {
    @ObservedObject var store: SpotStore

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                VStack(spacing: 10) {
                    if !store.isNetworkAvailable {
                        SpotRelayConnectivityBanner()
                    }

                    if let banner = store.errorBanner {
                        SpotRelayErrorBanner(banner: banner) {
                            store.clearErrorBanner()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.errorBanner?.id)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: store.isNetworkAvailable)
    }
}

extension View {
    func spotRelayErrorBanner(using store: SpotStore) -> some View {
        modifier(SpotRelayErrorBannerModifier(store: store))
    }
}
