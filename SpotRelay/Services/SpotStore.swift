import Combine
import CoreLocation
import Foundation
import MapKit
import Network
#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

struct ReviewPromptRequest: Equatable {
    let id = UUID()
    let successfulHandoffCount: Int
}

struct AppleAccountLinkResult: Equatable {
    let isLinked: Bool
    let message: String?

    static let success = AppleAccountLinkResult(isLinked: true, message: nil)

    static func failure(_ message: String) -> AppleAccountLinkResult {
        AppleAccountLinkResult(isLinked: false, message: message)
    }
}

@MainActor
final class SpotStore: NSObject, ObservableObject {
    let nearbySearchRadiusMeters = 500
    private let firebasePendingUserID = "firebase-auth-pending"

    @Published private(set) var currentUser: AppUser
    @Published private(set) var spots: [ParkingSpotSignal] = []
    @Published private(set) var userCoordinate: CLLocationCoordinate2D?
    @Published private(set) var currentAreaLabel = "Nearby"
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isNetworkAvailable = true
    @Published private(set) var userProfiles: [String: AppUser] = [:]
    @Published private(set) var reviewPromptRequest: ReviewPromptRequest?
    @Published private(set) var isDebugDemoDataEnabled: Bool
    @Published private(set) var sharedSpotHistory: [ParkingSpotSignal]
    @Published var activeHandoffID: String?
    @Published var errorBanner: SpotRelayErrorBannerState?
    let backendMode: SpotRelayBackendMode

    private let repository: SpotRepository
    private let userIdentity: UserIdentityProviding
    private let parkingReminderStore: ParkingReminderStore
    private let locationManager = CLLocationManager()
    private let networkPathMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.spotrelay.network-monitor")
    private var cancellables = Set<AnyCancellable>()
    private var repositorySpots: [ParkingSpotSignal] = []
    private var lastUserLocation: CLLocation?
    private var lastGeocodedLocation: CLLocation?
    private var bannerDismissTask: Task<Void, Never>?
    private var isAutoCompletingArrival = false
    private var locallyTrackedActiveHandoff: ParkingSpotSignal?
    private var lastAutoArrivalSkipLogKey: String?

    private enum Keys {
        static let debugDemoDataEnabled = "spotStore.debugDemoDataEnabled"
        static let sharedSpotHistory = "spotStore.sharedSpotHistory"
    }

    private enum SharedSpotHistory {
        static let maximumRecordCount = 10_000
    }

    private enum AutoArrivalCompletion {
        static let maximumAccuracyMeters: CLLocationAccuracy = 3
        static let completionRadiusMeters: CLLocationDistance = 3
        static let maximumLocationAge: TimeInterval = 30
        static let claimedExpiryGraceInterval: TimeInterval = 10 * 60
    }

    init(
        repository: SpotRepository,
        userIdentity: UserIdentityProviding,
        backendMode: SpotRelayBackendMode,
        parkingReminderStore: ParkingReminderStore
    ) {
        self.repository = repository
        self.userIdentity = userIdentity
        self.backendMode = backendMode
        self.parkingReminderStore = parkingReminderStore
        self.currentUser = userIdentity.currentUser
        self.isDebugDemoDataEnabled = UserDefaults.standard.bool(forKey: Keys.debugDemoDataEnabled)
        self.sharedSpotHistory = Self.loadSharedSpotHistory()
        super.init()

        bindRepository()
        bindUserIdentity()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 10
        locationAuthorizationStatus = locationManager.authorizationStatus
        startLocationTrackingIfAuthorized()
        startNetworkMonitoring()

        #if DEBUG
        print("SpotRelay backend: \(backendMode.shortLabel) - \(backendMode.detail)")
        #endif
    }

    deinit {
        networkPathMonitor.cancel()
    }

    var activeHandoff: ParkingSpotSignal? {
        guard let activeHandoffID else { return nil }
        return spots.first(where: { $0.id == activeHandoffID && $0.isActive })
    }

    var nearbyActiveSpots: [ParkingSpotSignal] {
        guard let userCoordinate else { return [] }
        return spots
            .filter(\.isActive)
            .filter { $0.distanceMeters(from: userCoordinate) <= nearbySearchRadiusMeters }
            .sorted { lhs, rhs in
                lhs.distanceMeters(from: userCoordinate) < rhs.distanceMeters(from: userCoordinate)
            }
    }

    var currentUserRole: HandoffRole? {
        guard let activeHandoff else { return nil }
        if activeHandoff.createdBy == currentUser.id { return .leaving }
        if activeHandoff.claimedBy == currentUser.id { return .arriving }
        return nil
    }

    var currentUserLeavingSignal: ParkingSpotSignal? {
        spots
            .filter { $0.isActive && $0.createdBy == currentUser.id }
            .sorted { lhs, rhs in
                if lhs.leavingAt != rhs.leavingAt {
                    return lhs.leavingAt < rhs.leavingAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .first
    }

    var preferredShareCoordinate: CLLocationCoordinate2D? {
        parkingReminderStore.savedParkedLocation?.coordinate ?? userCoordinate
    }

    var hasLocationAccess: Bool {
        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    var isAppleAccountLinked: Bool {
        userIdentity.isAppleAccountLinked
    }

    func displayName(for userID: String?) -> String? {
        guard let userID else { return nil }
        if userID == currentUser.id {
            return currentUser.localizedDisplayName
        }
        if let profile = userProfiles[userID] {
            return profile.localizedDisplayName
        }

        let normalized = userID
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { segment in
                let lowercased = segment.lowercased()
                if lowercased == "driver" {
                    return L10n.tr("Driver")
                }
                if lowercased.count == 1 {
                    return lowercased.uppercased()
                }
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")

        return normalized.isEmpty ? L10n.tr("Nearby driver") : normalized
    }

    func profile(for userID: String?) -> AppUser? {
        guard let userID else { return nil }
        if userID == currentUser.id {
            return currentUser
        }
        return userProfiles[userID]
    }

    func observeProfile(for userID: String?) {
        userIdentity.observeProfile(for: userID)
    }

    func refreshStatuses(now: Date = .now) {
        repository.refreshStatuses(now: now)
    }

    func runRefreshLoop() async {
        refreshStatuses()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { break }
            refreshStatuses()
        }
    }

    func prepareLocationTracking(requestIfNeeded: Bool) {
        locationAuthorizationStatus = locationManager.authorizationStatus

        switch locationAuthorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startLocationTrackingIfAuthorized()
            locationManager.requestLocation()
        case .notDetermined:
            guard requestIfNeeded else { return }
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    @discardableResult
    func postSpot(durationMinutes: Int, coordinateOverride: CLLocationCoordinate2D? = nil) async -> Bool {
        guard ensureReadyForMutation() else { return false }
        guard let coordinateToShare = coordinateOverride ?? preferredShareCoordinate else {
            presentBanner(
                title: L10n.tr("Share location needed"),
                message: L10n.tr("We need your parked location or live location before we can share your spot.")
            )
            return false
        }

        do {
            let signal = try await repository.postSpot(
                createdBy: currentUser.id,
                coordinate: coordinateToShare,
                durationMinutes: durationMinutes,
                now: .now
            )
            activeHandoffID = signal.id
            locallyTrackedActiveHandoff = signal
            upsertLocalSpot(signal)
            persistSharedSpotHistory(adding: signal)
            clearErrorBanner()
            ParkingSequenceLogger.shared.append(
                "Manual spot shared: id=\(signal.id), duration=\(durationMinutes)m, lat=\(coordinateToShare.latitude), lon=\(coordinateToShare.longitude)"
            )
            return true
        } catch {
            presentRepositoryError(
                error,
                title: L10n.tr("Couldn't share your spot"),
                fallbackMessage: L10n.tr("Please try posting your handoff again in a moment.")
            )
            return false
        }
    }

    @discardableResult
    func postAutoRelaySpot(
        from reminder: ParkingReminderStore.Reminder,
        durationMinutes: Int = 5,
        reason: String
    ) async -> Bool {
        guard isNetworkAvailable else {
            ParkingSequenceLogger.shared.append("Auto Relay share skipped: offline")
            return false
        }
        guard !(backendMode.isFirebase && currentUser.id == firebasePendingUserID) else {
            ParkingSequenceLogger.shared.append("Auto Relay share skipped: Firebase user session still connecting")
            return false
        }

        if let leavingSignal = currentUserLeavingSignal {
            activeHandoffID = leavingSignal.id
            ParkingSequenceLogger.shared.append(
                "Auto Relay share skipped: existing live handoff id=\(leavingSignal.id)"
            )
            return false
        }

        do {
            let signal = try await repository.postSpot(
                createdBy: currentUser.id,
                coordinate: reminder.coordinate,
                durationMinutes: durationMinutes,
                now: .now
            )
            activeHandoffID = signal.id
            locallyTrackedActiveHandoff = signal
            upsertLocalSpot(signal)
            persistSharedSpotHistory(adding: signal)
            clearErrorBanner()
            ParkingSequenceLogger.shared.append(
                "Auto Relay shared parked spot: id=\(signal.id), reason=\(reason), duration=\(durationMinutes)m, lat=\(reminder.latitude), lon=\(reminder.longitude), area=\(reminder.areaLabel ?? "unknown area")"
            )
            return true
        } catch {
            ParkingSequenceLogger.shared.append(
                "Auto Relay share failed: reason=\(reason), error=\(userFacingMessage(for: error, fallback: error.localizedDescription))"
            )
            return false
        }
    }

    @discardableResult
    func claimSpot(id: String) async -> Bool {
        guard ensureReadyForMutation() else { return false }
        do {
            let signal = try await repository.claimSpot(
                id: id,
                userID: currentUser.id,
                userCoordinate: userCoordinate,
                nearbySearchRadiusMeters: nearbySearchRadiusMeters,
                now: .now
            )
            activeHandoffID = signal.id
            locallyTrackedActiveHandoff = signal
            upsertLocalSpot(signal)
            updateLocationTrackingPrecisionForActiveHandoff()
            clearErrorBanner()
            ParkingSequenceLogger.shared.append(
                "Spot claimed: id=\(signal.id), lat=\(signal.latitude), lon=\(signal.longitude), leavingAt=\(signal.leavingAt.timeIntervalSince1970)"
            )
            evaluateAutoArrivalCompletionIfNeeded()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: L10n.tr("Couldn't claim this handoff"),
                fallbackMessage: L10n.tr("That spot may already be taken or no longer nearby.")
            )
            return false
        }
    }

    @discardableResult
    func markArrival() async -> Bool {
        guard ensureReadyForMutation() else { return false }
        guard let activeHandoffID else { return false }

        do {
            let signal = try await repository.markArrival(id: activeHandoffID, userID: currentUser.id)
            locallyTrackedActiveHandoff = signal
            upsertLocalSpot(signal)
            clearErrorBanner()
            evaluateAutoArrivalCompletionIfNeeded()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: L10n.tr("Couldn't update arrival"),
                fallbackMessage: L10n.tr("Please try marking your arrival again.")
            )
            return false
        }
    }

    @discardableResult
    func cancelActiveHandoff() async -> Bool {
        guard ensureReadyForMutation() else { return false }
        guard let activeHandoffID else { return false }

        do {
            _ = try await repository.cancelHandoff(id: activeHandoffID, userID: currentUser.id)
            self.activeHandoffID = nil
            self.locallyTrackedActiveHandoff = nil
            updateLocationTrackingPrecisionForActiveHandoff()
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: L10n.tr("Couldn't cancel this handoff"),
                fallbackMessage: L10n.tr("Please try again in a moment.")
            )
            return false
        }
    }

    @discardableResult
    func completeActiveHandoff(success: Bool) async -> Bool {
        guard ensureReadyForMutation() else { return false }
        guard let activeHandoffID else { return false }
        let roleAtCompletion = currentUserRole

        do {
            _ = try await repository.completeHandoff(id: activeHandoffID, userID: currentUser.id, success: success)
            currentUser = userIdentity.recordCompletedHandoff(success: success, as: roleAtCompletion)
            if success {
                reviewPromptRequest = ReviewPromptRequest(successfulHandoffCount: currentUser.successfulHandoffs)
            }
            self.activeHandoffID = nil
            self.locallyTrackedActiveHandoff = nil
            updateLocationTrackingPrecisionForActiveHandoff()
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: L10n.tr("Couldn't finish this handoff"),
                fallbackMessage: L10n.tr("Please try again before leaving the handoff.")
            )
            return false
        }
    }

    func updateCurrentUserProfile(displayName: String, avatarJPEGData: Data?) {
        currentUser = userIdentity.updateProfile(displayName: displayName, avatarJPEGData: avatarJPEGData)
    }

    @discardableResult
    func linkAppleAccount(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async -> AppleAccountLinkResult {
        guard ensureReadyForMutation() else {
            return .failure(errorBanner?.message ?? L10n.tr("Please try signing in with Apple again."))
        }

        do {
            currentUser = try await userIdentity.linkAppleAccount(
                idToken: idToken,
                rawNonce: rawNonce,
                fullName: fullName
            )
            clearErrorBanner()
            return .success
        } catch {
            let message = accountLinkingMessage(
                for: error,
                fallback: L10n.tr("Please try signing in with Apple again.")
            )
            #if DEBUG
            let nsError = error as NSError
            print("SpotRelay Apple account link failed: domain=\(nsError.domain) code=\(nsError.code) message=\(message) userInfo=\(nsError.userInfo)")
            #endif
            presentBanner(title: L10n.tr("Couldn't save Apple sign-in"), message: message)
            return .failure(message)
        }
    }

    func clearErrorBanner() {
        bannerDismissTask?.cancel()
        errorBanner = nil
    }

    func setDebugDemoDataEnabled(_ isEnabled: Bool) async {
        guard isDebugDemoDataEnabled != isEnabled else { return }
        isDebugDemoDataEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Keys.debugDemoDataEnabled)

        if isEnabled {
            parkingReminderStore.enableDebugDemoParkedData(anchor: debugDemoAnchorCoordinate)
        } else {
            parkingReminderStore.disableDebugDemoParkedData()
            activeHandoffID = nil
            updateLocationTrackingPrecisionForActiveHandoff()
        }

        applyRepositorySpots(repositorySpots)
        ParkingSequenceLogger.shared.append("Debug demo data \(isEnabled ? "enabled" : "disabled")")
    }

    private func bindRepository() {
        repositorySpots = repository.currentSpots
        spots = displaySpots(from: repositorySpots)

        repository.spotsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestSpots in
                self?.applyRepositorySpots(latestSpots)
            }
            .store(in: &cancellables)
    }

    private func bindUserIdentity() {
        userIdentity.currentUserPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestUser in
                self?.currentUser = latestUser
            }
            .store(in: &cancellables)

        userIdentity.userProfilesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestProfiles in
                self?.userProfiles = latestProfiles
            }
            .store(in: &cancellables)
    }

    private func applyRepositorySpots(_ latestSpots: [ParkingSpotSignal]) {
        repositorySpots = latestSpots
        let displaySpots = displaySpots(from: latestSpots)
        spots = displaySpots
        observeProfiles(for: displaySpots)

        guard let activeHandoffID else { return }
        let stillActive = displaySpots.contains { $0.id == activeHandoffID && $0.isActive }
        if let latestActiveHandoff = displaySpots.first(where: { $0.id == activeHandoffID }) {
            locallyTrackedActiveHandoff = latestActiveHandoff
        }
        if !stillActive {
            if let graceHandoff = displaySpots.first(where: { $0.id == activeHandoffID && allowsAutoArrivalGrace($0) }) {
                locallyTrackedActiveHandoff = graceHandoff
                ParkingSequenceLogger.shared.append(
                    "Keeping claimed handoff for auto-arrival grace: id=\(graceHandoff.id), expiredBy=\(Int(Date().timeIntervalSince(graceHandoff.leavingAt).rounded()))s"
                )
                evaluateAutoArrivalCompletionIfNeeded()
                return
            }
            self.activeHandoffID = nil
            self.locallyTrackedActiveHandoff = nil
            updateLocationTrackingPrecisionForActiveHandoff()
        }
        evaluateAutoArrivalCompletionIfNeeded()
    }

    private func upsertLocalSpot(_ signal: ParkingSpotSignal) {
        repositorySpots.removeAll { $0.id == signal.id }
        repositorySpots.append(signal)
        spots = displaySpots(from: repositorySpots)
        observeProfiles(for: spots)
    }

    private func persistSharedSpotHistory(adding signal: ParkingSpotSignal) {
        var history = sharedSpotHistory
        history.removeAll { $0.id == signal.id }
        history.insert(signal, at: 0)
        history = Array(history.prefix(SharedSpotHistory.maximumRecordCount))
        sharedSpotHistory = history

        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Keys.sharedSpotHistory)
    }

    private static func loadSharedSpotHistory() -> [ParkingSpotSignal] {
        guard let data = UserDefaults.standard.data(forKey: Keys.sharedSpotHistory),
              let history = try? JSONDecoder().decode([ParkingSpotSignal].self, from: data) else {
            return []
        }
        return Array(history.prefix(SharedSpotHistory.maximumRecordCount))
    }

    private func displaySpots(from latestSpots: [ParkingSpotSignal]) -> [ParkingSpotSignal] {
        guard isDebugDemoDataEnabled else { return latestSpots }
        let existingIDs = Set(latestSpots.map(\.id))
        let demoSpots = DebugDemoData.spots(around: debugDemoAnchorCoordinate)
            .filter { !existingIDs.contains($0.id) }
        return latestSpots + demoSpots
    }

    private func observeProfiles(for latestSpots: [ParkingSpotSignal]) {
        let userIDs = latestSpots.reduce(into: Set<String>()) { result, signal in
            result.insert(signal.createdBy)
            if let claimedBy = signal.claimedBy {
                result.insert(claimedBy)
            }
        }

        userIDs.forEach { userIdentity.observeProfile(for: $0) }
    }

    private func startLocationTrackingIfAuthorized() {
        guard hasLocationAccess else { return }
        if let coordinate = locationManager.location?.coordinate {
            setUserLocation(locationManager.location ?? CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        locationManager.startUpdatingLocation()
    }

    private func setUserLocation(_ location: CLLocation) {
        let coordinate = location.coordinate
        lastUserLocation = location
        userCoordinate = coordinate
        repository.seedPreviewSpotsIfNeeded(around: coordinate)
        if isDebugDemoDataEnabled {
            applyRepositorySpots(repositorySpots)
        }
        refreshAreaLabelIfNeeded(for: coordinate)
        evaluateAutoArrivalCompletionIfNeeded()
        Task {
            await parkingReminderStore.verifyReturnProximityFallback(at: coordinate)
        }
    }

    private func evaluateAutoArrivalCompletionIfNeeded() {
        guard !isAutoCompletingArrival else { return }
        guard let activeHandoffID else { return }
        guard let handoff = autoArrivalHandoffCandidate(id: activeHandoffID) else {
            logAutoArrivalSkip("no active claimed handoff candidate", handoffID: activeHandoffID)
            return
        }
        guard handoff.claimedBy == currentUser.id,
              handoff.createdBy != currentUser.id else {
            logAutoArrivalSkip("current user is not the claimant", handoffID: handoff.id)
            return
        }
        guard handoff.isActive || allowsAutoArrivalGrace(handoff) else {
            logAutoArrivalSkip("handoff is no longer active", handoffID: handoff.id)
            return
        }
        guard let location = lastUserLocation else {
            logAutoArrivalSkip("missing latest user location", handoffID: handoff.id)
            return
        }
        guard abs(location.timestamp.timeIntervalSinceNow) <= AutoArrivalCompletion.maximumLocationAge else {
            logAutoArrivalSkip("latest user location is stale", handoffID: handoff.id)
            return
        }

        let spotLocation = CLLocation(
            latitude: handoff.latitude,
            longitude: handoff.longitude
        )
        let distance = location.distance(from: spotLocation)
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= AutoArrivalCompletion.maximumAccuracyMeters else {
            if distance <= 25 {
                logAutoArrivalSkip(
                    "near spot but accuracy \(Int(location.horizontalAccuracy.rounded()))m exceeds \(Int(AutoArrivalCompletion.maximumAccuracyMeters))m, distance=\(String(format: "%.1f", distance))m",
                    handoffID: handoff.id
                )
            }
            return
        }
        guard distance <= AutoArrivalCompletion.completionRadiusMeters else {
            if distance <= 25 {
                logAutoArrivalSkip(
                    "near spot but outside \(Int(AutoArrivalCompletion.completionRadiusMeters))m radius, distance=\(String(format: "%.1f", distance))m, accuracy=\(Int(location.horizontalAccuracy.rounded()))m",
                    handoffID: handoff.id
                )
            }
            return
        }

        isAutoCompletingArrival = true
        let handoffID = handoff.id
        ParkingSequenceLogger.shared.append(
            "Auto handoff completion triggered: id=\(handoffID), distance=\(String(format: "%.1f", distance))m, accuracy=\(Int(location.horizontalAccuracy.rounded()))m"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.completeActiveHandoff(success: true)
            self.isAutoCompletingArrival = false
        }
    }

    private func autoArrivalHandoffCandidate(id: String) -> ParkingSpotSignal? {
        if let active = activeHandoff {
            return active
        }

        if let local = locallyTrackedActiveHandoff, local.id == id {
            return local
        }

        return spots.first { $0.id == id }
    }

    private func allowsAutoArrivalGrace(_ signal: ParkingSpotSignal) -> Bool {
        guard signal.claimedBy == currentUser.id,
              signal.createdBy != currentUser.id else {
            return false
        }

        switch signal.status {
        case .claimed, .arriving:
            return Date() <= signal.leavingAt.addingTimeInterval(AutoArrivalCompletion.claimedExpiryGraceInterval)
        case .posted, .completed, .expired, .cancelled:
            return false
        }
    }

    private func logAutoArrivalSkip(_ reason: String, handoffID: String) {
        let key = "\(handoffID):\(reason)"
        guard key != lastAutoArrivalSkipLogKey else { return }
        lastAutoArrivalSkipLogKey = key
        ParkingSequenceLogger.shared.append("Auto handoff completion skipped: id=\(handoffID), reason=\(reason)")
    }

    private func updateLocationTrackingPrecisionForActiveHandoff() {
        let isArriving = currentUserRole == .arriving || locallyTrackedActiveHandoff?.claimedBy == currentUser.id
        if isArriving {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 1
            startLocationTrackingIfAuthorized()
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
        }
    }

    private var debugDemoAnchorCoordinate: CLLocationCoordinate2D {
        userCoordinate
            ?? parkingReminderStore.latestRememberedParkedLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 37.56449, longitude: -122.05515)
    }

    private func refreshAreaLabelIfNeeded(for coordinate: CLLocationCoordinate2D) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let lastGeocodedLocation, lastGeocodedLocation.distance(from: location) < 250 {
            return
        }

        lastGeocodedLocation = location

        Task {
            do {
                guard let request = MKReverseGeocodingRequest(location: location) else { return }
                let mapItems = try await request.mapItems
                guard let mapItem = mapItems.first else { return }

                let label = mapItem.addressRepresentations?.cityName
                    ?? mapItem.addressRepresentations?.cityWithContext
                    ?? mapItem.address?.shortAddress
                    ?? mapItem.name?.components(separatedBy: ",").first

                if let label, !label.isEmpty {
                    currentAreaLabel = label
                } else {
                    currentAreaLabel = "Nearby"
                }
            } catch {
            }
        }
    }

    private func presentRepositoryError(_ error: Error, title: String, fallbackMessage: String) {
        presentBanner(
            title: title,
            message: userFacingMessage(for: error, fallback: fallbackMessage)
        )
    }

    private func accountLinkingMessage(for error: Error, fallback: String) -> String {
        let nsError = error as NSError

        #if canImport(FirebaseAuth)
        switch nsError.code {
        case AuthErrorCode.operationNotAllowed.rawValue:
            return L10n.tr("Apple sign-in isn't enabled in Firebase Authentication yet. Enable Apple under Firebase Console > Authentication > Sign-in method.")
        case AuthErrorCode.missingOrInvalidNonce.rawValue:
            return L10n.tr("Firebase could not verify the Apple sign-in nonce. Please try again.")
        case AuthErrorCode.invalidCredential.rawValue:
            return L10n.tr("Firebase could not verify the Apple credential. Please try again, then check the Apple provider setup in Firebase if it keeps happening.")
        case AuthErrorCode.networkError.rawValue:
            return L10n.tr("Apple sign-in needs internet to finish linking your profile.")
        default:
            break
        }
        #endif

        return userFacingMessage(for: error, fallback: fallback)
    }

    private func ensureReadyForMutation() -> Bool {
        guard isNetworkAvailable else {
            presentBanner(
                title: L10n.tr("You're offline"),
                message: L10n.tr("SpotRelay needs internet for live spots, claims, profile updates, and real-time handoffs.")
            )
            return false
        }

        guard !(backendMode.isFirebase && currentUser.id == firebasePendingUserID) else {
            presentBanner(
                title: L10n.tr("Connecting to Firebase"),
                message: L10n.tr("Please wait a moment for your secure user session to finish connecting.")
            )
            return false
        }

        return true
    }

    private func presentBanner(title: String, message: String) {
        bannerDismissTask?.cancel()
        errorBanner = SpotRelayErrorBannerState(title: title, message: message)
        bannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.errorBanner = nil
        }
    }

    private func userFacingMessage(for error: Error, fallback: String) -> String {
        if let repositoryError = error as? SpotRepositoryError,
           let description = repositoryError.errorDescription,
           !description.isEmpty {
            return description
        }

        let nsError = error as NSError
        let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty, description != nsError.domain {
            return description
        }

        return fallback
    }

    private func startNetworkMonitoring() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        networkPathMonitor.start(queue: networkMonitorQueue)
    }
}

extension SpotStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationAuthorizationStatus = manager.authorizationStatus
            self.startLocationTrackingIfAuthorized()
            if self.hasLocationAccess {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.setUserLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.presentBanner(
                title: L10n.tr("Location unavailable"),
                message: L10n.tr("We couldn't read your current location yet. Please try again in a moment.")
            )
        }
    }
}

enum HandoffRole {
    case leaving
    case arriving
}
