import Combine
import Foundation
import MapKit

@MainActor
final class LocalSpotRepository: SpotRepository {
    @Published private var spots: [ParkingSpotSignal] = []
    private var hasSeededPreviewSpots = false

    var spotsPublisher: AnyPublisher<[ParkingSpotSignal], Never> {
        $spots.eraseToAnyPublisher()
    }

    var currentSpots: [ParkingSpotSignal] {
        spots
    }

    func seedPreviewSpotsIfNeeded(around coordinate: CLLocationCoordinate2D) {
        guard !hasSeededPreviewSpots, spots.isEmpty else { return }
        spots = PreviewSignalSeed.signals(around: coordinate)
        hasSeededPreviewSpots = true
    }

    func refreshStatuses(now: Date) {
        spots = spots.map { spot in
            guard spot.isActive, now >= spot.leavingAt else { return spot }
            var expired = spot
            expired.status = .expired
            return expired
        }
    }

    func postSpot(createdBy: String, coordinate: CLLocationCoordinate2D, durationMinutes: Int, now: Date) async throws -> ParkingSpotSignal {
        guard activeLeavingSignal(createdBy: createdBy) == nil else {
            throw SpotRepositoryError.activeLeavingSignalExists
        }

        let signal = ParkingSpotSignal(
            id: UUID().uuidString,
            createdBy: createdBy,
            claimedBy: nil,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: now,
            leavingAt: Calendar.current.date(byAdding: .minute, value: durationMinutes, to: now) ?? now,
            status: .posted
        )

        spots.insert(signal, at: 0)
        return signal
    }

    func claimSpot(id: String, userID: String, userCoordinate: CLLocationCoordinate2D?, nearbySearchRadiusMeters: Int, now: Date) async throws -> ParkingSpotSignal {
        refreshStatuses(now: now)

        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].status == .posted else {
            throw SpotRepositoryError.spotUnavailable
        }
        if let userCoordinate, spots[index].distanceMeters(from: userCoordinate) > nearbySearchRadiusMeters {
            throw SpotRepositoryError.outsideNearbyRadius
        }

        spots[index].claimedBy = userID
        spots[index].status = .claimed
        return spots[index]
    }

    func markArrival(id: String, userID: String) async throws -> ParkingSpotSignal {
        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].claimedBy == userID else {
            throw SpotRepositoryError.unauthorizedMutation
        }

        spots[index].status = .arriving
        return spots[index]
    }

    func cancelHandoff(id: String, userID: String) async throws -> ParkingSpotSignal {
        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].createdBy == userID || spots[index].claimedBy == userID else {
            throw SpotRepositoryError.unauthorizedMutation
        }

        spots[index].status = .cancelled
        return spots[index]
    }

    func completeHandoff(id: String, userID: String, success: Bool) async throws -> ParkingSpotSignal {
        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].createdBy == userID || spots[index].claimedBy == userID else {
            throw SpotRepositoryError.unauthorizedMutation
        }

        spots[index].status = success ? .completed : .cancelled
        return spots[index]
    }

    private func activeLeavingSignal(createdBy userID: String) -> ParkingSpotSignal? {
        spots.first { $0.isActive && $0.createdBy == userID }
    }
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
