import MapKit
import SwiftUI
import Combine

struct ActiveHandoffView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    let signal: ParkingSpotSignal
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pendingRecenterOnLocationUpdate = false

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
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                spotStore.prepareLocationTracking(requestIfNeeded: false)
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
            .onReceive(spotStore.$userCoordinate.dropFirst()) { _ in
                guard pendingRecenterOnLocationUpdate else { return }
                recenterOnUser()
                pendingRecenterOnLocationUpdate = false
            }
        }
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active handoff")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(SpotRelayTheme.badgeText)

                    Text(roleTitle)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(roleSubtitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    infoBadge(liveSignal.minutesRemainingText)
                    infoBadge(liveSignal.statusLabel(for: spotStore.currentUser.id))
                }
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.orbGradient)
                    .frame(width: 58, height: 58)

                Image(systemName: "arrow.trianglehead.swap")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: 32,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 24,
            shadowY: 12
        )
    }

    private var liveMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live map")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Keep the handoff visible while you coordinate.")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text("Tracked")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }

            ZStack(alignment: .topTrailing) {
                SizedMap(position: $cameraPosition) {
                    UserAnnotation()

                    Annotation("Spot", coordinate: liveSignal.coordinate) {
                        Image(systemName: "parkingsign.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white, SpotRelayTheme.primary)
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .mapStyle(.standard(elevation: .flat))

                MapRecenterButton {
                    pendingRecenterOnLocationUpdate = true
                    spotStore.prepareLocationTracking(requestIfNeeded: true)
                    recenterOnUser()
                }
                .padding(14)
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 30, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 16, shadowY: 8)
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
        .glassPanel(
            cornerRadius: 30,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 16,
            shadowY: 8
        )
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
        .glassPanel(cornerRadius: 26, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 12, shadowY: 6)
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
            .background(SpotRelayTheme.badgeFill, in: Capsule())
            .foregroundStyle(SpotRelayTheme.badgeText)
    }

    private func actionButtonLabel(title: String, color: Color) -> some View {
        let fillStyle = title == "I'm Here" ? AnyShapeStyle(SpotRelayTheme.heroGradient) : AnyShapeStyle(color)

        return Text(title)
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(fillStyle, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private func recenterOnUser() {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: spotStore.userCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
        )
    }
}
