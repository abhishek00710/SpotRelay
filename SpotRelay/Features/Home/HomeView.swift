import MapKit
import SwiftUI
import Combine
import UserNotifications

struct HomeView: View {
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var pushNotificationStore: PushNotificationStore
    @EnvironmentObject private var parkingReminderStore: ParkingReminderStore
    @EnvironmentObject private var smartParkingStore: SmartParkingStore
    let onLeaveSoon: () -> Void
    let onSelectSpot: (ParkingSpotSignal) -> Void
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var pendingRecenterOnLocationUpdate = true
    @State private var isNearbySheetExpanded = false
    @State private var parkingReminderAlert: HomeViewAlert?

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            overlayGradient
            content
        }
        .background(SpotRelayTheme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .spotRelayErrorBanner(using: spotStore)
        .task {
            spotStore.prepareLocationTracking(requestIfNeeded: false)
            focusMap(animated: false)
        }
        .task {
            await spotStore.runRefreshLoop()
        }
        .onReceive(spotStore.$userCoordinate.dropFirst()) { _ in
            guard pendingRecenterOnLocationUpdate else { return }
            focusMap(animated: true)
            pendingRecenterOnLocationUpdate = false
        }
        .alert(item: $parkingReminderAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
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
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .ignoresSafeArea()
        .simultaneousGesture(
            TapGesture().onEnded {
                collapseNearbySheetIfNeeded()
            }
        )
    }

    private var overlayGradient: some View {
        ZStack {
            LinearGradient(
                colors: [.clear, SpotRelayTheme.mapOverlayMid, SpotRelayTheme.mapOverlayBottom],
                startPoint: .center,
                endPoint: .bottom
            )

            SpotRelayTheme.mapGlow
                .blendMode(.plusLighter)
                .opacity(0.9)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(spacing: 16) {
            headerCard
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    MapRecenterButton {
                        recenterOnUser()
                    }
                }

                if shouldShowSmartParkingButton {
                    HStack {
                        Spacer()
                        smartParkingButton
                    }
                }
            }
            .padding(.horizontal, 4)
            Spacer()
            nearbySheetContainer
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var smartParkingButton: some View {
        Button {
            Task {
                await handleSmartParkingTap()
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .glassPanel(
            cornerRadius: 18,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
        .accessibilityLabel("Set up smart parking")
    }

    private var shouldShowSmartParkingButton: Bool {
        switch smartParkingStore.status {
        case .disabled, .needsAlwaysLocation, .needsMotionAccess:
            return true
        case .monitoring, .unsupported:
            return false
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live city parking")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(SpotRelayTheme.badgeText)

                Text("SpotRelay")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("Pass the spot. Skip the stress.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                Text(spotStore.userCoordinate == nil ? "Locating..." : spotStore.currentAreaLabel)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)

                if pushNotificationStore.isAuthorizedForNotifications {
                    ZStack {
                        Circle()
                            .fill(SpotRelayTheme.orbGradient)
                            .frame(width: 44, height: 44)
                            .blur(radius: 0.5)

                        Image(systemName: "arrow.trianglehead.swap")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Button {
                        if pushNotificationStore.authorizationStatus == .denied {
                            pushNotificationStore.openSystemSettings()
                        } else {
                            Task {
                                _ = await pushNotificationStore.requestAuthorization()
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(SpotRelayTheme.orbGradient)
                                .frame(width: 44, height: 44)
                                .blur(radius: 0.5)

                            Image(systemName: pushNotificationStore.authorizationStatus == .denied ? "bell.slash.fill" : "bell.badge.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 30,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 24,
            shadowY: 12
        )
    }

    private var nearbySheetContainer: some View {
        nearbySheet
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isNearbySheetExpanded)
    }

    private var nearbySheet: some View {
        VStack(alignment: .leading, spacing: isNearbySheetExpanded ? 16 : 12) {
            grabber

            HStack(spacing: 14) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SpotRelayTheme.primary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Nearby handoffs")
                        .font(isNearbySheetExpanded ? .title3.weight(.bold) : .headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(isNearbySheetExpanded ? sheetSubtitle : collapsedSubtitle)
                        .font(isNearbySheetExpanded ? .subheadline : .caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer(minLength: 0)

                if spotStore.userCoordinate != nil {
                    Text("\(groupedHandoffCount)")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SpotRelayTheme.badgeFill, in: Capsule())
                        .foregroundStyle(SpotRelayTheme.badgeText)
                }

                Button {
                    toggleNearbySheet()
                } label: {
                    Image(systemName: isNearbySheetExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(SpotRelayTheme.badgeFill, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isNearbySheetExpanded else { return }
                expandNearbySheet()
            }

            expandedSheetBody
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, isNearbySheetExpanded ? 18 : 16)
        .glassPanel(
            cornerRadius: isNearbySheetExpanded ? 32 : 26,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: isNearbySheetExpanded ? 28 : 22,
            shadowY: 12
        )
    }

    private var expandedSheetBody: some View {
        Group {
            if isNearbySheetExpanded {
                ViewThatFits(in: .vertical) {
                    expandedSheetInlineContent

                    ScrollView(showsIndicators: false) {
                        expandedSheetContent
                    }
                }
            }
        }
        .frame(maxHeight: isNearbySheetExpanded ? expandedSheetHeightLimit : 0, alignment: .top)
        .opacity(isNearbySheetExpanded ? 1 : 0)
        .allowsHitTesting(isNearbySheetExpanded)
        .clipped()
    }

    private var expandedSheetInlineContent: some View {
        expandedSheetContent
            .fixedSize(horizontal: false, vertical: true)
    }

    private var expandedSheetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let reminder = parkingReminderStore.activeReminder {
                parkingReminderCard(reminder)
            }

            if spotStore.userCoordinate == nil {
                locationPendingCard
            } else {
                handoffSection(
                    title: "Handoff claims",
                    subtitle: "Trying to get a parking",
                    icon: "parkingsign.circle.fill",
                    signals: claimSectionSignals,
                    emptyTitle: "Nothing to claim yet",
                    emptySubtitle: "Nearby posted spots and your active claims will appear here.",
                    rowMode: .claim
                ) { signal in
                    if signal.claimedBy == spotStore.currentUser.id {
                        spotStore.activeHandoffID = signal.id
                    } else {
                        onSelectSpot(signal)
                    }
                }

                if !locationSectionSignals.isEmpty {
                    handoffSection(
                        title: "Handoff location",
                        subtitle: "Trying to give away my parking",
                        icon: "location.circle.fill",
                        signals: locationSectionSignals,
                        emptyTitle: "No live handoff location",
                        emptySubtitle: "When you post a leaving timer, your own handoff will show up here.",
                        rowMode: .location
                    ) { signal in
                        spotStore.activeHandoffID = signal.id
                    }
                }
            }

            if locationSectionSignals.isEmpty {
                Button(action: primaryButtonAction) {
                    HStack {
                        Image(systemName: primaryButtonIconName)
                        Text(primaryButtonTitle)
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .foregroundStyle(.white)
                }
                .shadow(color: SpotRelayTheme.shadow, radius: 18, y: 10)
            }
        }
    }

    private var grabber: some View {
        Capsule()
            .fill(SpotRelayTheme.textSecondary.opacity(0.28))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private func parkingReminderCard(_ reminder: ParkingReminderStore.Reminder) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(SpotRelayTheme.success.opacity(0.14))
                        .frame(width: 40, height: 40)

                    Image(systemName: "car.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SpotRelayTheme.success)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Leaving reminder on")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(reminder.areaSummary)
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Text("\(Int(reminder.radiusMeters))m radius")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)

                Spacer(minLength: 0)

                Button {
                    Task {
                        await parkingReminderStore.clearReminder()
                    }
                } label: {
                    Text("Clear")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.warning)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: 24,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private func focusMap(animated: Bool) {
        guard let coordinate = spotStore.userCoordinate else {
            setCameraPosition(.automatic, animated: animated)
            return
        }
        setCameraPosition(
            .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
            )
            ),
            animated: animated
        )
    }

    private var sheetSubtitle: String {
        if spotStore.userCoordinate == nil {
            return "We’ll show live handoffs as soon as we have your current location."
        }
        if groupedHandoffCount == 0 {
            return "Nothing active within 500m yet"
        }
        if !claimSectionSignals.isEmpty && !locationSectionSignals.isEmpty {
            return "Claims and your live handoff grouped together"
        }
        if !claimSectionSignals.isEmpty {
            return "Nearby spots"
        }
        return "Your live handoff location is active"
    }

    private var collapsedSubtitle: String {
        if spotStore.userCoordinate == nil {
            return "Tap to enable your location"
        }
        if groupedHandoffCount == 0 {
            return "No live handoffs within 500m"
        }
        if !claimSectionSignals.isEmpty && !locationSectionSignals.isEmpty {
            return "\(claimSectionSignals.count) claims • \(locationSectionSignals.count) locations"
        }
        if !claimSectionSignals.isEmpty {
            return claimSectionSignals.count == 1 ? "1 handoff claim" : "\(claimSectionSignals.count) handoff claims"
        }
        return locationSectionSignals.count == 1 ? "1 handoff location" : "\(locationSectionSignals.count) handoff locations"
    }

    private var locationPendingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finding your current location")
                .font(.headline.weight(.semibold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Location is required to center the map, sort nearby handoffs, and post your spot accurately.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 24, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 14, shadowY: 8)
    }

    private var primaryButtonAction: () -> Void {
        {
            if spotStore.userCoordinate == nil {
                recenterOnUser()
            } else if let leavingSignal = spotStore.currentUserLeavingSignal {
                spotStore.activeHandoffID = leavingSignal.id
            } else {
                onLeaveSoon()
            }
        }
    }

    private var expandedSheetHeightLimit: CGFloat {
        420
    }

    private var primaryButtonTitle: String {
        if spotStore.userCoordinate == nil {
            return "Use Current Location"
        }
        if spotStore.currentUserLeavingSignal != nil {
            return "View My Live Handoff"
        }
        return "Leaving Soon"
    }

    private var primaryButtonIconName: String {
        if spotStore.userCoordinate == nil {
            return "location.fill"
        }
        if spotStore.currentUserLeavingSignal != nil {
            return "timer"
        }
        return "arrowshape.turn.up.right.circle.fill"
    }

    private func recenterOnUser() {
        pendingRecenterOnLocationUpdate = true
        spotStore.prepareLocationTracking(requestIfNeeded: true)
        focusMap(animated: true)
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

    private func toggleNearbySheet() {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isNearbySheetExpanded.toggle()
            }
        }
    }

    private func expandNearbySheet() {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isNearbySheetExpanded = true
            }
        }
    }

    private func collapseNearbySheetIfNeeded() {
        guard isNearbySheetExpanded else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                isNearbySheetExpanded = false
            }
        }
    }

    private var claimSectionSignals: [ParkingSpotSignal] {
        let claimedByYou = sortedSignals(
            spotStore.spots.filter { $0.isActive && $0.claimedBy == spotStore.currentUser.id }
        )
        let claimedIDs = Set(claimedByYou.map(\.id))
        let nearbyClaimable = sortedSignals(
            spotStore.nearbyActiveSpots.filter {
                $0.createdBy != spotStore.currentUser.id &&
                $0.status == .posted &&
                !claimedIDs.contains($0.id)
            }
        )
        return claimedByYou + nearbyClaimable
    }

    private var locationSectionSignals: [ParkingSpotSignal] {
        sortedSignals(
            spotStore.spots.filter { $0.isActive && $0.createdBy == spotStore.currentUser.id }
        )
    }

    private var groupedHandoffCount: Int {
        claimSectionSignals.count + locationSectionSignals.count
    }

    private func sortedSignals(_ signals: [ParkingSpotSignal]) -> [ParkingSpotSignal] {
        signals.sorted { lhs, rhs in
            if let userCoordinate = spotStore.userCoordinate {
                let leftDistance = lhs.distanceMeters(from: userCoordinate)
                let rightDistance = rhs.distanceMeters(from: userCoordinate)
                if leftDistance != rightDistance {
                    return leftDistance < rightDistance
                }
            }

            if lhs.leavingAt != rhs.leavingAt {
                return lhs.leavingAt < rhs.leavingAt
            }

            return lhs.createdAt > rhs.createdAt
        }
    }

    private func handleSmartParkingTap() async {
        if smartParkingStore.status == .monitoring {
            smartParkingStore.disable()
            return
        }

        let notificationsReady: Bool
        switch pushNotificationStore.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsReady = true
        case .notDetermined:
            notificationsReady = await pushNotificationStore.requestAuthorization()
        case .denied:
            notificationsReady = false
            parkingReminderAlert = HomeViewAlert(
                title: "Notifications are off",
                message: "Turn notifications on so SpotRelay can alert you when you're back near your parked car."
            )
        @unknown default:
            notificationsReady = false
        }

        guard notificationsReady else { return }

        await smartParkingStore.enable()
        smartParkingStore.refreshPermissions()

        switch smartParkingStore.status {
        case .monitoring:
            parkingReminderAlert = HomeViewAlert(
                title: "Smart parking is on",
                message: "SpotRelay will now look for likely parking stops and arm a return reminder automatically."
            )
        case .needsAlwaysLocation:
            parkingReminderAlert = HomeViewAlert(
                title: "Finish location setup",
                message: "Choose Always Allow for SpotRelay so smart parking can keep working even when the app isn't open."
            )
        case .needsMotionAccess:
            parkingReminderAlert = HomeViewAlert(
                title: "Motion access needed",
                message: "Allow Motion & Fitness for SpotRelay so it can tell when a drive has likely ended."
            )
        case .unsupported:
            parkingReminderAlert = HomeViewAlert(
                title: "Smart parking unavailable",
                message: "This device doesn't expose the motion signals SpotRelay needs for automatic parked-spot detection."
            )
        case .disabled:
            break
        }
    }

    private func handoffSection(
        title: String,
        subtitle: String,
        icon: String,
        signals: [ParkingSpotSignal],
        emptyTitle: String,
        emptySubtitle: String,
        rowMode: NearbySpotRowMode,
        action: @escaping (ParkingSpotSignal) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SpotRelayTheme.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text("\(signals.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }

            if signals.isEmpty {
                sectionEmptyState(title: emptyTitle, subtitle: emptySubtitle)
            } else {
                ForEach(signals.prefix(3)) { signal in
                    NearbySpotRow(signal: signal, mode: rowMode, action: {
                        action(signal)
                    })
                }
            }
        }
    }

    private func sectionEmptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(
            cornerRadius: 22,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 12,
            shadowY: 6
        )
    }
}

private struct HomeViewAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SpotPinView: View {
    let signal: ParkingSpotSignal

    var body: some View {
        VStack(spacing: 6) {
            Text(signal.isActive ? signal.status.rawValue.capitalized : "Closed")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(SpotRelayTheme.chrome, in: Capsule())
                .foregroundStyle(pinColor)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.chrome)
                    .frame(width: 18, height: 18)

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, pinColor)
            }
            .shadow(color: SpotRelayTheme.shadow, radius: 10, y: 6)
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
    let mode: NearbySpotRowMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.14))
                        .frame(width: 42, height: 42)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(signal.minutesRemainingText) • \(signal.distanceText(from: spotStore.userCoordinate))")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(signal.statusLabel(for: spotStore.currentUser.id))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text(badgeTitle)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }
            .padding(16)
            .glassPanel(cornerRadius: 24, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 14, shadowY: 8)
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

    private var badgeTitle: String {
        switch mode {
        case .claim:
            return signal.claimedBy == spotStore.currentUser.id ? "Claimed" : "Open"
        case .location:
            switch signal.status {
            case .posted:
                return "Live"
            case .claimed, .arriving:
                return "Claimed"
            case .completed:
                return "Done"
            case .expired:
                return "Expired"
            case .cancelled:
                return "Cancelled"
            }
        }
    }
}

private enum NearbySpotRowMode {
    case claim
    case location
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Spot available")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("This handoff is still open right now. Claim it and the leaving driver will see you immediately.")
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }

            HStack(spacing: 12) {
                detailChip(title: spot.minutesRemainingText, subtitle: "remaining")
                detailChip(title: spot.distanceValue(from: spotStore.userCoordinate), subtitle: "away")
                detailChip(title: "Live", subtitle: spot.statusLabel(for: spotStore.currentUser.id))
            }

            Button(action: onClaim) {
                HStack {
                    Image(systemName: "arrowshape.turn.up.right.circle.fill")
                    Text("Claim Spot")
                }
                .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SpotRelayTheme.success, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .spotRelayErrorBanner(using: spotStore)
        //.background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
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
        .glassPanel(cornerRadius: 20, tint: SpotRelayTheme.glassTint, stroke: SpotRelayTheme.softStroke, shadow: SpotRelayTheme.rowShadow, shadowRadius: 10, shadowY: 6)
    }
}

extension ParkingSpotSignal {
    var minutesRemainingText: String {
        let seconds = max(Int(leavingAt.timeIntervalSinceNow.rounded()), 0)
        let minutes = max(Int(ceil(Double(seconds) / 60)), 0)
        return "\(minutes) min"
    }
}
