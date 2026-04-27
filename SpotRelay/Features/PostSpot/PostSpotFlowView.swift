import MapKit
import SwiftUI
import Combine

struct PostSpotFlowView: View {
    private enum ShareSource: String {
        case parked
        case current

        var title: String {
            switch self {
            case .parked:
                return L10n.tr("Parked spot")
            case .current:
                return L10n.tr("Current location")
            }
        }

        var systemImage: String {
            switch self {
            case .parked:
                return "parkingsign.circle.fill"
            case .current:
                return "location.fill"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var parkingReminderStore: ParkingReminderStore
    @State private var selectedMinutes = 2
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pendingRecenterOnLocationUpdate = true
    @State private var isMapVisible = true
    @State private var selectedShareSource: ShareSource = .parked

    private let durations = [2, 5, 10]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topHandle
                durationPicker
                //locationPreview
                shareButton
                Spacer(minLength: 0)
            }
            .padding(20)
            .task {
                syncSelectedShareSource()
                spotStore.prepareLocationTracking(requestIfNeeded: false)
                focusOnShareLocation(animated: false)
            }
        }
        .onReceive(spotStore.$userCoordinate.dropFirst()) { _ in
            syncSelectedShareSource()
            guard pendingRecenterOnLocationUpdate else { return }
            focusOnShareLocation(animated: true)
            pendingRecenterOnLocationUpdate = false
        }
        .onReceive(parkingReminderStore.$savedParkedLocation.dropFirst()) { _ in
            syncSelectedShareSource()
            focusOnShareLocation(animated: true)
        }
        .spotRelayErrorBanner(using: spotStore)
        .onDisappear {
            isMapVisible = false
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
        VStack(alignment: .leading, spacing: 18) {
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

            if shouldShowShareSourcePicker {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Share from")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    HStack(spacing: 12) {
                        shareSourceButton(.parked)
                        shareSourceButton(.current)
                    }
                }
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 28, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 16, shadowY: 8)
    }

    private var shareCoordinate: CLLocationCoordinate2D? {
        switch activeShareSource {
        case .parked:
            return parkingReminderStore.savedParkedLocation?.coordinate
        case .current:
            return spotStore.userCoordinate
        }
    }

    private var isUsingParkedLocation: Bool {
        activeShareSource == .parked
    }

    private var shouldShowShareSourcePicker: Bool {
        parkingReminderStore.savedParkedLocation != nil
    }

    private var activeShareSource: ShareSource {
        if parkingReminderStore.savedParkedLocation == nil {
            return .current
        }

        if selectedShareSource == .current {
            return .current
        }

        return .parked
    }

    private func shareSourceButton(_ source: ShareSource) -> some View {
        Button {
            selectedShareSource = source
            if source == .current {
                pendingRecenterOnLocationUpdate = true
                spotStore.prepareLocationTracking(requestIfNeeded: true)
            }
            focusOnShareLocation(animated: true)
        } label: {
            let isSelected = activeShareSource == source
            let isCurrentWaiting = source == .current && spotStore.userCoordinate == nil
            let fillStyle = isSelected ? AnyShapeStyle(SpotRelayTheme.heroGradient) : AnyShapeStyle(SpotRelayTheme.badgeFill)

            HStack(spacing: 9) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 15, weight: .bold))

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if isCurrentWaiting {
                        Text(L10n.tr("Locating"))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .padding(.horizontal, 14)
            .background(fillStyle, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .foregroundStyle(isSelected ? .white : SpotRelayTheme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private var locationPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isUsingParkedLocation ? L10n.tr("Sharing from parked car") : L10n.tr("Sharing from live location"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(isUsingParkedLocation
                         ? L10n.tr("Your saved parked location will be shared, which is usually more precise than your live position.")
                         : L10n.tr("The handoff will publish from your current live location."))
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text(shareCoordinate == nil ? L10n.tr("Waiting") : (isUsingParkedLocation ? L10n.tr("Parked") : L10n.tr("Live")))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }

            if shareCoordinate == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("We’ll use your parked location when smart parking saves one, or your live position once it’s available."))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)

                    Button {
                        pendingRecenterOnLocationUpdate = true
                        spotStore.prepareLocationTracking(requestIfNeeded: true)
                    } label: {
                        HStack {
                            Image(systemName: "location.fill")
                            Text(L10n.tr("Enable Current Location"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.primary)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            } else {
                ZStack(alignment: .topTrailing) {
                    if isMapVisible {
                        SizedMap(position: $cameraPosition) {
                            if spotStore.userCoordinate != nil {
                                UserAnnotation()
                            }

                            if let parkedLocation = parkingReminderStore.savedParkedLocation {
                                Annotation("Parked car", coordinate: parkedLocation.coordinate) {
                                    ParkedLocationBadgePin()
                                }
                            }
                        }
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .mapStyle(.standard(elevation: .flat))
                    } else {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(SpotRelayTheme.surface)
                            .frame(height: 190)
                    }

                    MapRecenterButton {
                        pendingRecenterOnLocationUpdate = true
                        spotStore.prepareLocationTracking(requestIfNeeded: true)
                        focusOnShareLocation(animated: true)
                    }
                    .padding(14)
                }

                if isUsingParkedLocation, let parkedLocation = parkingReminderStore.savedParkedLocation {
                    HStack(spacing: 10) {
                        Label("Parked pin saved", systemImage: "parkingsign.circle.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(SpotRelayTheme.badgeFill, in: Capsule())
                            .foregroundStyle(SpotRelayTheme.badgeText)

                        if let userCoordinate = spotStore.userCoordinate {
                            Text(L10n.format("%@ from you", parkedLocation.coordinateDistanceText(from: userCoordinate)))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(SpotRelayTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .glassPanel(cornerRadius: 28, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 16, shadowY: 8)
    }

    private var shareButton: some View {
        Button {
            Task {
                if await spotStore.postSpot(durationMinutes: selectedMinutes, coordinateOverride: shareCoordinate) {
                    await parkingReminderStore.clearReminder()
                    dismissSafely()
                }
            }
        } label: {
            HStack {
                Image(systemName: shareCoordinate == nil ? "location.fill" : (isUsingParkedLocation ? "parkingsign.circle.fill" : "arrowshape.turn.up.right.circle.fill"))
                Text(shareCoordinate == nil ? L10n.tr("Waiting for Location") : (isUsingParkedLocation ? L10n.tr("Share Parked Spot") : L10n.tr("Share Current Location")))
            }
            .font(.headline.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(shareCoordinate == nil)
        .opacity(shareCoordinate == nil ? 0.6 : 1)
        .shadow(color: SpotRelayTheme.shadow, radius: 18, y: 10)
    }

    private func focusOnShareLocation(animated: Bool) {
        guard let coordinate = shareCoordinate else {
            setCameraPosition(.automatic, animated: animated)
            return
        }
        setCameraPosition(
            .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
            ),
            animated: animated
        )
    }

    private func dismissSafely() {
        isMapVisible = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            dismiss()
        }
    }

    private func setCameraPosition(_ position: MapCameraPosition, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = position
            }
        } else {
            cameraPosition = position
        }
    }

    private func syncSelectedShareSource() {
        if parkingReminderStore.savedParkedLocation != nil {
            return
        }

        selectedShareSource = .current
    }
}

private struct ParkedLocationBadgePin: View {
    var body: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("Parked"))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(SpotRelayTheme.chrome, in: Capsule())
                .foregroundStyle(SpotRelayTheme.success)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.chrome)
                    .frame(width: 18, height: 18)

                Image(systemName: "car.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, SpotRelayTheme.success)
            }
            .shadow(color: SpotRelayTheme.shadow, radius: 10, y: 6)
        }
    }
}
