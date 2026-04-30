import CoreLocation
import CoreMotion
import Foundation

struct ParkingCaptureEvent {
    enum Source: String, Codable, Equatable {
        case vehicleDisconnect
        case motionSettled
        case locationDwell
        case visitSettled

        var label: String {
            switch self {
            case .vehicleDisconnect:
                "car disconnected"
            case .motionSettled:
                "motion settled"
            case .locationDwell:
                "location dwell"
            case .visitSettled:
                "visit settled"
            }
        }
    }

    let location: CLLocation
    let parkedAt: Date
    let confidenceScore: Int
    let evidence: [String]
    let source: Source

    var evidenceSummary: String {
        evidence.joined(separator: " + ")
    }
}

struct ParkingCaptureSnapshot: Equatable {
    enum Phase: String {
        case idle
        case driving
        case parkedCandidate
    }

    let phase: Phase
    let sampleCount: Int
    let bestAccuracyMeters: Double?
    let driveDistanceMeters: Double
    let lastSpeedMetersPerSecond: Double?
    let lastReason: String
    let updatedAt: Date?
}

struct ParkingCaptureEngine {
    private struct Sample {
        let location: CLLocation

        var timestamp: Date {
            location.timestamp
        }
    }

    private struct Session {
        let startedAt: Date
        var samples: [Sample]
        var evidence: Set<String>
        var vehicleSignalSeen: Bool
        var sawDrivingMotion: Bool
        var distanceMeters: CLLocationDistance
        var lastMovingAt: Date
        var stoppedSince: Date?
        var lastSpeedMetersPerSecond: CLLocationSpeed?

        var duration: TimeInterval {
            Date().timeIntervalSince(startedAt)
        }

        var isQualifiedDrive: Bool {
            sawDrivingMotion || distanceMeters >= ParkingCaptureEngine.minimumDriveDistanceMeters
        }
    }

    private var session: Session?
    private var recentSamples: [Sample] = []
    private var lastReason = "Waiting for a drive"
    private var updatedAt: Date?

    private static let minimumDriveSpeedMetersPerSecond: CLLocationSpeed = 7.0
    private static let movingSpeedMetersPerSecond: CLLocationSpeed = 3.0
    private static let stoppedSpeedMetersPerSecond: CLLocationSpeed = 1.4
    private static let maximumUsefulAccuracyMeters: CLLocationAccuracy = 80
    private static let maximumParkingAccuracyMeters: CLLocationAccuracy = 35
    private static let idealParkingAccuracyMeters: CLLocationAccuracy = 18
    private static let maximumWalkingSpeedMetersPerSecond: CLLocationSpeed = 3.2
    private static let recentSampleRetention: TimeInterval = 10 * 60
    private static let sessionSampleRetention: TimeInterval = 30 * 60
    private static let parkingWindowBeforeEvent: TimeInterval = 3 * 60
    private static let parkingWindowAfterEvent: TimeInterval = 25
    private static let stoppedDwellDuration: TimeInterval = 90
    private static let minimumDriveDuration: TimeInterval = 2 * 60
    private static let minimumDriveDistanceMeters: CLLocationDistance = 250
    private static let maximumSamples = 180
    private static let minimumSaveConfidence = 75

    var snapshot: ParkingCaptureSnapshot {
        let activeSession = session
        let bestAccuracy = activeSession?.samples
            .map(\.location.horizontalAccuracy)
            .filter { $0 >= 0 }
            .min()

        return ParkingCaptureSnapshot(
            phase: activeSession == nil ? .idle : (activeSession?.stoppedSince == nil ? .driving : .parkedCandidate),
            sampleCount: activeSession?.samples.count ?? recentSamples.count,
            bestAccuracyMeters: bestAccuracy,
            driveDistanceMeters: activeSession?.distanceMeters ?? 0,
            lastSpeedMetersPerSecond: activeSession?.lastSpeedMetersPerSecond,
            lastReason: lastReason,
            updatedAt: updatedAt
        )
    }

    mutating func reset(reason: String = "Reset") {
        session = nil
        recentSamples.removeAll()
        lastReason = reason
        updatedAt = .now
    }

    mutating func vehicleConnected(summary: String, at date: Date = .now) {
        updatedAt = date
        ensureSession(startedAt: date, evidence: "vehicle signal")
        session?.vehicleSignalSeen = true
        session?.evidence.insert(summary)
        lastReason = "Vehicle signal connected"
    }

    mutating func vehicleDisconnected(summary: String, at date: Date = .now) -> ParkingCaptureEvent? {
        updatedAt = date
        guard var activeSession = session else {
            lastReason = "Vehicle disconnected before a drive session"
            return nil
        }

        activeSession.vehicleSignalSeen = true
        activeSession.evidence.insert(summary)
        activeSession.evidence.insert("vehicle disconnected")
        session = activeSession
        return finalize(source: .vehicleDisconnect, parkedAt: date, reason: "Vehicle disconnected")
    }

    mutating func ingest(activity: CMMotionActivity, at receivedAt: Date = .now) -> ParkingCaptureEvent? {
        updatedAt = receivedAt

        if activity.automotive, activity.confidence != .low {
            ensureSession(startedAt: activity.startDate, evidence: "automotive motion")
            if activity.confidence == .high {
                session?.evidence.insert("high-confidence automotive motion")
            }
            if var activeSession = session {
                activeSession.lastMovingAt = max(activeSession.lastMovingAt, activity.startDate)
                activeSession.sawDrivingMotion = true
                activeSession.stoppedSince = nil
                session = activeSession
            }
            lastReason = "Driving motion detected"
            return nil
        }

        guard session != nil else { return nil }

        if activity.stationary, activity.confidence != .low {
            session?.evidence.insert("stationary after drive")
            return settleIfQualified(since: activity.startDate, receivedAt: receivedAt, source: .motionSettled)
        }

        if activity.walking, activity.confidence != .low {
            session?.evidence.insert("walking after parking")
            return settleIfQualified(since: activity.startDate, receivedAt: receivedAt, source: .motionSettled)
        }

        return nil
    }

    mutating func ingest(locations: [CLLocation]) -> ParkingCaptureEvent? {
        let usefulLocations = locations.filter(isUsefulLocation)
        guard !usefulLocations.isEmpty else { return nil }

        updatedAt = usefulLocations.last?.timestamp ?? .now
        var detectedEvent: ParkingCaptureEvent?

        for location in usefulLocations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let sample = Sample(location: location)
            appendRecentSample(sample)

            if shouldStartDrive(from: location) {
                ensureSession(startedAt: location.timestamp, evidence: "driving speed")
            }

            guard session != nil else { continue }

            appendSessionSample(sample)
            updateSessionDistance(with: location)
            updateMotionFromSpeed(location)

            if detectedEvent == nil {
                detectedEvent = settleFromLocationDwellIfReady(at: location.timestamp)
            }
        }

        return detectedEvent
    }

    mutating func ingest(visit: CLVisit, at date: Date = .now) -> ParkingCaptureEvent? {
        updatedAt = date
        guard session != nil else {
            lastReason = "Visit received without drive trail"
            return nil
        }

        session?.evidence.insert("arrival visit")
        return settleIfQualified(since: visit.arrivalDate, receivedAt: date, source: .visitSettled)
    }

    private mutating func ensureSession(startedAt: Date, evidence: String) {
        if session == nil {
            let initialSamples = recentSamples.filter {
                startedAt.timeIntervalSince($0.timestamp) <= Self.recentSampleRetention
            }
            session = Session(
                startedAt: startedAt,
                samples: initialSamples,
                evidence: [evidence],
                vehicleSignalSeen: false,
                sawDrivingMotion: evidence == "automotive motion" || evidence == "driving speed",
                distanceMeters: 0,
                lastMovingAt: startedAt,
                stoppedSince: nil,
                lastSpeedMetersPerSecond: nil
            )
        } else {
            session?.evidence.insert(evidence)
        }
    }

    private mutating func appendRecentSample(_ sample: Sample) {
        recentSamples.append(sample)
        recentSamples = recentSamples
            .filter { sample.timestamp.timeIntervalSince($0.timestamp) <= Self.recentSampleRetention }
        recentSamples = Array(recentSamples.suffix(Self.maximumSamples))
    }

    private mutating func appendSessionSample(_ sample: Sample) {
        guard var activeSession = session else { return }

        activeSession.samples.append(sample)
        activeSession.samples = activeSession.samples
            .filter { sample.timestamp.timeIntervalSince($0.timestamp) <= Self.sessionSampleRetention }
        activeSession.samples = Array(activeSession.samples.suffix(Self.maximumSamples))
        session = activeSession
    }

    private mutating func updateSessionDistance(with location: CLLocation) {
        guard let previous = session?.samples.dropLast().last?.location else { return }
        let distance = location.distance(from: previous)
        guard distance.isFinite, distance > 0, distance < 300 else { return }
        session?.distanceMeters += distance
    }

    private mutating func updateMotionFromSpeed(_ location: CLLocation) {
        guard location.speed >= 0 else { return }
        session?.lastSpeedMetersPerSecond = location.speed

        if location.speed >= Self.movingSpeedMetersPerSecond {
            session?.lastMovingAt = location.timestamp
            session?.stoppedSince = nil
            if location.speed >= Self.minimumDriveSpeedMetersPerSecond {
                session?.evidence.insert("driving speed")
                session?.sawDrivingMotion = true
            }
            return
        }

        if location.speed <= Self.stoppedSpeedMetersPerSecond {
            if session?.stoppedSince == nil {
                session?.stoppedSince = location.timestamp
            }
            session?.evidence.insert("speed settled")
        }
    }

    private mutating func settleIfQualified(
        since settledAt: Date,
        receivedAt: Date,
        source: ParkingCaptureEvent.Source
    ) -> ParkingCaptureEvent? {
        guard let activeSession = session, activeSession.isQualifiedDrive else {
            lastReason = "Ignoring stop: drive not qualified yet"
            return nil
        }

        let dwellTime = receivedAt.timeIntervalSince(settledAt)
        guard dwellTime >= 20 || source == .visitSettled else {
            lastReason = "Waiting for stop to settle"
            return nil
        }

        return finalize(source: source, parkedAt: settledAt, reason: source.label)
    }

    private mutating func settleFromLocationDwellIfReady(at date: Date) -> ParkingCaptureEvent? {
        guard let activeSession = session, activeSession.isQualifiedDrive else { return nil }
        guard let stoppedSince = activeSession.stoppedSince else { return nil }
        guard date.timeIntervalSince(stoppedSince) >= Self.stoppedDwellDuration else {
            lastReason = "Parking candidate: waiting for dwell"
            return nil
        }
        return finalize(source: .locationDwell, parkedAt: stoppedSince, reason: "Location dwell complete")
    }

    private mutating func finalize(
        source: ParkingCaptureEvent.Source,
        parkedAt: Date,
        reason: String
    ) -> ParkingCaptureEvent? {
        guard let activeSession = session else { return nil }
        guard let location = bestParkingLocation(from: activeSession, parkedAt: parkedAt) else {
            lastReason = "Skipped save: no accurate final GPS fix"
            return nil
        }

        let confidenceScore = confidence(for: activeSession, location: location, source: source)
        guard confidenceScore >= Self.minimumSaveConfidence else {
            lastReason = "Skipped save: low confidence \(confidenceScore)"
            return nil
        }

        var evidence = Array(activeSession.evidence).sorted()
        evidence.append(source.label)
        evidence.append("GPS ±\(Int(location.horizontalAccuracy.rounded()))m")

        let event = ParkingCaptureEvent(
            location: location,
            parkedAt: parkedAt,
            confidenceScore: confidenceScore,
            evidence: evidence,
            source: source
        )

        session = nil
        lastReason = "Saved parked spot: \(reason)"
        return event
    }

    private func bestParkingLocation(from session: Session, parkedAt: Date) -> CLLocation? {
        let earliest = parkedAt.addingTimeInterval(-Self.parkingWindowBeforeEvent)
        let latest = parkedAt.addingTimeInterval(Self.parkingWindowAfterEvent)

        let candidates = session.samples
            .map(\.location)
            .filter { location in
                guard location.horizontalAccuracy >= 0 else { return false }
                guard location.horizontalAccuracy <= Self.maximumParkingAccuracyMeters else { return false }
                guard location.timestamp >= earliest, location.timestamp <= latest else { return false }
                if location.speed >= 0, location.speed > Self.maximumWalkingSpeedMetersPerSecond {
                    return location.timestamp <= parkedAt
                }
                return true
            }

        return candidates.min { lhs, rhs in
            score(location: lhs, parkedAt: parkedAt) < score(location: rhs, parkedAt: parkedAt)
        }
    }

    private func confidence(
        for session: Session,
        location: CLLocation,
        source: ParkingCaptureEvent.Source
    ) -> Int {
        var score = 48

        if location.horizontalAccuracy <= Self.idealParkingAccuracyMeters {
            score += 20
        } else if location.horizontalAccuracy <= Self.maximumParkingAccuracyMeters {
            score += 12
        }

        if session.vehicleSignalSeen {
            score += 18
        }

        if session.distanceMeters >= Self.minimumDriveDistanceMeters {
            score += 8
        }

        if session.duration >= Self.minimumDriveDuration {
            score += 6
        }

        switch source {
        case .vehicleDisconnect:
            score += 14
        case .motionSettled:
            score += 10
        case .locationDwell:
            score += 8
        case .visitSettled:
            score += 4
        }

        return min(score, 100)
    }

    private func score(location: CLLocation, parkedAt: Date) -> Double {
        let timeDistance = abs(location.timestamp.timeIntervalSince(parkedAt))
        let speedPenalty = max(location.speed, 0) * 8
        let afterParkingPenalty = location.timestamp > parkedAt ? 8 : 0
        return (location.horizontalAccuracy * 2.7) + (timeDistance * 0.55) + speedPenalty + Double(afterParkingPenalty)
    }

    private func shouldStartDrive(from location: CLLocation) -> Bool {
        guard location.horizontalAccuracy <= Self.maximumUsefulAccuracyMeters else { return false }
        guard location.speed >= Self.minimumDriveSpeedMetersPerSecond else { return false }
        return true
    }

    private func isUsefulLocation(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }
        guard location.horizontalAccuracy <= Self.maximumUsefulAccuracyMeters else { return false }
        guard abs(location.timestamp.timeIntervalSinceNow) <= Self.sessionSampleRetention else { return false }
        return true
    }
}
