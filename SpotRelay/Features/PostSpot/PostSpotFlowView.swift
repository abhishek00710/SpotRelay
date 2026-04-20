import MapKit
import SwiftUI
import Combine

struct PostSpotFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    @State private var selectedMinutes = 2
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pendingRecenterOnLocationUpdate = true

    private let durations = [2, 5, 10]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topHandle
                heroPanel
                durationPicker
                locationPreview
                shareButton
                Spacer(minLength: 0)
            }
            .padding(20)
            .task {
                spotStore.prepareLocationTracking(requestIfNeeded: false)
                recenterOnUser()
            }
        }
        .onReceive(spotStore.$userCoordinate.dropFirst()) { _ in
            guard pendingRecenterOnLocationUpdate else { return }
            recenterOnUser()
            pendingRecenterOnLocationUpdate = false
        }
    }

    private var topHandle: some View {
        Capsule()
            .fill(SpotRelayTheme.textSecondary.opacity(0.24))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private var heroPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Leaving soon?")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("Share your spot in under three seconds.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)

                Text("Live once you post")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.orbGradient)
                    .frame(width: 54, height: 54)

                Image(systemName: "parkingsign.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(22)
        .glassPanel(
            cornerRadius: 30,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 22,
            shadowY: 12
        )
    }

    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick your timing")
                .font(.headline.weight(.semibold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            HStack(spacing: 12) {
                ForEach(durations, id: \.self) { minute in
                    Button {
                        selectedMinutes = minute
                    } label: {
                        let fillStyle = selectedMinutes == minute ? AnyShapeStyle(SpotRelayTheme.heroGradient) : AnyShapeStyle(SpotRelayTheme.badgeFill)

                        VStack(spacing: 6) {
                            Text("\(minute)")
                                .font(.title3.weight(.bold))

                            Text("min")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(1.1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(fillStyle, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .foregroundStyle(selectedMinutes == minute ? .white : SpotRelayTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 28, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 16, shadowY: 8)
    }

    private var locationPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your current spot")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("The handoff will publish from your live location.")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text("Live")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }

            ZStack(alignment: .topTrailing) {
                SizedMap(position: $cameraPosition) {
                    UserAnnotation()
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
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
        .glassPanel(cornerRadius: 28, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 16, shadowY: 8)
    }

    private var shareButton: some View {
        Button {
            spotStore.postSpot(durationMinutes: selectedMinutes)
            dismiss()
        } label: {
            HStack {
                Image(systemName: "arrowshape.turn.up.right.circle.fill")
                Text("Share My Spot")
            }
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .shadow(color: SpotRelayTheme.shadow, radius: 18, y: 10)
    }

    private func recenterOnUser() {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: spotStore.userCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        )
    }
}
