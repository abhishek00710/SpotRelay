import Combine
import Foundation
import MapKit

enum SpotRepositoryError: LocalizedError, Equatable {
    case activeLeavingSignalExists
    case handoffNotFound
    case spotUnavailable
    case outsideNearbyRadius
    case unauthorizedMutation
    case backendNotConfigured

    var errorDescription: String? {
        switch self {
        case .activeLeavingSignalExists:
            return "You already have a live leaving handoff."
        case .handoffNotFound:
            return "That handoff could not be found."
        case .spotUnavailable:
            return "That spot is no longer available."
        case .outsideNearbyRadius:
            return "That spot is outside the nearby claim radius."
        case .unauthorizedMutation:
            return "This handoff action is no longer allowed."
        case .backendNotConfigured:
            return "The Firebase backend is not configured yet."
        }
    }
}

@MainActor
protocol SpotRepository: AnyObject {
    var spotsPublisher: AnyPublisher<[ParkingSpotSignal], Never> { get }
    var currentSpots: [ParkingSpotSignal] { get }

    func seedPreviewSpotsIfNeeded(around coordinate: CLLocationCoordinate2D)
    func refreshStatuses(now: Date)
    func postSpot(createdBy: String, coordinate: CLLocationCoordinate2D, durationMinutes: Int, now: Date) async throws -> ParkingSpotSignal
    func claimSpot(id: String, userID: String, userCoordinate: CLLocationCoordinate2D?, nearbySearchRadiusMeters: Int, now: Date) async throws -> ParkingSpotSignal
    func markArrival(id: String, userID: String) async throws -> ParkingSpotSignal
    func cancelHandoff(id: String, userID: String) async throws -> ParkingSpotSignal
    func completeHandoff(id: String, userID: String, success: Bool) async throws -> ParkingSpotSignal
}
