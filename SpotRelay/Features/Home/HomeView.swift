import MapKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var spotStore: SpotStore
    let onLeaveSoon: () -> Void
    let onSelectSpot: (ParkingSpotSignal) -> Void
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            overlayGradient
            content
        }
        .background(SpotRelayTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            focusMap()
        }
        .task {
            await spotStore.runRefreshLoop()
        }
    }

    private var mapLayer: some View {
        SizedMap(position: $cameraPosition) {
            UserAnnotation()

            ForEach(spotStore.nearbyActiveSpots) { spot in
                Annotation(spot.statusLabel(for: spotStore.currentUser.id), coordinate: spot.coordinate) {
                    Button {
                        if spot.createdBy != spotStore.currentUser.id && spot.claimedBy != spotStore.currentUser.id {
                            onSelectSpot(spot)
                        } else {
                            spotStore.activeHandoffID = spot.id
                        }
                    } label: {
                        SpotPinView(signal: spot)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .ignoresSafeArea()
    }

    private var overlayGradient: some View {
        LinearGradient(
            colors: [.clear, Color.black.opacity(0.16), Color.black.opacity(0.42)],
            startPoint: .center,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 16) {
            headerCard
            Spacer()
            nearbySheet
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var headerCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SpotRelay")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Pass the spot. Skip the stress.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            Text("Downtown")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.14), in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var nearbySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nearby handoffs")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(spotStore.nearbyActiveSpots.isEmpty ? "Nothing nearby yet" : "Live signals updating around you")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()
            }

            if spotStore.nearbyActiveSpots.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Be the first to share your spot")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("The fastest way to make the network useful is to seed the first handoff.")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SpotRelayTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ForEach(spotStore.nearbyActiveSpots.prefix(3)) { signal in
                    NearbySpotRow(signal: signal) {
                        if signal.createdBy != spotStore.currentUser.id && signal.claimedBy != spotStore.currentUser.id {
                            onSelectSpot(signal)
                        } else {
                            spotStore.activeHandoffID = signal.id
                        }
                    }
                }
            }

            Button(action: onLeaveSoon) {
                HStack {
                    Image(systemName: "arrowshape.turn.up.right.circle.fill")
                    Text("Leaving Soon")
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .foregroundStyle(.white)
            }
        }
        .padding(18)
        .background(SpotRelayTheme.panel, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func focusMap() {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: spotStore.userCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            )
        )
    }
}

private struct SpotPinView: View {
    let signal: ParkingSpotSignal

    var body: some View {
        VStack(spacing: 4) {
            Text(signal.isActive ? signal.status.rawValue.capitalized : "Closed")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white, in: Capsule())
                .foregroundStyle(pinColor)

            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white, pinColor)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
        }
    }

    private var pinColor: Color {
        switch signal.status {
        case .posted:
            return SpotRelayTheme.success
        case .claimed, .arriving:
            return SpotRelayTheme.warning
        case .completed, .expired, .cancelled:
            return SpotRelayTheme.textSecondary
        }
    }
}

private struct NearbySpotRow: View {
    @EnvironmentObject private var spotStore: SpotStore
    let signal: ParkingSpotSignal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(signal.minutesRemainingText) • \(signal.distanceMeters(from: spotStore.userCoordinate))m away")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(signal.statusLabel(for: spotStore.currentUser.id))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }
            .padding(16)
            .background(SpotRelayTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch signal.status {
        case .posted:
            return SpotRelayTheme.success
        case .claimed, .arriving:
            return SpotRelayTheme.warning
        case .completed, .expired, .cancelled:
            return SpotRelayTheme.textSecondary
        }
    }
}

struct SpotDetailSheet: View {
    @EnvironmentObject private var spotStore: SpotStore
    let spot: ParkingSpotSignal
    let onClaim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(SpotRelayTheme.textSecondary.opacity(0.2))
                .frame(width: 42, height: 5)
                .frame(maxWidth: .infinity)

            Text("Spot available")
                .font(.title2.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            HStack(spacing: 12) {
                detailChip(title: spot.minutesRemainingText, subtitle: "remaining")
                detailChip(title: "\(spot.distanceMeters(from: spotStore.userCoordinate))m", subtitle: "away")
                detailChip(title: "Live", subtitle: spot.statusLabel(for: spotStore.currentUser.id))
            }

            Text("Claiming locks the spot for you and updates the leaving driver instantly.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            Button(action: onClaim) {
                Text("Claim Spot")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SpotRelayTheme.success, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .background(SpotRelayTheme.background)
    }

    private func detailChip(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(SpotRelayTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpotRelayTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension ParkingSpotSignal {
    var minutesRemainingText: String {
        let seconds = max(Int(leavingAt.timeIntervalSinceNow.rounded()), 0)
        let minutes = max(Int(ceil(Double(seconds) / 60)), 0)
        return "\(minutes) min"
    }
}
