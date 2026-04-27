import MapKit
import SwiftUI
import Combine
import UserNotifications
import UIKit

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
    @State private var isShowingParkedLocationSheet = false
    @State private var isShowingProfileSheet = false
    @State private var parkingReminderAlert: HomeViewAlert?
    @State private var nearbySheetHeaderHeight: CGFloat = 0
    @State private var expandedSheetContentHeight: CGFloat = 0
    @State private var parkedLocationToastMessage: String?
    @GestureState private var nearbySheetDragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
            overlayGradient
            content
            if let parkedLocationToastMessage {
                parkedLocationToast(message: parkedLocationToastMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(nearbySheetRenderedBottomInset + 18, 120))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
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
        .sheet(isPresented: $isShowingParkedLocationSheet) {
            if let parkedLocation = parkingReminderStore.savedParkedLocation {
                ParkedLocationDetailView(initialReminder: parkedLocation)
                    .environmentObject(spotStore)
                    .environmentObject(parkingReminderStore)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $isShowingProfileSheet) {
            ProfileView()
                .environmentObject(spotStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var mapLayer: some View {
        SizedMap(position: $cameraPosition) {
            UserAnnotation()

            if let parkedLocation = parkingReminderStore.savedParkedLocation {
                Annotation("You parked here", coordinate: parkedLocation.coordinate) {
                    Button {
                        isShowingParkedLocationSheet = true
                    } label: {
                        ParkedCarPinView()
                    }
                    .buttonStyle(.plain)
                }
            }

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

                if parkingReminderStore.savedParkedLocation != nil {
                    HStack {
                        Spacer()
                        parkedLocationShortcutButton
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

    private var parkedLocationShortcutButton: some View {
        Button {
            focusOnSavedParkedLocation()
        } label: {
            Text("P")
                .font(.system(size: 18, weight: .bold, design: .rounded))
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
        .accessibilityLabel("Center on parked location")
    }

    private var notificationButton: some View {
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
        .accessibilityLabel("Notification settings")
    }

    private var profileButton: some View {
        Button {
            isShowingProfileSheet = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarJPEGData = spotStore.currentUser.avatarJPEGData,
                       let avatarImage = UIImage(data: avatarJPEGData) {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Circle()
                            .fill(SpotRelayTheme.orbGradient)

                        Text(spotStore.currentUser.displayInitials)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(SpotRelayTheme.softStroke, lineWidth: 1.2)
                )

                if spotStore.currentUser.shareStars > 0 {
                    HStack(spacing: 1) {
                        ForEach(0..<homeProfileStarBadgeCount, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(SpotRelayTheme.warning, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: 8, y: 6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open profile")
    }

    private var homeProfileStarBadgeCount: Int {
        switch spotStore.currentUser.shareStars {
        case 1..<10:
            return 1
        case 10..<50:
            return 2
        case 50...:
            return 3
        default:
            return 0
        }
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
                Text(spotStore.userCoordinate == nil ? L10n.tr("Locating...") : localizedAreaLabel(spotStore.currentAreaLabel))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)

                HStack(spacing: 10) {
                    if !pushNotificationStore.isAuthorizedForNotifications {
                        notificationButton
                    }
                    profileButton
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
            .offset(y: nearbySheetDragOffset)
            .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isNearbySheetExpanded)
    }

    private var nearbySheet: some View {
        VStack(alignment: .leading, spacing: isNearbySheetExpanded ? 16 : 12) {
            nearbySheetHeader

            expandedSheetBody
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, isNearbySheetExpanded ? 18 : 16)
        .frame(height: isNearbySheetExpanded ? expandedSheetRenderedTotalHeight : nil, alignment: .top)
        .clipped()
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
                if shouldUseScrollableExpandedSheet {
                    ScrollView(showsIndicators: false) {
                        measuredExpandedSheetContent
                    }
                    .frame(height: expandedSheetViewportHeight, alignment: .top)
                } else {
                    measuredExpandedSheetContent
                }
            }
        }
        .clipped()
    }

    private var nearbySheetHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NearbySheetHeaderHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(NearbySheetHeaderHeightPreferenceKey.self) { newHeight in
            let normalizedHeight = max(newHeight, 0)
            guard abs(nearbySheetHeaderHeight - normalizedHeight) > 1 else { return }
            nearbySheetHeaderHeight = normalizedHeight
        }
    }

    private var measuredExpandedSheetContent: some View {
        expandedSheetContent
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ExpandedSheetContentHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ExpandedSheetContentHeightPreferenceKey.self) { newHeight in
                let normalizedHeight = max(newHeight, 0)
                guard abs(expandedSheetContentHeight - normalizedHeight) > 1 else { return }
                expandedSheetContentHeight = normalizedHeight
            }
    }

    private var expandedSheetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if spotStore.userCoordinate == nil && parkingReminderStore.savedParkedLocation == nil {
                locationPendingCard
            } else {
                if !claimSectionSignals.isEmpty {
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
                }

                if !locationSectionSignals.isEmpty {
                    handoffSection(
                        title: "Handoff location",
                        subtitle: "Sharing my spot",
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
            .padding(.vertical, 6)
            .gesture(nearbySheetGrabberGesture)
    }

    private func parkingReminderCard(_ reminder: ParkingReminderStore.Reminder) -> some View {
        parkedLocationCard(reminder)
    }

    private func parkedLocationCard(_ reminder: ParkingReminderStore.Reminder) -> some View {
        Button {
            isShowingParkedLocationSheet = true
        } label: {
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
                        Text("Parked car saved")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(SpotRelayTheme.textPrimary)

                        Text(reminder.areaSummary)
                            .font(.subheadline)
                            .foregroundStyle(SpotRelayTheme.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    Text("\(Int(reminder.radiusMeters))m radius")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(SpotRelayTheme.badgeFill, in: Capsule())
                        .foregroundStyle(SpotRelayTheme.badgeText)

                    Text(parkingReminderStore.activeReminder != nil ? "Reminder armed" : "Ready to share")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(SpotRelayTheme.badgeFill, in: Capsule())
                        .foregroundStyle(SpotRelayTheme.badgeText)

//                    Spacer(minLength: 0)
//
//                    Text("Details")
//                        .font(.subheadline.weight(.semibold))
//                        .foregroundStyle(SpotRelayTheme.primary)
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
        .buttonStyle(.plain)
    }

    private func parkingReminderDebugCard(_ state: ParkingReminderStore.DebugState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(parkingReminderDebugTint(for: state).opacity(0.14))
                    .frame(width: 38, height: 38)

                Image(systemName: parkingReminderDebugIcon(for: state))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(parkingReminderDebugTint(for: state))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(state.detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
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
        if spotStore.userCoordinate == nil && parkingReminderStore.savedParkedLocation == nil {
            return L10n.tr("We’ll show live handoffs as soon as we have your current location.")
        }
        if spotStore.userCoordinate == nil && parkingReminderStore.savedParkedLocation != nil {
            return L10n.tr("Your parked location is saved. Nearby claims will return once live location updates.")
        }
        if groupedHandoffCount == 0 {
            return L10n.tr("Nothing active within 500m yet")
        }
        if !claimSectionSignals.isEmpty && !locationSectionSignals.isEmpty {
            return L10n.tr("Claims and your live handoff grouped together")
        }
        if !claimSectionSignals.isEmpty {
            return L10n.tr("Nearby spots")
        }
        return L10n.tr("Your live handoff location is active")
    }

    private var collapsedSubtitle: String {
        if spotStore.userCoordinate == nil && parkingReminderStore.savedParkedLocation == nil {
            return L10n.tr("Tap to enable your location")
        }
        if spotStore.userCoordinate == nil && parkingReminderStore.savedParkedLocation != nil {
            return L10n.tr("Parked car saved")
        }
        if groupedHandoffCount == 0 {
            return L10n.tr("No live handoffs within 500m")
        }
        if !claimSectionSignals.isEmpty && !locationSectionSignals.isEmpty {
            return L10n.format("%d claims • %d locations", claimSectionSignals.count, locationSectionSignals.count)
        }
        if !claimSectionSignals.isEmpty {
            return claimSectionSignals.count == 1 ? L10n.tr("1 handoff claim") : L10n.format("%d handoff claims", claimSectionSignals.count)
        }
        return locationSectionSignals.count == 1 ? L10n.tr("1 handoff location") : L10n.format("%d handoff locations", locationSectionSignals.count)
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
            if !hasShareableLocation {
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

    private var expandedSheetChromeHeight: CGFloat {
        let topPadding: CGFloat = 12
        let bottomPadding: CGFloat = isNearbySheetExpanded ? 18 : 16
        let headerToBodySpacing: CGFloat = isNearbySheetExpanded ? 16 : 12
        return nearbySheetHeaderHeight + topPadding + bottomPadding + headerToBodySpacing
    }

    private var expandedSheetBodyViewportLimit: CGFloat {
        max(0, expandedSheetHeightLimit - expandedSheetChromeHeight)
    }

    private var expandedSheetViewportHeight: CGFloat {
        min(expandedSheetContentHeight, expandedSheetBodyViewportLimit)
    }

    private var expandedSheetRenderedTotalHeight: CGFloat {
        expandedSheetChromeHeight + expandedSheetViewportHeight
    }

    private var shouldUseScrollableExpandedSheet: Bool {
        expandedSheetContentHeight > expandedSheetBodyViewportLimit + 1
    }

    private var primaryButtonTitle: String {
        if !hasShareableLocation {
            return L10n.tr("Use Current Location")
        }
        if spotStore.currentUserLeavingSignal != nil {
            return L10n.tr("View My Live Handoff")
        }
        return L10n.tr("Leaving Soon")
    }

    private var primaryButtonIconName: String {
        if !hasShareableLocation {
            return "location.fill"
        }
        if spotStore.currentUserLeavingSignal != nil {
            return "timer"
        }
        return parkingReminderStore.savedParkedLocation != nil ? "parkingsign.circle.fill" : "arrowshape.turn.up.right.circle.fill"
    }

    private var hasShareableLocation: Bool {
        parkingReminderStore.savedParkedLocation != nil || spotStore.userCoordinate != nil
    }

    private func recenterOnUser() {
        pendingRecenterOnLocationUpdate = true
        spotStore.prepareLocationTracking(requestIfNeeded: true)
        focusMap(animated: true)
    }

    private func focusOnSavedParkedLocation() {
        guard let reminder = parkingReminderStore.savedParkedLocation else { return }

        collapseNearbySheetIfNeeded()
        setCameraPosition(
            .region(
                MKCoordinateRegion(
                    center: reminder.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                )
            ),
            animated: true
        )
        //showParkedLocationToast(for: reminder)
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

    private func localizedAreaLabel(_ label: String) -> String {
        label == "Nearby" ? L10n.tr("Nearby") : label
    }

    private var nearbySheetGrabberGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($nearbySheetDragTranslation) { value, state, _ in
                state = clampedNearbySheetDragTranslation(value.translation.height)
            }
            .onEnded { value in
                let translation = value.translation.height
                let threshold: CGFloat = 32

                if translation < -threshold, !isNearbySheetExpanded {
                    expandNearbySheet()
                } else if translation > threshold, isNearbySheetExpanded {
                    collapseNearbySheetIfNeeded()
                }
            }
    }

    private var nearbySheetDragOffset: CGFloat {
        clampedNearbySheetDragTranslation(nearbySheetDragTranslation)
    }

    private func clampedNearbySheetDragTranslation(_ translation: CGFloat) -> CGFloat {
        if isNearbySheetExpanded {
            if translation > 0 {
                return min(translation, 54)
            }
            return max(translation * 0.18, -10)
        }

        if translation < 0 {
            return max(translation, -54)
        }
        return min(translation * 0.18, 10)
    }

    private func toggleNearbySheet() {
        DispatchQueue.main.async {
            withAnimation {
                isNearbySheetExpanded.toggle()
            }
        }
    }

    private func expandNearbySheet() {
        DispatchQueue.main.async {
            withAnimation{
                isNearbySheetExpanded = true
            }
        }
    }

    private func collapseNearbySheetIfNeeded() {
        guard isNearbySheetExpanded else { return }
        DispatchQueue.main.async {
            withAnimation{
                isNearbySheetExpanded = false
            }
        }
    }

    private var nearbySheetRenderedBottomInset: CGFloat {
        isNearbySheetExpanded ? expandedSheetRenderedTotalHeight : 112
    }

    private func parkedLocationToast(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "parkingsign.circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: SpotRelayTheme.shadow, radius: 16, y: 8)
    }

    private func showParkedLocationToast(for reminder: ParkingReminderStore.Reminder) {
        let message: String
        if let areaLabel = reminder.areaLabel, !areaLabel.isEmpty {
            message = L10n.format("Centered on your parked spot near %@.", areaLabel)
        } else {
            message = L10n.tr("Centered on your parked spot.")
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            parkedLocationToastMessage = message
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard parkedLocationToastMessage == message else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                parkedLocationToastMessage = nil
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
                title: L10n.tr("Notifications are off"),
                message: L10n.tr("Turn notifications on so SpotRelay can alert you when you're back near your parked car.")
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
                title: L10n.tr("Smart parking is on"),
                message: L10n.tr("SpotRelay will now look for likely parking stops and arm a return reminder automatically.")
            )
        case .needsAlwaysLocation:
            parkingReminderAlert = HomeViewAlert(
                title: L10n.tr("Finish location setup"),
                message: L10n.tr("Choose Always Allow for SpotRelay so smart parking can keep working even when the app isn't open.")
            )
        case .needsMotionAccess:
            parkingReminderAlert = HomeViewAlert(
                title: L10n.tr("Motion access needed"),
                message: L10n.tr("Allow Motion & Fitness for SpotRelay so it can tell when a drive has likely ended.")
            )
        case .unsupported:
            parkingReminderAlert = HomeViewAlert(
                title: L10n.tr("Smart parking unavailable"),
                message: L10n.tr("This device doesn't expose the motion signals SpotRelay needs for automatic parked-spot detection.")
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
                    Text(L10n.tr(title))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(L10n.tr(subtitle))
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
            Text(L10n.tr(title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text(L10n.tr(subtitle))
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

    private func parkingReminderDebugIcon(for state: ParkingReminderStore.DebugState) -> String {
        switch state {
        case .noReminder:
            return "car.circle"
        case .armed:
            return "location.circle.fill"
        case .exitedWaitingForReturn:
            return "figure.walk.departure"
        case .notificationScheduled:
            return "bell.badge.fill"
        case .pausedNeedsAlwaysLocation:
            return "location.slash.circle.fill"
        case .monitoringUnavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private func parkingReminderDebugTint(for state: ParkingReminderStore.DebugState) -> Color {
        switch state {
        case .noReminder:
            return SpotRelayTheme.textSecondary
        case .armed:
            return SpotRelayTheme.success
        case .exitedWaitingForReturn:
            return SpotRelayTheme.primary
        case .notificationScheduled:
            return SpotRelayTheme.warning
        case .pausedNeedsAlwaysLocation, .monitoringUnavailable:
            return SpotRelayTheme.warning
        }
    }
}

private struct ExpandedSheetContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NearbySheetHeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct HomeViewAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct ParkedCarPinView: View {
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

private struct ParkedLocationDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var parkingReminderStore: ParkingReminderStore

    let initialReminder: ParkingReminderStore.Reminder

    @State private var localAlert: HomeViewAlert?

    private var reminder: ParkingReminderStore.Reminder {
        parkingReminderStore.savedParkedLocation ?? initialReminder
    }

    private var statusTitle: String {
        parkingReminderStore.activeReminder != nil ? L10n.tr("Reminder armed") : L10n.tr("Ready to share")
    }

    private var savedRelativeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: reminder.createdAt, relativeTo: .now)
    }

    private var savedAbsoluteText: String {
        reminder.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    detailPanel
                    directionsPanel
                    controlsPanel
                }
                .padding(20)
            }
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .navigationTitle("You parked here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert(item: $localAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Parked car")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(SpotRelayTheme.badgeText)

                Text(reminder.areaLabel ?? "Saved parking spot")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("SpotRelay will use this parked pin by default when you share a handoff, so the spot lands closer to the actual car location.")
                    .font(.body.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.orbGradient)
                    .frame(width: 58, height: 58)

                Image(systemName: "car.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .glassPanel(
            cornerRadius: 30,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 24,
            shadowY: 12
        )
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved details")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            detailRow(
                icon: "clock.fill",
                title: "Saved",
                value: L10n.format("Updated %@", savedRelativeText),
                subtitle: savedAbsoluteText
            )

            detailRow(
                icon: "parkingsign.circle.fill",
                title: "Share point",
                value: "This parked pin will be used first",
                subtitle: "New leaving handoffs will publish from this saved car location."
            )

            detailRow(
                icon: "location.circle.fill",
                title: "Reminder status",
                value: statusTitle,
                subtitle: reminder.areaSummary
            )

            HStack(spacing: 10) {
                badge(text: L10n.format("%d m return radius", Int(reminder.radiusMeters)))

                if let userCoordinate = spotStore.userCoordinate {
                    badge(text: reminder.coordinateDistanceText(from: userCoordinate))
                }
            }
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

    private var directionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Directions back to the car")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Open navigation directly to the saved parked spot.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            HStack(spacing: 12) {
                Button {
                    openAppleMapsDirections()
                } label: {
                    parkedActionButton(
                        title: "Apple Maps",
                        icon: "map.fill",
                        color: SpotRelayTheme.primary
                    )
                }
                .buttonStyle(.plain)

                Button {
                    openGoogleMapsDirections()
                } label: {
                    parkedActionButton(
                        title: "Google Maps",
                        icon: "arrow.triangle.turn.up.right.diamond.fill",
                        color: SpotRelayTheme.success
                    )
                }
                .buttonStyle(.plain)
            }
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

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage parked pin")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Refresh the parked spot to your current location if you moved the car, or clear it if this is no longer useful.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            Button {
                Task {
                    await updateParkedLocationToCurrentPosition()
                }
            } label: {
                HStack {
                    Image(systemName: "location.fill")
                    Text("Update to My Current Location")
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(spotStore.userCoordinate == nil)
            .opacity(spotStore.userCoordinate == nil ? 0.55 : 1)

            Button(role: .destructive) {
                Task {
                    await parkingReminderStore.clearReminder()
                    dismiss()
                }
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Clear Saved Parked Spot")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .foregroundStyle(SpotRelayTheme.warning)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SpotRelayTheme.badgeFill, in: Capsule())
            .foregroundStyle(SpotRelayTheme.badgeText)
    }

    private func detailRow(icon: String, title: String, value: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(SpotRelayTheme.badgeFill)
                    .frame(width: 38, height: 38)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SpotRelayTheme.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(title))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.9)

                Text(L10n.tr(value))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(L10n.tr(subtitle))
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func parkedActionButton(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(L10n.tr(title))
        }
        .font(.subheadline.weight(.bold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(color)
    }

    private func updateParkedLocationToCurrentPosition() async {
        guard let userCoordinate = spotStore.userCoordinate else {
            localAlert = HomeViewAlert(
                title: L10n.tr("Current location unavailable"),
                message: L10n.tr("Move the map back to your current location first, then try updating the parked pin again.")
            )
            return
        }

        do {
            try await parkingReminderStore.rememberParkedSpot(
                at: userCoordinate,
                areaLabel: spotStore.currentAreaLabel,
                radiusMeters: reminder.radiusMeters
            )
        } catch {
            localAlert = HomeViewAlert(
                title: L10n.tr("Couldn't update parked spot"),
                message: error.localizedDescription
            )
        }
    }

    private func openAppleMapsDirections() {
        let destination = MKMapItem(
            location: CLLocation(
                latitude: reminder.coordinate.latitude,
                longitude: reminder.coordinate.longitude
            ),
            address: nil
        )
        destination.name = L10n.tr("Saved Parked Car")

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
            source.name = L10n.tr("Current Location")
            MKMapItem.openMaps(with: [source, destination], launchOptions: launchOptions)
        } else {
            destination.openInMaps(launchOptions: launchOptions)
        }
    }

    private func openGoogleMapsDirections() {
        let destinationValue = "\(reminder.coordinate.latitude),\(reminder.coordinate.longitude)"
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
}

private struct SpotPinView: View {
    let signal: ParkingSpotSignal

    var body: some View {
        VStack(spacing: 6) {
            Text(signal.isActive ? L10n.tr(signal.status.rawValue.capitalized) : L10n.tr("Closed"))
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
            return signal.claimedBy == spotStore.currentUser.id ? L10n.tr("Claimed") : L10n.tr("Open")
        case .location:
            switch signal.status {
            case .posted:
                return L10n.tr("Live")
            case .claimed, .arriving:
                return L10n.tr("Claimed")
            case .completed:
                return L10n.tr("Done")
            case .expired:
                return L10n.tr("Expired")
            case .cancelled:
                return L10n.tr("Cancelled")
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
                detailChip(title: spot.minutesRemainingText, subtitle: L10n.tr("remaining"))
                detailChip(title: spot.distanceValue(from: spotStore.userCoordinate), subtitle: L10n.tr("away"))
                detailChip(title: L10n.tr("Live"), subtitle: spot.statusLabel(for: spotStore.currentUser.id))
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
        return L10n.format("%d min", minutes)
    }
}
