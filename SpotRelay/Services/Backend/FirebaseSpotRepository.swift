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

    private let cleanupThrottleInterval: TimeInterval = 20
    private let terminalRetentionInterval: TimeInterval = 60 * 60 * 6
    private let database = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var listeningTask: Task<Void, Never>?
    private var expiryCleanupTask: Task<Void, Never>?
    private var lastExpiryCleanupAt: Date?

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
        expiryCleanupTask?.cancel()
    }

    func seedPreviewSpotsIfNeeded(around coordinate: CLLocationCoordinate2D) {
    }

    func refreshStatuses(now: Date) {
        let normalizedSpots = spots
            .map { spot in
                guard spot.isActive, now >= spot.leavingAt else { return spot }
                var expired = spot
                expired.status = .expired
                return expired
            }
            .filter { spot in
                spot.isActive || spot.leavingAt > now.addingTimeInterval(-terminalRetentionInterval)
            }

        if normalizedSpots != spots {
            spots = normalizedSpots
        }

        scheduleExpiryCleanupIfNeeded(now: now)
    }

    func postSpot(createdBy: String, coordinate: CLLocationCoordinate2D, durationMinutes: Int, now: Date) async throws -> ParkingSpotSignal {
        try await ensureSignedInAnonymously()
        try await ensureNoActiveLeavingSignal(for: createdBy, now: now)

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
        try await ensureNoActiveClaim(for: userID, excluding: id, now: now)

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                if payload.requiresExpiry(at: now) {
                    transaction.updateData(payload.applyingStatus(.expired).statusPatch, forDocument: reference)
                    throw SpotRepositoryError.spotUnavailable
                }
                guard payload.createdBy != userID else {
                    throw SpotRepositoryError.cannotClaimOwnSpot
                }
                if payload.claimedBy == userID, (payload.status == .claimed || payload.status == .arriving) {
                    return payload
                }
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
                transaction.updateData(updatedPayload.claimPatch, forDocument: reference)
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
        let now = Date()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                if payload.requiresExpiry(at: now) {
                    transaction.updateData(payload.applyingStatus(.expired).statusPatch, forDocument: reference)
                    throw SpotRepositoryError.spotUnavailable
                }
                guard payload.claimedBy == userID else {
                    throw SpotRepositoryError.unauthorizedMutation
                }
                if payload.status == .arriving {
                    return payload
                }
                guard payload.status == .claimed else {
                    throw SpotRepositoryError.spotUnavailable
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
        let now = Date()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                let isOwner = payload.createdBy == userID
                let isClaimant = payload.claimedBy == userID
                let isParticipant = isOwner || isClaimant
                if isParticipant && payload.status == .cancelled {
                    return payload
                }
                if payload.requiresExpiry(at: now) {
                    transaction.updateData(payload.applyingStatus(.expired).statusPatch, forDocument: reference)
                    throw SpotRepositoryError.spotUnavailable
                }
                guard isParticipant else {
                    throw SpotRepositoryError.unauthorizedMutation
                }
                guard payload.isActive(at: now) else {
                    throw SpotRepositoryError.spotUnavailable
                }

                if isClaimant {
                    let updatedPayload = payload.releasingClaim()
                    transaction.updateData(updatedPayload.claimReleasePatch, forDocument: reference)
                    return updatedPayload
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
        let now = Date()

        let reference = spotsCollection.document(id)
        let result = try await database.runTransaction { transaction, errorPointer in
            do {
                let payload = try self.fetchDocument(reference: reference, transaction: transaction)
                let terminalStatus: SpotStatus = success ? .completed : .cancelled
                let isParticipant = payload.createdBy == userID || payload.claimedBy == userID
                if isParticipant && payload.status == terminalStatus {
                    return payload
                }
                if payload.requiresExpiry(at: now) {
                    transaction.updateData(payload.applyingStatus(.expired).statusPatch, forDocument: reference)
                    throw SpotRepositoryError.spotUnavailable
                }
                guard isParticipant else {
                    throw SpotRepositoryError.unauthorizedMutation
                }
                guard payload.isActive(at: now) else {
                    throw SpotRepositoryError.spotUnavailable
                }

                let updatedPayload = payload.applyingStatus(terminalStatus)
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
        let cutoff = Date().addingTimeInterval(-terminalRetentionInterval)
        listener = spotsCollection
            .whereField("leavingAt", isGreaterThan: cutoff)
            .order(by: "leavingAt", descending: true)
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

    private func scheduleExpiryCleanupIfNeeded(now: Date) {
        guard expiryCleanupTask == nil else { return }

        if let lastExpiryCleanupAt,
           now.timeIntervalSince(lastExpiryCleanupAt) < cleanupThrottleInterval {
            return
        }

        lastExpiryCleanupAt = now
        expiryCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.expiryCleanupTask = nil }
            try? await self.cleanupExpiredSpots(now: now)
        }
    }

    private func cleanupExpiredSpots(now: Date) async throws {
        let snapshot = try await getDocuments(
            spotsCollection
                .whereField("leavingAt", isLessThanOrEqualTo: now)
                .order(by: "leavingAt", descending: true)
                .limit(to: 50)
        )

        let expiredReferences = snapshot.documents.compactMap { document -> DocumentReference? in
            guard let payload = FirestoreSpotDocument(dictionary: document.data()),
                  payload.requiresExpiry(at: now) else {
                return nil
            }
            return document.reference
        }

        guard !expiredReferences.isEmpty else { return }

        let batch = database.batch()
        for reference in expiredReferences {
            batch.updateData(["status": SpotStatus.expired.rawValue], forDocument: reference)
        }
        try await commit(batch)
    }

    private func ensureNoActiveLeavingSignal(for userID: String, now: Date) async throws {
        let snapshot = try await getDocuments(
            spotsCollection
                .whereField("createdBy", isEqualTo: userID)
                .limit(to: 20)
        )

        let hasActiveSignal = snapshot.documents.contains { document in
            guard let payload = FirestoreSpotDocument(dictionary: document.data()) else { return false }
            return payload.createdBy == userID && payload.isActive(at: now)
        }

        guard !hasActiveSignal else {
            throw SpotRepositoryError.activeLeavingSignalExists
        }
    }

    private func ensureNoActiveClaim(for userID: String, excluding excludedSpotID: String, now: Date) async throws {
        let snapshot = try await getDocuments(
            spotsCollection
                .whereField("claimedBy", isEqualTo: userID)
                .limit(to: 20)
        )

        let hasOtherActiveClaim = snapshot.documents.contains { document in
            guard document.documentID != excludedSpotID,
                  let payload = FirestoreSpotDocument(dictionary: document.data()) else {
                return false
            }

            return payload.claimedBy == userID && payload.isActive(at: now)
        }

        guard !hasOtherActiveClaim else {
            throw SpotRepositoryError.activeClaimExists
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

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<QuerySnapshot, Error>) in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: SpotRepositoryError.handoffNotFound)
                }
            }
        }
    }

    private func commit(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
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
    let cleanupAt: Date?
    let status: SpotStatus

    private static let retentionInterval: TimeInterval = 60 * 60 * 24

    init(
        createdBy: String,
        claimedBy: String?,
        latitude: Double,
        longitude: Double,
        createdAt: Date,
        leavingAt: Date,
        cleanupAt: Date?,
        status: SpotStatus
    ) {
        self.createdBy = createdBy
        self.claimedBy = claimedBy
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.leavingAt = leavingAt
        self.cleanupAt = cleanupAt
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
        self.cleanupAt = Self.dateValue(from: dictionary["cleanupAt"])
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

        if let cleanupAt {
            data["cleanupAt"] = cleanupAt
        }

        return data
    }

    var statusPatch: [String: Any] {
        ["status": status.rawValue]
    }

    var claimPatch: [String: Any] {
        [
            "claimedBy": claimedBy as Any,
            "status": status.rawValue
        ]
    }

    var claimReleasePatch: [String: Any] {
        [
            "claimedBy": FieldValue.delete(),
            "status": status.rawValue
        ]
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

    func requiresExpiry(at now: Date) -> Bool {
        switch status {
        case .posted, .claimed, .arriving:
            return leavingAt <= now
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
            cleanupAt: cleanupAt,
            status: .claimed
        )
    }

    func releasingClaim() -> FirestoreSpotDocument {
        FirestoreSpotDocument(
            createdBy: createdBy,
            claimedBy: nil,
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt,
            leavingAt: leavingAt,
            cleanupAt: cleanupAt,
            status: .posted
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
            cleanupAt: cleanupAt,
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
            cleanupAt: signal.createdAt.addingTimeInterval(Self.retentionInterval),
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
