import AVFAudio
import Combine
import CoreLocation
import CoreMotion
import Foundation
import MapKit
import UIKit

@MainActor
final class SmartParkingStore: NSObject, ObservableObject {
    enum Status: Equatable {
        case disabled
        case monitoring
        case needsAlwaysLocation
        case needsMotionAccess
        case unsupported

        var badgeTitle: String {
            switch self {
            case .disabled:
                return "Off"
            case .monitoring:
                return "On"
            case .needsAlwaysLocation, .needsMotionAccess:
                return "Limited"
            case .unsupported:
                return "Unavailable"
            }
        }
    }

    enum ConfidenceLevel: Int, Codable, Equatable, Comparable {
        case low = 1
        case medium = 2
        case high = 3
        case veryHigh = 4

        static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        init(score: Int) {
            switch score {
            case 85...:
                self = .veryHigh
            case 70...:
                self = .high
            case 55...:
                self = .medium
            default:
                self = .low
            }
        }

        var badgeTitle: String {
            switch self {
            case .low:
                return "Low confidence"
            case .medium:
                return "Medium confidence"
            case .high:
                return "High confidence"
            case .veryHigh:
                return "Very high confidence"
            }
        }
    }

    struct AutoArmRecord: Codable, Equatable {
        let armedAt: Date
        let latitude: Double
        let longitude: Double
        let areaLabel: String?
        let confidenceScore: Int?
        let evidenceSummary: String?

        var confidenceLevel: ConfidenceLevel? {
            guard let confidenceScore else { return nil }
            return ConfidenceLevel(score: confidenceScore)
        }
    }

    struct ConfidenceAssessment: Codable, Equatable {
        let score: Int
        let level: ConfidenceLevel
        let evidenceSummary: String
        let detectedAt: Date
        let usedVehicleSignal: Bool
    }

    enum VehicleSignalSource: String, Codable, Equatable {
        case carAudio
        case bluetoothAudio

        var summaryLabel: String {
            switch self {
            case .carAudio:
                return "CarPlay or car audio"
            case .bluetoothAudio:
                return "car Bluetooth"
            }
        }
    }

    struct VehicleSignalRecord: Codable, Equatable {
        let source: VehicleSignalSource
        let detectedAt: Date
        let routeName: String?

        var summary: String {
            if let routeName, !routeName.isEmpty {
                return "\(source.summaryLabel) via \(routeName)"
            }
            return source.summaryLabel
        }
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var isEnabled = false
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionAuthorizationStatus: CMAuthorizationStatus = .notDetermined
    @Published private(set) var lastAutoArmRecord: AutoArmRecord?
    @Published private(set) var recentVehicleSignal: VehicleSignalRecord?
    @Published private(set) var lastInferenceAssessment: ConfidenceAssessment?

    private let defaults: UserDefaults
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private let motionQueue = OperationQueue()
    private let parkingReminderStore: ParkingReminderStore
    private var activeReminderCancellable: AnyCancellable?
    private var notificationCancellables = Set<AnyCancellable>()

    private enum Keys {
        static let isEnabled = "smartParking.enabled"
        static let lastAutoArmRecord = "smartParking.lastAutoArmRecord"
        static let recentVehicleSignal = "smartParking.recentVehicleSignal"
        static let lastInferenceAssessment = "smartParking.lastInferenceAssessment"
    }

    nonisolated private static let automotiveLookback: TimeInterval = 45 * 60
    nonisolated private static let recentAutomotiveWindow: TimeInterval = 20 * 60
    nonisolated private static let duplicateArmSuppressionWindow: TimeInterval = 12 * 60 * 60
    nonisolated private static let duplicateArmDistanceMeters: CLLocationDistance = 120
    nonisolated private static let vehicleSignalLookback: TimeInterval = 3 * 60 * 60
    nonisolated private static let staleVehicleSignalWindow: TimeInterval = 24 * 60 * 60

    init(
        parkingReminderStore: ParkingReminderStore,
        defaults: UserDefaults = .standard
    ) {
        self.parkingReminderStore = parkingReminderStore
        self.defaults = defaults
        super.init()

        motionQueue.name = "SpotRelay.smartParking.motion"
        motionQueue.qualityOfService = .utility

        locationManager.delegate = self
        locationAuthorizationStatus = locationManager.authorizationStatus
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        isEnabled = defaults.bool(forKey: Keys.isEnabled)
        lastAutoArmRecord = Self.loadAutoArmRecord(from: defaults)
        recentVehicleSignal = Self.loadVehicleSignalRecord(from: defaults)
        lastInferenceAssessment = Self.loadInferenceAssessment(from: defaults)

        activeReminderCancellable = parkingReminderStore.$activeReminder
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
            }

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVehicleConnectionEvidence()
            }
            .store(in: &notificationCancellables)

        refreshStatus()
        refreshVehicleConnectionEvidence()
        if isEnabled {
            beginMonitoringIfPossible()
        }
    }

    var statusSummary: String {
        switch status {
        case .disabled:
            return "One-time setup. SpotRelay can learn where you parked and arm your return reminder automatically."
        case .monitoring:
            if let areaLabel = lastAutoArmRecord?.areaLabel, !areaLabel.isEmpty {
                if let confidenceLevel = lastAutoArmRecord?.confidenceLevel {
                    return "Smart parking is on. The last automatic reminder was armed near \(areaLabel) with \(confidenceLevel.badgeTitle.lowercased())."
                }
                return "Smart parking is on. The last automatic reminder was armed near \(areaLabel)."
            }
            if let recentVehicleSignal {
                return "Smart parking is on. SpotRelay uses motion plus recent \(recentVehicleSignal.summary) evidence to spot likely parking moments."
            }
            return "Smart parking is on. SpotRelay watches for likely parking moments and arms a return reminder for you."
        case .needsAlwaysLocation:
            return "Keep location on Always to let SpotRelay infer parked spots even when the app isn't open."
        case .needsMotionAccess:
            return "Allow Motion & Fitness so SpotRelay can tell when a car trip has likely ended."
        case .unsupported:
            return "This device doesn't support the motion signals needed for smart parking."
        }
    }

    var actionTitle: String {
        switch status {
        case .disabled:
            return "Turn On"
        case .monitoring:
            return "Turn Off"
        case .needsAlwaysLocation, .needsMotionAccess:
            return "Finish Setup"
        case .unsupported:
            return "Unavailable"
        }
    }

    var confidenceBadgeTitle: String? {
        lastInferenceAssessment?.level.badgeTitle
    }

    var confidenceSummary: String? {
        lastInferenceAssessment?.evidenceSummary
    }

    func enable() async {
        defaults.set(true, forKey: Keys.isEnabled)
        isEnabled = true

        if locationAuthorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if locationAuthorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }

        if CMMotionActivityManager.isActivityAvailable() {
            _ = try? await recentMotionActivities(lookback: 2 * 60)
            motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        }

        beginMonitoringIfPossible()
        refreshVehicleConnectionEvidence()
        refreshStatus()
    }

    func disable() {
        defaults.set(false, forKey: Keys.isEnabled)
        isEnabled = false
        locationManager.stopMonitoringVisits()
        refreshStatus()
    }

    func refreshPermissions() {
        locationAuthorizationStatus = locationManager.authorizationStatus
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        refreshVehicleConnectionEvidence()
        refreshStatus()
    }

    private func beginMonitoringIfPossible() {
        guard isEnabled else { return }
        guard locationAuthorizationStatus == .authorizedWhenInUse || locationAuthorizationStatus == .authorizedAlways else { return }
        locationManager.startMonitoringVisits()
    }

    private func refreshStatus() {
        guard isEnabled else {
            status = .disabled
            return
        }

        if !CMMotionActivityManager.isActivityAvailable() {
            status = .unsupported
            return
        }

        if motionAuthorizationStatus == .denied || motionAuthorizationStatus == .restricted {
            status = .needsMotionAccess
            return
        }

        if locationAuthorizationStatus != .authorizedAlways {
            status = .needsAlwaysLocation
            return
        }

        status = .monitoring
    }

    private func handleVisit(_ visit: CLVisit) async {
        guard isEnabled else { return }
        guard status == .monitoring || status == .needsAlwaysLocation else { return }
        guard visit.horizontalAccuracy >= 0 else { return }
        guard visit.arrivalDate != .distantPast else { return }
        guard parkingReminderStore.activeReminder == nil else { return }

        let activities = (try? await recentMotionActivities(
            from: visit.arrivalDate.addingTimeInterval(-Self.automotiveLookback),
            to: max(Date(), visit.arrivalDate.addingTimeInterval(5 * 60))
        )) ?? []

        guard let assessment = assessParkingConfidence(from: activities, arrivalDate: visit.arrivalDate) else { return }
        persist(assessment)
        lastInferenceAssessment = assessment

        guard shouldAutoArm(for: assessment) else { return }

        let coordinate = visit.coordinate
        guard !isLikelyDuplicateArm(at: coordinate, comparedTo: lastAutoArmRecord) else { return }

        let areaLabel = await reverseGeocodedAreaLabel(for: coordinate)

        do {
            try await parkingReminderStore.rememberParkedSpot(
                at: coordinate,
                areaLabel: areaLabel
            )

            let record = AutoArmRecord(
                armedAt: .now,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                areaLabel: areaLabel,
                confidenceScore: assessment.score,
                evidenceSummary: assessment.evidenceSummary
            )
            persist(record)
            lastAutoArmRecord = record
            refreshStatus()
        } catch {
        }
    }

    private func assessParkingConfidence(from activities: [CMMotionActivity], arrivalDate: Date) -> ConfidenceAssessment? {
        guard !activities.isEmpty else { return nil }

        let sorted = activities.sorted { $0.startDate < $1.startDate }
        let recentAutomotive = sorted.last { activity in
            guard activity.automotive else { return false }
            guard activity.confidence != .low else { return false }
            return arrivalDate.timeIntervalSince(activity.startDate) <= Self.recentAutomotiveWindow
        }

        guard let recentAutomotive else { return nil }

        var score = 42
        var evidence = ["recent drive"]

        if recentAutomotive.confidence == .high {
            score += 8
            evidence.append("high-confidence automotive motion")
        } else if recentAutomotive.confidence == .medium {
            score += 4
        }

        let settledActivities = sorted.filter { activity in
            guard activity.startDate >= recentAutomotive.startDate else { return false }
            guard activity.startDate <= arrivalDate.addingTimeInterval(10 * 60) else { return false }
            return activity.stationary || activity.walking
        }

        let timeSinceDriveStart = arrivalDate.timeIntervalSince(recentAutomotive.startDate)
        if timeSinceDriveStart <= 5 * 60 {
            score += 10
            evidence.append("arrived soon after the drive ended")
        } else if timeSinceDriveStart <= 10 * 60 {
            score += 6
        }

        if settledActivities.contains(where: \.stationary) {
            score += 18
            evidence.append("stationary after arrival")
        } else if settledActivities.contains(where: \.walking) {
            score += 14
            evidence.append("walking after parking")
        }

        let usedVehicleSignal: Bool
        if let recentVehicleSignal, hasRecentVehicleSignal(around: arrivalDate) {
            usedVehicleSignal = true
            switch recentVehicleSignal.source {
            case .carAudio:
                score += 28
            case .bluetoothAudio:
                score += 20
            }
            evidence.append(recentVehicleSignal.summary)
        } else {
            usedVehicleSignal = false
        }

        let clampedScore = min(score, 100)
        return ConfidenceAssessment(
            score: clampedScore,
            level: ConfidenceLevel(score: clampedScore),
            evidenceSummary: evidence.joined(separator: " + "),
            detectedAt: arrivalDate,
            usedVehicleSignal: usedVehicleSignal
        )
    }

    private func shouldAutoArm(for assessment: ConfidenceAssessment) -> Bool {
        assessment.level >= .high
    }

    private func recentMotionActivities(lookback: TimeInterval) async throws -> [CMMotionActivity] {
        try await recentMotionActivities(from: Date().addingTimeInterval(-lookback), to: Date())
    }

    private func recentMotionActivities(from start: Date, to end: Date) async throws -> [CMMotionActivity] {
        try await withCheckedThrowingContinuation { continuation in
            motionActivityManager.queryActivityStarting(from: start, to: end, to: motionQueue) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: activities ?? [])
                }
            }
        }
    }

    private func reverseGeocodedAreaLabel(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
            let items = try await request.mapItems
            let mapItem = items.first
            return mapItem?.addressRepresentations?.cityName
                ?? mapItem?.addressRepresentations?.cityWithContext
                ?? mapItem?.address?.shortAddress
                ?? mapItem?.name?.components(separatedBy: ",").first
        } catch {
            return nil
        }
    }

    private func isLikelyDuplicateArm(at coordinate: CLLocationCoordinate2D, comparedTo record: AutoArmRecord?) -> Bool {
        guard let record else { return false }
        guard Date().timeIntervalSince(record.armedAt) < Self.duplicateArmSuppressionWindow else { return false }

        let previous = CLLocation(latitude: record.latitude, longitude: record.longitude)
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return previous.distance(from: current) < Self.duplicateArmDistanceMeters
    }

    private func hasRecentVehicleSignal(around arrivalDate: Date) -> Bool {
        guard let recentVehicleSignal else { return false }
        return abs(arrivalDate.timeIntervalSince(recentVehicleSignal.detectedAt)) <= Self.vehicleSignalLookback
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            refreshVehicleConnectionEvidence()
            return
        }

        switch reason {
        case .newDeviceAvailable, .routeConfigurationChange, .override, .wakeFromSleep:
            refreshVehicleConnectionEvidence()
        case .oldDeviceUnavailable:
            pruneStaleVehicleConnectionEvidence()
        default:
            break
        }
    }

    private func refreshVehicleConnectionEvidence() {
        pruneStaleVehicleConnectionEvidence()

        guard let record = currentVehicleSignalRecord() else { return }

        recentVehicleSignal = record
        persist(record)
    }

    private func pruneStaleVehicleConnectionEvidence() {
        guard let recentVehicleSignal else { return }
        guard Date().timeIntervalSince(recentVehicleSignal.detectedAt) > Self.staleVehicleSignalWindow else { return }

        defaults.removeObject(forKey: Keys.recentVehicleSignal)
        self.recentVehicleSignal = nil
    }

    private func currentVehicleSignalRecord() -> VehicleSignalRecord? {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs

        if let carPort = outputs.first(where: { $0.portType == .carAudio }) {
            return VehicleSignalRecord(
                source: .carAudio,
                detectedAt: .now,
                routeName: normalizedRouteName(carPort.portName)
            )
        }

        if let bluetoothPort = outputs.first(where: {
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP ||
            $0.portType == .bluetoothLE
        }) {
            return VehicleSignalRecord(
                source: .bluetoothAudio,
                detectedAt: .now,
                routeName: normalizedRouteName(bluetoothPort.portName)
            )
        }

        return nil
    }

    private func persist(_ record: AutoArmRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Keys.lastAutoArmRecord)
    }

    private func persist(_ record: VehicleSignalRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Keys.recentVehicleSignal)
    }

    private func persist(_ assessment: ConfidenceAssessment) {
        guard let data = try? JSONEncoder().encode(assessment) else { return }
        defaults.set(data, forKey: Keys.lastInferenceAssessment)
    }

    private static func loadAutoArmRecord(from defaults: UserDefaults) -> AutoArmRecord? {
        guard let data = defaults.data(forKey: Keys.lastAutoArmRecord) else { return nil }
        return try? JSONDecoder().decode(AutoArmRecord.self, from: data)
    }

    private static func loadVehicleSignalRecord(from defaults: UserDefaults) -> VehicleSignalRecord? {
        guard let data = defaults.data(forKey: Keys.recentVehicleSignal) else { return nil }
        return try? JSONDecoder().decode(VehicleSignalRecord.self, from: data)
    }

    private static func loadInferenceAssessment(from defaults: UserDefaults) -> ConfidenceAssessment? {
        guard let data = defaults.data(forKey: Keys.lastInferenceAssessment) else { return nil }
        return try? JSONDecoder().decode(ConfidenceAssessment.self, from: data)
    }

    private func normalizedRouteName(_ routeName: String?) -> String? {
        guard let routeName else { return nil }
        let trimmed = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension SmartParkingStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationAuthorizationStatus = manager.authorizationStatus
            if self.isEnabled, self.locationAuthorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            self.beginMonitoringIfPossible()
            self.refreshStatus()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor [weak self] in
            await self?.handleVisit(visit)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    }
}
