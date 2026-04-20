import Foundation
import MapKit
import Combine
import CoreLocation

@MainActor
final class SpotStore: NSObject, ObservableObject {
    @Published private(set) var currentUser = AppUser(
        id: "current-user",
        displayName: "You",
        successfulHandoffs: 12,
        noShowCount: 1
    )
    @Published private(set) var spots: [ParkingSpotSignal] = DemoData.sampleSignals
    @Published private(set) var userCoordinate = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var activeHandoffID: String?

    private let locationManager = CLLocationManager()

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
        return spots
            .filter(\.isActive)
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

    func postSpot(durationMinutes: Int) {
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
    }

    func claimSpot(id: String) {
        refreshStatuses()
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        guard spots[index].status == .posted else { return }
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
            userCoordinate = coordinate
        }
        locationManager.startUpdatingLocation()
    }
}

extension SpotStore: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorizationStatus = manager.authorizationStatus
        startLocationTrackingIfAuthorized()
        if hasLocationAccess {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        userCoordinate = coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    }
}

enum HandoffRole {
    case leaving
    case arriving
}

enum DemoData {
    static let sampleSignals: [ParkingSpotSignal] = [
        ParkingSpotSignal(
            id: "spot-1",
            createdBy: "driver-a",
            claimedBy: nil,
            latitude: 37.7762,
            longitude: -122.4171,
            createdAt: .now.addingTimeInterval(-70),
            leavingAt: .now.addingTimeInterval(125),
            status: .posted
        ),
        ParkingSpotSignal(
            id: "spot-2",
            createdBy: "driver-b",
            claimedBy: "driver-c",
            latitude: 37.7731,
            longitude: -122.4218,
            createdAt: .now.addingTimeInterval(-120),
            leavingAt: .now.addingTimeInterval(320),
            status: .claimed
        ),
        ParkingSpotSignal(
            id: "spot-3",
            createdBy: "driver-d",
            claimedBy: nil,
            latitude: 37.7754,
            longitude: -122.4147,
            createdAt: .now.addingTimeInterval(-30),
            leavingAt: .now.addingTimeInterval(560),
            status: .posted
        )
    ]
}
