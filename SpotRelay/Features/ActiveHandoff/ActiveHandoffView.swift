import MapKit
import SwiftUI
import Combine
import UIKit

struct ActiveHandoffView: View {
    @EnvironmentObject private var spotStore: SpotStore
    let signal: ParkingSpotSignal
    let onClose: () -> Void
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pendingRecenterOnLocationUpdate = false
    @State private var isMapVisible = true
    @State private var isShowingDirectionsOptions = false

    private var liveSignal: ParkingSpotSignal {
        spotStore.activeHandoff ?? signal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    counterpartyPanel
                    //liveMap
                    actionPanel
                    statusPanel
                }
                .padding(20)
            }
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
//            .toolbar {
//                ToolbarItem(placement: .topBarTrailing) {
//                    Button("Close") {
//                        dismissSafely {
//                            onClose()
//                        }
//                    }
//                }
//            }
            .task {
                spotStore.prepareLocationTracking(requestIfNeeded: false)
                setCameraPosition(
                    .region(
                    MKCoordinateRegion(
                        center: liveSignal.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                    )
                    ),
                    animated: false
                )
            }
            .task {
                await spotStore.runRefreshLoop()
            }
            .onReceive(spotStore.$userCoordinate.dropFirst()) { _ in
                guard pendingRecenterOnLocationUpdate else { return }
                recenterOnUser(animated: true)
                pendingRecenterOnLocationUpdate = false
            }
            .onChange(of: spotStore.activeHandoffID) { _, newValue in
                if newValue == nil {
                    isMapVisible = false
                }
            }
            .onDisappear {
                isMapVisible = false
            }
            .sheet(isPresented: $isShowingDirectionsOptions) {
                directionsSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .spotRelayErrorBanner(using: spotStore)
        }
    }

    private var counterpartyPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(approachAccent.opacity(0.16))
                        .frame(width: 48, height: 48)

                    Image(systemName: panelSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(approachAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(panelTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(panelSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                detailPill(title: "Driver", value: counterpartyName)
                detailPill(title: "Stage", value: approachStageTitle)
            }

            Text(approachStageDetail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SpotRelayTheme.textSecondary)
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
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
                if isMapVisible {
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
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(SpotRelayTheme.surface)
                        .frame(height: 220)
                }

                MapRecenterButton {
                    pendingRecenterOnLocationUpdate = true
                    spotStore.prepareLocationTracking(requestIfNeeded: true)
                    recenterOnUser(animated: true)
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
                    isShowingDirectionsOptions = true
                } label: {
                    secondaryActionButton(title: "Directions", icon: "arrow.triangle.turn.up.right.diamond.fill", color: SpotRelayTheme.primary)
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        _ = await spotStore.markArrival()
                    }
                } label: {
                    actionButtonLabel(title: "I'm Here", color: SpotRelayTheme.success)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    if await spotStore.cancelActiveHandoff() {
                        dismissSafely {
                            onClose()
                        }
                    }
                }
            } label: {
                actionButtonLabel(title: "Cancel", color: SpotRelayTheme.warning)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button {
                    Task {
                        if await spotStore.completeActiveHandoff(success: true) {
                            dismissSafely {
                                onClose()
                            }
                        }
                    }
                } label: {
                    completionButton(title: "Yes", icon: "hand.thumbsup.fill", color: SpotRelayTheme.success)
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        if await spotStore.completeActiveHandoff(success: false) {
                            dismissSafely {
                                onClose()
                            }
                        }
                    }
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
            statusLine("Distance", value: liveSignal.distanceText(from: spotStore.userCoordinate))
            statusLine("Countdown", value: liveSignal.minutesRemainingText)
        }
        .padding(20)
        .glassPanel(cornerRadius: 26, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 12, shadowY: 6)
    }

    private var directionsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open directions")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("Choose how you want to navigate to the claimed handoff spot.")
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }

            Button {
                dismissDirectionsSheet {
                    openAppleMapsDirections()
                }
            } label: {
                directionOptionButton(title: "Apple Maps", icon: "map.fill", color: SpotRelayTheme.primary)
            }
            .buttonStyle(.plain)

            Button {
                dismissDirectionsSheet {
                    openGoogleMapsDirections()
                }
            } label: {
                directionOptionButton(title: "Google Maps", icon: "arrow.triangle.turn.up.right.diamond.fill", color: SpotRelayTheme.success)
            }
            .buttonStyle(.plain)

            Button {
                isShowingDirectionsOptions = false
            } label: {
                directionOptionButton(title: "Cancel", icon: "xmark", color: SpotRelayTheme.warning)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
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
            return "Stay visible while the claimant closes the gap."
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

    private func secondaryActionButton(title: String, icon: String, color: Color) -> some View {
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

    private func directionOptionButton(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.bold))

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
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

    private func detailPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SpotRelayTheme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func openAppleMapsDirections() {
        let destination = MKMapItem(
            location: CLLocation(
                latitude: liveSignal.coordinate.latitude,
                longitude: liveSignal.coordinate.longitude
            ),
            address: nil
        )
        destination.name = "SpotRelay Handoff Spot"

        let launchOptions = [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ]

        if let userCoordinate = spotStore.userCoordinate {
            let source = MKMapItem(
                location: CLLocation(
                    latitude: userCoordinate.latitude,
                    longitude: userCoordinate.longitude
                ),
                address: nil
            )
            source.name = "Current Location"
            MKMapItem.openMaps(with: [source, destination], launchOptions: launchOptions)
        } else {
            destination.openInMaps(launchOptions: launchOptions)
        }
    }

    private func openGoogleMapsDirections() {
        let destinationValue = "\(liveSignal.coordinate.latitude),\(liveSignal.coordinate.longitude)"
        let originValue = spotStore.userCoordinate.map { "\($0.latitude),\($0.longitude)" }

        let appURLString: String
        if let originValue {
            appURLString = "comgooglemaps://?saddr=\(originValue)&daddr=\(destinationValue)&directionsmode=driving"
        } else {
            appURLString = "comgooglemaps://?daddr=\(destinationValue)&directionsmode=driving"
        }

        let fallbackURL = googleMapsWebURL(destination: destinationValue, origin: originValue)

        guard let appURL = URL(string: appURLString) else {
            UIApplication.shared.open(fallbackURL)
            return
        }

        UIApplication.shared.open(appURL, options: [:]) { success in
            guard !success else { return }
            UIApplication.shared.open(fallbackURL)
        }
    }

    private func googleMapsWebURL(destination: String, origin: String?) -> URL {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        var queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "travelmode", value: "driving")
        ]

        if let origin {
            queryItems.append(URLQueryItem(name: "origin", value: origin))
        }

        components.queryItems = queryItems
        return components.url!
    }

    private func dismissDirectionsSheet(then action: @escaping () -> Void) {
        isShowingDirectionsOptions = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    private var counterpartyName: String {
        switch spotStore.currentUserRole {
        case .leaving:
            return spotStore.displayName(for: liveSignal.claimedBy) ?? "Waiting for claim"
        case .arriving:
            return spotStore.displayName(for: liveSignal.createdBy) ?? "Leaving driver"
        case .none:
            return spotStore.displayName(for: liveSignal.claimedBy) ?? "Nearby driver"
        }
    }

    private var panelTitle: String {
        switch spotStore.currentUserRole {
        case .leaving:
            return liveSignal.claimedBy == nil ? "Waiting for someone to claim" : "Someone claimed your spot"
        case .arriving:
            return "The leaving driver can see you"
        case .none:
            return "Live handoff confidence"
        }
    }

    private var panelSubtitle: String {
        switch spotStore.currentUserRole {
        case .leaving:
            return liveSignal.claimedBy == nil
                ? "You’ll see the claimant here the moment another driver commits."
                : "Clear claimant identity and arrival stage make the handoff feel safer."
        case .arriving:
            return "Keep your status updated so the other driver trusts the handoff."
        case .none:
            return "Identity and approach stage reduce uncertainty for both drivers."
        }
    }

    private var approachStageTitle: String {
        switch liveSignal.status {
        case .posted:
            return "Waiting"
        case .claimed:
            return spotStore.currentUserRole == .leaving ? "Claimed" : "On the way"
        case .arriving:
            return "Arriving"
        case .completed:
            return "Complete"
        case .expired:
            return "Expired"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var approachStageDetail: String {
        switch liveSignal.status {
        case .posted:
            return "No driver has committed yet, so the spot is still open."
        case .claimed:
            if spotStore.currentUserRole == .leaving {
                return "A nearby driver has claimed the spot. Once they update their arrival state, you’ll see that here immediately."
            } else {
                return "Your claim is live. The leaving driver now knows you’re coming."
            }
        case .arriving:
            return "Arrival has been marked, so both sides have a clearer handoff moment."
        case .completed:
            return "The handoff is complete."
        case .expired:
            return "The countdown ran out before the handoff completed."
        case .cancelled:
            return "This handoff was cancelled."
        }
    }

    private var panelSymbol: String {
        switch liveSignal.status {
        case .posted:
            return "hourglass"
        case .claimed:
            return "person.crop.circle.badge.checkmark"
        case .arriving:
            return "location.fill.viewfinder"
        case .completed:
            return "checkmark.circle.fill"
        case .expired:
            return "clock.badge.xmark.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    private var approachAccent: Color {
        switch liveSignal.status {
        case .posted:
            return SpotRelayTheme.primary
        case .claimed, .arriving:
            return SpotRelayTheme.success
        case .completed:
            return SpotRelayTheme.success
        case .expired, .cancelled:
            return SpotRelayTheme.warning
        }
    }

    private func recenterOnUser(animated: Bool) {
        guard let coordinate = spotStore.userCoordinate else {
            setCameraPosition(
                .region(
                MKCoordinateRegion(
                    center: liveSignal.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                )
                ),
                animated: animated
            )
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

    private func dismissSafely(action: @escaping () -> Void) {
        isMapVisible = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            action()
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
}
