import Combine
import CoreLocation
import Foundation
import MapKit
import Network

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
    private var lastGeocodedLocation: CLLocation?
    private var bannerDismissTask: Task<Void, Never>?

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

    func displayName(for userID: String?) -> String? {
        guard let userID else { return nil }
        if userID == currentUser.id {
            return currentUser.displayName
        }

        let normalized = userID
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { segment in
                let lowercased = segment.lowercased()
                if lowercased == "driver" {
                    return "Driver"
                }
                if lowercased.count == 1 {
                    return lowercased.uppercased()
                }
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")

        return normalized.isEmpty ? "Nearby driver" : normalized
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
                title: "Share location needed",
                message: "We need your parked location or live location before we can share your spot."
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
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: "Couldn't share your spot",
                fallbackMessage: "Please try posting your handoff again in a moment."
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
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: "Couldn't claim this handoff",
                fallbackMessage: "That spot may already be taken or no longer nearby."
            )
            return false
        }
    }

    @discardableResult
    func markArrival() async -> Bool {
        guard ensureReadyForMutation() else { return false }
        guard let activeHandoffID else { return false }

        do {
            _ = try await repository.markArrival(id: activeHandoffID, userID: currentUser.id)
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: "Couldn't update arrival",
                fallbackMessage: "Please try marking your arrival again."
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
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: "Couldn't cancel this handoff",
                fallbackMessage: "Please try again in a moment."
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
            self.activeHandoffID = nil
            clearErrorBanner()
            return true
        } catch {
            presentRepositoryError(
                error,
                title: "Couldn't finish this handoff",
                fallbackMessage: "Please try again before leaving the handoff."
            )
            return false
        }
    }

    func updateCurrentUserProfile(displayName: String, avatarJPEGData: Data?) {
        currentUser = userIdentity.updateProfile(displayName: displayName, avatarJPEGData: avatarJPEGData)
    }

    func clearErrorBanner() {
        bannerDismissTask?.cancel()
        errorBanner = nil
    }

    private func bindRepository() {
        spots = repository.currentSpots

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
    }

    private func applyRepositorySpots(_ latestSpots: [ParkingSpotSignal]) {
        spots = latestSpots

        guard let activeHandoffID else { return }
        let stillActive = latestSpots.contains { $0.id == activeHandoffID && $0.isActive }
        if !stillActive {
            self.activeHandoffID = nil
        }
    }

    private func startLocationTrackingIfAuthorized() {
        guard hasLocationAccess else { return }
        if let coordinate = locationManager.location?.coordinate {
            setUserCoordinate(coordinate)
        }
        locationManager.startUpdatingLocation()
    }

    private func setUserCoordinate(_ coordinate: CLLocationCoordinate2D) {
        userCoordinate = coordinate
        repository.seedPreviewSpotsIfNeeded(around: coordinate)
        refreshAreaLabelIfNeeded(for: coordinate)
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

    private func ensureReadyForMutation() -> Bool {
        guard isNetworkAvailable else {
            presentBanner(
                title: "You're offline",
                message: "SpotRelay needs internet for live spots, claims, profile updates, and real-time handoffs."
            )
            return false
        }

        guard !(backendMode.isFirebase && currentUser.id == firebasePendingUserID) else {
            presentBanner(
                title: "Connecting to Firebase",
                message: "Please wait a moment for your secure user session to finish connecting."
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
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in
            self?.setUserCoordinate(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.presentBanner(
                title: "Location unavailable",
                message: "We couldn't read your current location yet. Please try again in a moment."
            )
        }
    }
}

enum HandoffRole {
    case leaving
    case arriving
}
