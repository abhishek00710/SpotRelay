import Combine
import Foundation
import MapKit

enum SpotRepositoryError: LocalizedError, Equatable {
    case activeLeavingSignalExists
    case activeClaimExists
    case handoffNotFound
    case spotUnavailable
    case outsideNearbyRadius
    case cannotClaimOwnSpot
    case unauthorizedMutation
    case backendNotConfigured

    var errorDescription: String? {
        switch self {
        case .activeLeavingSignalExists:
            return L10n.tr("You already have a live leaving handoff.")
        case .activeClaimExists:
            return L10n.tr("You already have an active claimed handoff.")
        case .handoffNotFound:
            return L10n.tr("That handoff could not be found.")
        case .spotUnavailable:
            return L10n.tr("That spot is no longer available.")
        case .outsideNearbyRadius:
            return L10n.tr("That spot is outside the nearby claim radius.")
        case .cannotClaimOwnSpot:
            return L10n.tr("You can't claim your own parking handoff.")
        case .unauthorizedMutation:
            return L10n.tr("This handoff action is no longer allowed.")
        case .backendNotConfigured:
            return L10n.tr("The Firebase backend is not configured yet.")
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
