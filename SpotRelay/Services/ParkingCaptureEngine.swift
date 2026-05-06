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

    private struct LocationSelection {
        let location: CLLocation
        let evidence: [String]
    }

    private struct Session {
        let startedAt: Date
        var samples: [Sample]
        var evidence: Set<String>
        var seenVehicleSignals: Set<String>
        var activeVehicleSignals: Set<String>
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

        var vehicleSignalSeen: Bool {
            !seenVehicleSignals.isEmpty
        }

        var vehicleConnectionActive: Bool {
            !activeVehicleSignals.isEmpty
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
    private static let maximumParkingAccuracyMeters: CLLocationAccuracy = 28
    private static let requiredAutoSaveAccuracyMeters: CLLocationAccuracy = 24
    private static let idealParkingAccuracyMeters: CLLocationAccuracy = 12
    private static let maximumWalkingSpeedMetersPerSecond: CLLocationSpeed = 3.2
    private static let recentSampleRetention: TimeInterval = 10 * 60
    private static let sessionSampleRetention: TimeInterval = 30 * 60
    private static let parkingWindowBeforeEvent: TimeInterval = 3 * 60
    private static let parkingWindowAfterEvent: TimeInterval = 16
    private static let disconnectPostStopCandidateWindow: TimeInterval = 5
    private static let stoppedDwellDuration: TimeInterval = 90
    private static let minimumDriveDuration: TimeInterval = 2 * 60
    private static let minimumDriveDistanceMeters: CLLocationDistance = 250
    private static let maximumSamples = 180
    private static let minimumSaveConfidence = 75
    private static let clusteredStopRadiusMeters: CLLocationDistance = 18
    private static let clusteredStopMinimumSupport = 2
    private static let preferredStopWindowBeforeParkedAt: TimeInterval = 28
    private static let preferredStopWindowAfterParkedAt: TimeInterval = 4

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
        session?.seenVehicleSignals.insert(summary)
        session?.activeVehicleSignals.insert(summary)
        session?.evidence.insert(summary)
        lastReason = "Vehicle signal connected"
    }

    mutating func vehicleDisconnected(summary: String, at date: Date = .now) -> ParkingCaptureEvent? {
        updatedAt = date
        guard var activeSession = session else {
            lastReason = "Vehicle disconnected before a drive session"
            return nil
        }

        activeSession.seenVehicleSignals.insert(summary)
        activeSession.activeVehicleSignals.remove(summary)
        activeSession.evidence.insert(summary)
        activeSession.evidence.insert("vehicle disconnected")
        session = activeSession
        guard activeSession.activeVehicleSignals.isEmpty else {
            lastReason = "One vehicle signal disconnected, but another is still active"
            return nil
        }
        let parkedAt = activeSession.stoppedSince ?? date
        return finalize(
            source: .vehicleDisconnect,
            parkedAt: parkedAt,
            selectionEnd: date,
            reason: "Vehicle disconnected"
        )
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
                seenVehicleSignals: [],
                activeVehicleSignals: [],
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

        if activeSession.vehicleConnectionActive, source == .visitSettled {
            lastReason = "Deferring visit settle while vehicle connection is still active"
            return nil
        }

        return finalize(
            source: source,
            parkedAt: settledAt,
            selectionEnd: receivedAt,
            reason: source.label
        )
    }

    private mutating func settleFromLocationDwellIfReady(at date: Date) -> ParkingCaptureEvent? {
        guard let activeSession = session, activeSession.isQualifiedDrive else { return nil }
        guard let stoppedSince = activeSession.stoppedSince else { return nil }
        guard date.timeIntervalSince(stoppedSince) >= Self.stoppedDwellDuration else {
            lastReason = "Parking candidate: waiting for dwell"
            return nil
        }
        if activeSession.vehicleConnectionActive {
            lastReason = "Parking candidate: vehicle signal still active"
            return nil
        }
        return finalize(
            source: .locationDwell,
            parkedAt: stoppedSince,
            selectionEnd: date,
            reason: "Location dwell complete"
        )
    }

    private mutating func finalize(
        source: ParkingCaptureEvent.Source,
        parkedAt: Date,
        selectionEnd: Date,
        reason: String
    ) -> ParkingCaptureEvent? {
        guard let activeSession = session else { return nil }
        guard let selection = bestParkingLocation(
            from: activeSession,
            parkedAt: parkedAt,
            selectionEnd: selectionEnd,
            source: source
        ) else {
            lastReason = "Skipped save: no accurate final GPS fix"
            return nil
        }

        guard selection.location.horizontalAccuracy <= Self.requiredAutoSaveAccuracyMeters else {
            lastReason = "Skipped save: GPS still too wide at ±\(Int(selection.location.horizontalAccuracy.rounded()))m"
            return nil
        }

        let confidenceScore = confidence(for: activeSession, location: selection.location, source: source)
        guard confidenceScore >= Self.minimumSaveConfidence else {
            lastReason = "Skipped save: low confidence \(confidenceScore)"
            return nil
        }

        var evidence = Array(activeSession.evidence).sorted()
        evidence.append(source.label)
        evidence.append(contentsOf: selection.evidence)
        evidence.append("GPS ±\(Int(selection.location.horizontalAccuracy.rounded()))m")

        let event = ParkingCaptureEvent(
            location: selection.location,
            parkedAt: parkedAt,
            confidenceScore: confidenceScore,
            evidence: evidence,
            source: source
        )

        session = nil
        lastReason = "Saved parked spot: \(reason)"
        return event
    }

    private func bestParkingLocation(
        from session: Session,
        parkedAt: Date,
        selectionEnd: Date,
        source: ParkingCaptureEvent.Source
    ) -> LocationSelection? {
        let earliest = parkedAt.addingTimeInterval(-Self.parkingWindowBeforeEvent)
        let latest = max(
            parkedAt.addingTimeInterval(Self.parkingWindowAfterEvent),
            min(selectionEnd, parkedAt.addingTimeInterval(Self.stoppedDwellDuration + Self.parkingWindowAfterEvent))
        )

        let candidates = session.samples
            .map(\.location)
            .filter { location in
                guard location.horizontalAccuracy >= 0 else { return false }
                guard location.horizontalAccuracy <= Self.maximumParkingAccuracyMeters else { return false }
                guard location.timestamp >= earliest, location.timestamp <= latest else { return false }
                if source == .vehicleDisconnect, location.timestamp > parkedAt {
                    let secondsAfterStop = location.timestamp.timeIntervalSince(parkedAt)
                    guard secondsAfterStop <= Self.disconnectPostStopCandidateWindow else {
                        return false
                    }
                    if location.speed >= 0, location.speed > Self.stoppedSpeedMetersPerSecond {
                        return false
                    }
                }
                if location.speed >= 0, location.speed > Self.maximumWalkingSpeedMetersPerSecond {
                    return location.timestamp <= parkedAt
                }
                return true
            }

        guard !candidates.isEmpty else { return nil }

        let lowSpeedCandidates = candidates.filter {
            $0.speed < 0 || $0.speed <= Self.stoppedSpeedMetersPerSecond
        }
        let preferredStopCandidates = lowSpeedCandidates.filter { location in
            location.timestamp >= parkedAt.addingTimeInterval(-Self.preferredStopWindowBeforeParkedAt)
            && location.timestamp <= parkedAt.addingTimeInterval(Self.preferredStopWindowAfterParkedAt)
        }

        let clusteredPreferredCandidates = preferredStopCandidates.filter {
            clusterSupportCount(for: $0, in: preferredStopCandidates) >= Self.clusteredStopMinimumSupport
        }

        let prioritizedCandidates: [CLLocation]
        let selectionEvidence: [String]
        if !clusteredPreferredCandidates.isEmpty {
            prioritizedCandidates = clusteredPreferredCandidates
            selectionEvidence = ["clustered low-speed stop point"]
        } else if !preferredStopCandidates.isEmpty {
            prioritizedCandidates = preferredStopCandidates
            selectionEvidence = ["preferred final stop window"]
        } else if !lowSpeedCandidates.isEmpty {
            prioritizedCandidates = lowSpeedCandidates
            selectionEvidence = ["low-speed stop point"]
        } else {
            prioritizedCandidates = candidates
            selectionEvidence = ["fallback stop sample"]
        }

        let clusterAnchor = clusterAnchor(for: prioritizedCandidates)
        guard let bestLocation = prioritizedCandidates.min(by: { lhs, rhs in
            score(
                location: lhs,
                parkedAt: parkedAt,
                selectionEnd: latest,
                source: source,
                clusterAnchor: clusterAnchor,
                clusterSupport: clusterSupportCount(for: lhs, in: prioritizedCandidates)
            ) < score(
                location: rhs,
                parkedAt: parkedAt,
                selectionEnd: latest,
                source: source,
                clusterAnchor: clusterAnchor,
                clusterSupport: clusterSupportCount(for: rhs, in: prioritizedCandidates)
            )
        }) else {
            return nil
        }

        return LocationSelection(location: bestLocation, evidence: selectionEvidence)
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

        if session.evidence.contains("vehicle-signal:carplay") {
            score += 34
        } else if session.evidence.contains("vehicle-signal:corebluetooth") {
            score += 24
        } else if session.vehicleSignalSeen {
            score += 16
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

    private func score(
        location: CLLocation,
        parkedAt: Date,
        selectionEnd: Date,
        source: ParkingCaptureEvent.Source,
        clusterAnchor: CLLocation?,
        clusterSupport: Int
    ) -> Double {
        let timeDistance: TimeInterval
        let afterParkingPenalty: Double
        if source == .locationDwell, location.timestamp >= parkedAt {
            timeDistance = max(0, selectionEnd.timeIntervalSince(location.timestamp)) * 0.12
            afterParkingPenalty = location.timestamp > parkedAt ? 6 : 0
        } else if source == .vehicleDisconnect, location.timestamp > parkedAt {
            let secondsAfterStop = location.timestamp.timeIntervalSince(parkedAt)
            timeDistance = secondsAfterStop * 1.35
            afterParkingPenalty = 40 + min(secondsAfterStop, 10) * 4.2
        } else {
            timeDistance = abs(location.timestamp.timeIntervalSince(parkedAt)) * 0.42
            afterParkingPenalty = location.timestamp > parkedAt ? 14 : 0
        }
        let speedPenalty = max(location.speed, 0) * 11
        let clusterDistancePenalty: Double
        if let clusterAnchor {
            clusterDistancePenalty = location.distance(from: clusterAnchor) * 1.4
        } else {
            clusterDistancePenalty = 0
        }
        let supportBonus = Double(max(clusterSupport - 1, 0)) * 18
        let lowSpeedBonus = (location.speed < 0 || location.speed <= Self.stoppedSpeedMetersPerSecond) ? 10.0 : 0
        return (location.horizontalAccuracy * 3.1)
            + timeDistance
            + speedPenalty
            + afterParkingPenalty
            + clusterDistancePenalty
            - supportBonus
            - lowSpeedBonus
    }

    private func clusterSupportCount(for location: CLLocation, in candidates: [CLLocation]) -> Int {
        candidates.reduce(into: 0) { count, candidate in
            guard candidate.distance(from: location) <= Self.clusteredStopRadiusMeters else { return }
            count += 1
        }
    }

    private func clusterAnchor(for candidates: [CLLocation]) -> CLLocation? {
        guard !candidates.isEmpty else { return nil }

        let latitude = candidates.map(\.coordinate.latitude).reduce(0, +) / Double(candidates.count)
        let longitude = candidates.map(\.coordinate.longitude).reduce(0, +) / Double(candidates.count)
        let bestAccuracy = candidates.map(\.horizontalAccuracy).filter { $0 >= 0 }.min() ?? Self.maximumParkingAccuracyMeters
        let latestTimestamp = candidates.map(\.timestamp).max() ?? .now
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: bestAccuracy,
            verticalAccuracy: -1,
            timestamp: latestTimestamp
        )
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
