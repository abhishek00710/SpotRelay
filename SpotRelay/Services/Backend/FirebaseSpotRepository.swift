#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import Combine
import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import MapKit

@MainActor
final class FirebaseSpotRepository: SpotRepository {
    @Published private var spots: [ParkingSpotSignal] = []

    private let database = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var listeningTask: Task<Void, Never>?

    var spotsPublisher: AnyPublisher<[ParkingSpotSignal], Never> {
        $spots.eraseToAnyPublisher()
    }

    var currentSpots: [ParkingSpotSignal] {
        spots
    }

    init() {
        listeningTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureSignedInAnonymously()
                self.startListening()
            } catch {
            }
        }
    }

    deinit {
        listener?.remove()
        listeningTask?.cancel()
    }

    func seedPreviewSpotsIfNeeded(around coordinate: CLLocationCoordinate2D) {
    }

    func refreshStatuses(now: Date) {
    }

    func postSpot(createdBy: String, coordinate: CLLocationCoordinate2D, durationMinutes: Int, now: Date) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()

        let activeSignalExists = spots.contains {
            $0.createdBy == createdBy && $0.isActive
        }
        guard !activeSignalExists else {
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

        let document = FirestoreSpotDocument(signal: signal)
        try await setDocument(document.dictionary, at: spotsCollection.document(signal.id))
        return signal
    }

    func claimSpot(id: String, userID: String, userCoordinate: CLLocationCoordinate2D?, nearbySearchRadiusMeters: Int, now: Date) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                guard payload.isActive(at: now) else {
                    throw SpotRepositoryError.spotUnavailable
                }
                guard payload.status == .posted else {
                    throw SpotRepositoryError.spotUnavailable
                }
                if let userCoordinate, payload.distanceMeters(from: userCoordinate) > nearbySearchRadiusMeters {
                    throw SpotRepositoryError.outsideNearbyRadius
                }

                let updatedPayload = payload.applyingClaim(by: userID)
                transaction.setData(updatedPayload.dictionary, forDocument: reference)
                return updatedPayload
            } catch {
                errorPointer?.pointee = self.nsError(for: error)
                return nil
            }
        }

        guard let document = result as? FirestoreSpotDocument else {
            throw SpotRepositoryError.handoffNotFound
        }
        return document.model(id: id)
    }

    func markArrival(id: String, userID: String) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                guard payload.claimedBy == userID else {
                    throw SpotRepositoryError.unauthorizedMutation
                }

                let updatedPayload = payload.applyingStatus(.arriving)
                transaction.updateData(updatedPayload.statusPatch, forDocument: reference)
                return updatedPayload
            } catch {
                errorPointer?.pointee = self.nsError(for: error)
                return nil
            }
        }

        guard let document = result as? FirestoreSpotDocument else {
            throw SpotRepositoryError.handoffNotFound
        }
        return document.model(id: id)
    }

    func cancelHandoff(id: String, userID: String) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                guard payload.createdBy == userID || payload.claimedBy == userID else {
                    throw SpotRepositoryError.unauthorizedMutation
                }

                let updatedPayload = payload.applyingStatus(.cancelled)
                transaction.updateData(updatedPayload.statusPatch, forDocument: reference)
                return updatedPayload
            } catch {
                errorPointer?.pointee = self.nsError(for: error)
                return nil
            }
        }

        guard let document = result as? FirestoreSpotDocument else {
            throw SpotRepositoryError.handoffNotFound
        }
        return document.model(id: id)
    }

    func completeHandoff(id: String, userID: String, success: Bool) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                guard payload.createdBy == userID || payload.claimedBy == userID else {
                    throw SpotRepositoryError.unauthorizedMutation
                }

                let updatedPayload = payload.applyingStatus(success ? .completed : .cancelled)
                transaction.updateData(updatedPayload.statusPatch, forDocument: reference)
                return updatedPayload
            } catch {
                errorPointer?.pointee = self.nsError(for: error)
                return nil
            }
        }

        guard let document = result as? FirestoreSpotDocument else {
            throw SpotRepositoryError.handoffNotFound
        }
        return document.model(id: id)
    }

    private var spotsCollection: CollectionReference {
        database.collection("spots")
    }

    private func startListening() {
        listener?.remove()
        listener = spotsCollection
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot else { return }
                self.spots = snapshot.documents.compactMap { document in
                    guard let payload = FirestoreSpotDocument(dictionary: document.data()) else {
                        return nil
                    }
                    return payload.model(id: document.documentID)
                }
            }
    }

    private func ensureSignedInAnonymously() async throws {
        if Auth.auth().currentUser != nil {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Auth.auth().signInAnonymously { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setDocument(_ data: [String: Any], at reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func fetchDocument(reference: DocumentReference, transaction: Transaction) throws -> FirestoreSpotDocument {
        let snapshot: DocumentSnapshot
        do {
            try snapshot = transaction.getDocument(reference)
        } catch {
            throw error
        }

        guard snapshot.exists else {
            throw SpotRepositoryError.handoffNotFound
        }
        guard let data = snapshot.data(),
              let payload = FirestoreSpotDocument(dictionary: data) else {
            throw SpotRepositoryError.handoffNotFound
        }
        return payload
    }

    private func nsError(for error: Error) -> NSError {
        if let repositoryError = error as? SpotRepositoryError {
            return NSError(
                domain: "SpotRelay.FirebaseSpotRepository",
                code: repositoryError.hashValue,
                userInfo: [NSLocalizedDescriptionKey: repositoryError.localizedDescription]
            )
        }

        return error as NSError
    }
}

private struct FirestoreSpotDocument: Codable {
    let createdBy: String
    let claimedBy: String?
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let leavingAt: Date
    let status: SpotStatus

    init(
        createdBy: String,
        claimedBy: String?,
        latitude: Double,
        longitude: Double,
        createdAt: Date,
        leavingAt: Date,
        status: SpotStatus
    ) {
        self.createdBy = createdBy
        self.claimedBy = claimedBy
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.leavingAt = leavingAt
        self.status = status
    }

    init?(
        dictionary: [String: Any]
    ) {
        guard let createdBy = dictionary["createdBy"] as? String,
              let latitude = dictionary["latitude"] as? Double,
              let longitude = dictionary["longitude"] as? Double,
              let createdAt = Self.dateValue(from: dictionary["createdAt"]),
              let leavingAt = Self.dateValue(from: dictionary["leavingAt"]),
              let statusRawValue = dictionary["status"] as? String,
              let status = SpotStatus(rawValue: statusRawValue) else {
            return nil
        }

        self.createdBy = createdBy
        self.claimedBy = dictionary["claimedBy"] as? String
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.leavingAt = leavingAt
        self.status = status
    }

    var dictionary: [String: Any] {
        var data: [String: Any] = [
            "createdBy": createdBy,
            "latitude": latitude,
            "longitude": longitude,
            "createdAt": createdAt,
            "leavingAt": leavingAt,
            "status": status.rawValue
        ]

        if let claimedBy {
            data["claimedBy"] = claimedBy
        }

        return data
    }

    var statusPatch: [String: Any] {
        ["status": status.rawValue]
    }

    func model(id: String) -> ParkingSpotSignal {
        ParkingSpotSignal(
            id: id,
            createdBy: createdBy,
            claimedBy: claimedBy,
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt,
            leavingAt: leavingAt,
            status: status
        )
    }

    func isActive(at now: Date) -> Bool {
        switch status {
        case .posted, .claimed, .arriving:
            return leavingAt > now
        case .completed, .expired, .cancelled:
            return false
        }
    }

    func applyingClaim(by userID: String) -> FirestoreSpotDocument {
        FirestoreSpotDocument(
            createdBy: createdBy,
            claimedBy: userID,
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt,
            leavingAt: leavingAt,
            status: .claimed
        )
    }

    func applyingStatus(_ nextStatus: SpotStatus) -> FirestoreSpotDocument {
        FirestoreSpotDocument(
            createdBy: createdBy,
            claimedBy: claimedBy,
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt,
            leavingAt: leavingAt,
            status: nextStatus
        )
    }

    func distanceMeters(from coordinate: CLLocationCoordinate2D) -> Int {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let destination = CLLocation(latitude: latitude, longitude: longitude)
        return Int(origin.distance(from: destination).rounded())
    }

    init(signal: ParkingSpotSignal) {
        self.init(
            createdBy: signal.createdBy,
            claimedBy: signal.claimedBy,
            latitude: signal.latitude,
            longitude: signal.longitude,
            createdAt: signal.createdAt,
            leavingAt: signal.leavingAt,
            status: signal.status
        )
    }

    private static func dateValue(from value: Any?) -> Date? {
        switch value {
        case let date as Date:
            return date
        case let timestamp as Timestamp:
            return timestamp.dateValue()
        default:
            return nil
        }
    }
}
#endif
