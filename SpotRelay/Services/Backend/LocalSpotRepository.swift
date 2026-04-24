import Combine
import Foundation
import MapKit

@MainActor
final class LocalSpotRepository: SpotRepository {
    @Published private var spots: [ParkingSpotSignal] = []
    private let terminalRetentionInterval: TimeInterval = 60 * 60 * 6
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
        spots = spots
            .map { spot in
                guard spot.isActive, now >= spot.leavingAt else { return spot }
                var expired = spot
                expired.status = .expired
                return expired
            }
            .filter { spot in
                spot.isActive || spot.leavingAt > now.addingTimeInterval(-terminalRetentionInterval)
            }
    }

    func postSpot(createdBy: String, coordinate: CLLocationCoordinate2D, durationMinutes: Int, now: Date) async throws -> ParkingSpotSignal {
        refreshStatuses(now: now)

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
        guard spots[index].createdBy != userID else {
            throw SpotRepositoryError.cannotClaimOwnSpot
        }
        guard activeClaimSignal(claimedBy: userID, excluding: id) == nil else {
            throw SpotRepositoryError.activeClaimExists
        }
        if spots[index].claimedBy == userID, spots[index].status == .claimed {
            return spots[index]
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
        refreshStatuses(now: .now)

        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].isActive else {
            throw SpotRepositoryError.spotUnavailable
        }
        guard spots[index].claimedBy == userID else {
            throw SpotRepositoryError.unauthorizedMutation
        }

        spots[index].status = .arriving
        return spots[index]
    }

    func cancelHandoff(id: String, userID: String) async throws -> ParkingSpotSignal {
        refreshStatuses(now: .now)

        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].isActive else {
            throw SpotRepositoryError.spotUnavailable
        }
        guard spots[index].createdBy == userID || spots[index].claimedBy == userID else {
            throw SpotRepositoryError.unauthorizedMutation
        }

        if spots[index].claimedBy == userID {
            spots[index].claimedBy = nil
            spots[index].status = .posted
        } else {
            spots[index].status = .cancelled
        }
        return spots[index]
    }

    func completeHandoff(id: String, userID: String, success: Bool) async throws -> ParkingSpotSignal {
        refreshStatuses(now: .now)

        guard let index = spots.firstIndex(where: { $0.id == id }) else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard spots[index].isActive else {
            throw SpotRepositoryError.spotUnavailable
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

    private func activeClaimSignal(claimedBy userID: String, excluding excludedSpotID: String? = nil) -> ParkingSpotSignal? {
        spots.first {
            $0.isActive &&
            $0.claimedBy == userID &&
            $0.id != excludedSpotID
        }
    }
}

enum PreviewSignalSeed {
    static func signals(around coordinate: CLLocationCoordinate2D) -> [ParkingSpotSignal] {
        // Temporary local-only mock handoffs for UI/demo testing.
        // Remove this whole `seeds` array block later if you no longer want preview spots.
        let seeds: [(id: String, createdBy: String, claimedBy: String?, latOffset: Double, lonOffset: Double, createdAgo: TimeInterval, leavingIn: TimeInterval, status: SpotStatus)] = [
            ("mock-spot-1", "driver-a", nil, 0.0008, -0.0005, 70, 125, .posted),
            ("mock-spot-2", "driver-b", "driver-c", -0.0011, 0.0009, 120, 320, .claimed),
            ("mock-spot-3", "driver-d", nil, 0.0005, 0.0014, 30, 560, .posted)
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
