import MapKit
import SwiftUI

struct ActiveHandoffView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    let signal: ParkingSpotSignal
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var liveSignal: ParkingSpotSignal {
        spotStore.activeHandoff ?? signal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    liveMap
                    actionPanel
                    statusPanel
                }
                .padding(20)
            }
            .background(
                LinearGradient(
                    colors: [SpotRelayTheme.background, Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: liveSignal.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                    )
                )
            }
            .task {
                await spotStore.runRefreshLoop()
            }
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(roleTitle)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(roleSubtitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))

            HStack(spacing: 12) {
                infoBadge(liveSignal.minutesRemainingText)
                infoBadge(liveSignal.statusLabel(for: spotStore.currentUser.id))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var liveMap: some View {
        SizedMap(position: $cameraPosition) {
            Annotation("Spot", coordinate: liveSignal.coordinate) {
                Image(systemName: "parkingsign.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, SpotRelayTheme.primary)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .mapStyle(.standard(elevation: .flat))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Next action")
                .font(.title3.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            if spotStore.currentUserRole == .arriving {
                Button {
                    spotStore.markArrival()
                } label: {
                    actionButtonLabel(title: "I'm Here", color: SpotRelayTheme.success)
                }
                .buttonStyle(.plain)
            }

            Button {
                spotStore.cancelActiveHandoff()
                dismiss()
            } label: {
                actionButtonLabel(title: "Cancel", color: SpotRelayTheme.warning)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button {
                    spotStore.completeActiveHandoff(success: true)
                    dismiss()
                } label: {
                    completionButton(title: "Yes", icon: "hand.thumbsup.fill", color: SpotRelayTheme.success)
                }
                .buttonStyle(.plain)

                Button {
                    spotStore.completeActiveHandoff(success: false)
                    dismiss()
                } label: {
                    completionButton(title: "No", icon: "hand.thumbsdown.fill", color: SpotRelayTheme.warning)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(SpotRelayTheme.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handoff status")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            statusLine("Spot state", value: liveSignal.statusLabel(for: spotStore.currentUser.id))
            statusLine("Distance", value: "\(liveSignal.distanceMeters(from: spotStore.userCoordinate)) meters")
            statusLine("Countdown", value: liveSignal.minutesRemainingText)
        }
        .padding(20)
        .background(SpotRelayTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var roleTitle: String {
        switch spotStore.currentUserRole {
        case .leaving:
            return "Your spot is live"
        case .arriving:
            return "Heading to your spot"
        case .none:
            return "Active handoff"
        }
    }

    private var roleSubtitle: String {
        switch spotStore.currentUserRole {
        case .leaving:
            return "Stay visible while the arriving driver closes the gap."
        case .arriving:
            return "Keep the leaving driver confident with a clear live arrival state."
        case .none:
            return "Real-time coordination keeps the exchange simple."
        }
    }

    private func infoBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.18), in: Capsule())
            .foregroundStyle(.white)
    }

    private func actionButtonLabel(title: String, color: Color) -> some View {
        Text(title)
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .foregroundStyle(.white)
    }

    private func completionButton(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title)
        }
        .font(.headline.weight(.bold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(color)
    }

    private func statusLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(SpotRelayTheme.textSecondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(SpotRelayTheme.textPrimary)
        }
        .font(.subheadline)
    }
}
