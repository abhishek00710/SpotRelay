import Foundation
import MapKit
import Combine
import CoreLocation

@MainActor
final class SpotStore: NSObject, ObservableObject {
    let nearbySearchRadiusMeters = 500

    @Published private(set) var currentUser = AppUser(
        id: "current-user",
        displayName: "You",
        successfulHandoffs: 12,
        noShowCount: 1
    )
    @Published private(set) var spots: [ParkingSpotSignal] = []
    @Published private(set) var userCoordinate: CLLocationCoordinate2D?
    @Published private(set) var currentAreaLabel = "Nearby"
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var activeHandoffID: String?

    private let locationManager = CLLocationManager()
    private var hasSeededPreviewSpots = false
    private var lastGeocodedLocation: CLLocation?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 10
        locationAuthorizationStatus = locationManager.authorizationStatus
        startLocationTrackingIfAuthorized()
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

    func refreshStatuses(now: Date = .now) {
        var didExpireActive = false
        spots = spots.map { spot in
            guard spot.isActive, now >= spot.leavingAt else { return spot }
            if spot.id == activeHandoffID {
                didExpireActive = true
            }
            var expired = spot
            expired.status = .expired
            return expired
        }
        if didExpireActive {
            activeHandoffID = nil
        }
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
    func postSpot(durationMinutes: Int) -> Bool {
        guard let userCoordinate else { return false }

        let signal = ParkingSpotSignal(
            id: UUID().uuidString,
            createdBy: currentUser.id,
            claimedBy: nil,
            latitude: userCoordinate.latitude,
            longitude: userCoordinate.longitude,
            createdAt: .now,
            leavingAt: Calendar.current.date(byAdding: .minute, value: durationMinutes, to: .now) ?? .now,
            status: .posted
        )

        spots.insert(signal, at: 0)
        activeHandoffID = signal.id
        return true
    }

    func claimSpot(id: String) {
        refreshStatuses()
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        guard spots[index].status == .posted else { return }
        if let userCoordinate, spots[index].distanceMeters(from: userCoordinate) > nearbySearchRadiusMeters {
            return
        }
        spots[index].claimedBy = currentUser.id
        spots[index].status = .claimed
        activeHandoffID = id
    }

    func markArrival() {
        guard let activeHandoffID, let index = spots.firstIndex(where: { $0.id == activeHandoffID }) else { return }
        guard spots[index].claimedBy == currentUser.id else { return }
        spots[index].status = .arriving
    }

    func cancelActiveHandoff() {
        guard let activeHandoffID, let index = spots.firstIndex(where: { $0.id == activeHandoffID }) else { return }
        spots[index].status = .cancelled
        self.activeHandoffID = nil
    }

    func completeActiveHandoff(success: Bool) {
        guard let activeHandoffID, let index = spots.firstIndex(where: { $0.id == activeHandoffID }) else { return }
        spots[index].status = success ? .completed : .cancelled
        if success {
            currentUser.successfulHandoffs += 1
        } else {
            currentUser.noShowCount += 1
        }
        self.activeHandoffID = nil
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
        seedPreviewSpotsIfNeeded(around: coordinate)
        refreshAreaLabelIfNeeded(for: coordinate)
    }

    private func seedPreviewSpotsIfNeeded(around coordinate: CLLocationCoordinate2D) {
        guard !hasSeededPreviewSpots, spots.isEmpty else { return }
        spots = PreviewSignalSeed.signals(around: coordinate)
        hasSeededPreviewSpots = true
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
    }
}

enum HandoffRole {
    case leaving
    case arriving
}

enum PreviewSignalSeed {
    static func signals(around coordinate: CLLocationCoordinate2D) -> [ParkingSpotSignal] {
        let seeds: [(id: String, createdBy: String, claimedBy: String?, latOffset: Double, lonOffset: Double, createdAgo: TimeInterval, leavingIn: TimeInterval, status: SpotStatus)] = [
            ("spot-1", "driver-a", nil, 0.0008, -0.0005, 70, 125, .posted),
            ("spot-2", "driver-b", "driver-c", -0.0011, 0.0009, 120, 320, .claimed),
            ("spot-3", "driver-d", nil, 0.0005, 0.0014, 30, 560, .posted)
        ]

        return seeds.map { seed in
            ParkingSpotSignal(
                id: seed.id,
                createdBy: seed.createdBy,
                claimedBy: seed.claimedBy,
                latitude: coordinate.latitude + seed.latOffset,
                longitude: coordinate.longitude + seed.lonOffset,
                createdAt: .now.addingTimeInterval(-seed.createdAgo),
                leavingAt: .now.addingTimeInterval(seed.leavingIn),
                status: seed.status
            )
        }
    }
}
