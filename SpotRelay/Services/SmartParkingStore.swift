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
                return L10n.tr("Off")
            case .monitoring:
                return L10n.tr("On")
            case .needsAlwaysLocation, .needsMotionAccess:
                return L10n.tr("Limited")
            case .unsupported:
                return L10n.tr("Unavailable")
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
                return L10n.tr("Low confidence")
            case .medium:
                return L10n.tr("Medium confidence")
            case .high:
                return L10n.tr("High confidence")
            case .veryHigh:
                return L10n.tr("Very high confidence")
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
        let locationAccuracyMeters: Double?
        let locationSource: ParkingLocationSource?

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
        let parkingTransitionDate: Date
    }

    enum ParkingLocationSource: String, Codable, Equatable {
        case rollingDriveFix
        case livePrecisionFix
        case vehicleDisconnectFix
        case motionSettledFix
        case locationDwellFix
        case visitSettledFix

        var summaryLabel: String {
            switch self {
            case .rollingDriveFix:
                return L10n.tr("drive GPS fix")
            case .livePrecisionFix:
                return L10n.tr("live GPS fix")
            case .vehicleDisconnectFix:
                return L10n.tr("car disconnect fix")
            case .motionSettledFix:
                return L10n.tr("motion settled fix")
            case .locationDwellFix:
                return L10n.tr("location dwell fix")
            case .visitSettledFix:
                return L10n.tr("visit settled fix")
            }
        }
    }

    enum VehicleSignalSource: String, Codable, Equatable {
        case carAudio
        case bluetoothAudio

        var summaryLabel: String {
            switch self {
            case .carAudio:
                return L10n.tr("CarPlay or car audio")
            case .bluetoothAudio:
                return L10n.tr("car Bluetooth")
            }
        }
    }

    struct VehicleSignalRecord: Codable, Equatable {
        let source: VehicleSignalSource
        let detectedAt: Date
        let routeName: String?

        var summary: String {
            if let routeName, !routeName.isEmpty {
                return L10n.format("%@ via %@", source.summaryLabel, routeName)
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
    @Published private(set) var parkingCaptureSnapshot = ParkingCaptureEngine().snapshot

    private let defaults: UserDefaults
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private let motionQueue = OperationQueue()
    private let parkingReminderStore: ParkingReminderStore
    private var parkingCaptureEngine = ParkingCaptureEngine()
    private var activeReminderCancellable: AnyCancellable?
    private var notificationCancellables = Set<AnyCancellable>()
    private var isMonitoringMotionActivity = false

    private enum Keys {
        static let isEnabled = "smartParking.enabled"
        static let lastAutoArmRecord = "smartParking.lastAutoArmRecord"
        static let recentVehicleSignal = "smartParking.recentVehicleSignal"
        static let lastInferenceAssessment = "smartParking.lastInferenceAssessment"
    }

    nonisolated private static let duplicateArmSuppressionWindow: TimeInterval = 12 * 60 * 60
    nonisolated private static let duplicateArmDistanceMeters: CLLocationDistance = 120
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
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = true
        if Self.isBackgroundLocationModeEnabled {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = false
        }
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
            return L10n.tr("One-time setup. SpotRelay can learn where you parked and arm your return reminder automatically.")
        case .monitoring:
            if let areaLabel = lastAutoArmRecord?.areaLabel, !areaLabel.isEmpty {
                if let confidenceLevel = lastAutoArmRecord?.confidenceLevel {
                    return L10n.format("Smart parking is on. The last automatic reminder was armed near %@ with %@.", areaLabel, confidenceLevel.badgeTitle.lowercased())
                }
                return L10n.format("Smart parking is on. The last automatic reminder was armed near %@.", areaLabel)
            }
            if let recentVehicleSignal {
                return L10n.format("Smart parking is on. SpotRelay uses motion plus recent %@ evidence to spot likely parking moments.", recentVehicleSignal.summary)
            }
            return L10n.tr("Smart parking is on. SpotRelay watches for likely parking moments and arms a return reminder for you.")
        case .needsAlwaysLocation:
            return L10n.tr("Keep location on Always to let SpotRelay infer parked spots even when the app isn't open.")
        case .needsMotionAccess:
            return L10n.tr("Allow Motion & Fitness so SpotRelay can tell when a car trip has likely ended.")
        case .unsupported:
            return L10n.tr("This device doesn't support the motion signals needed for smart parking.")
        }
    }

    var actionTitle: String {
        switch status {
        case .disabled:
            return L10n.tr("Turn On")
        case .monitoring:
            return L10n.tr("Turn Off")
        case .needsAlwaysLocation, .needsMotionAccess:
            return L10n.tr("Finish Setup")
        case .unsupported:
            return L10n.tr("Unavailable")
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
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopUpdatingLocation()
        motionActivityManager.stopActivityUpdates()
        isMonitoringMotionActivity = false
        parkingCaptureEngine.reset(reason: "Smart parking off")
        parkingCaptureSnapshot = parkingCaptureEngine.snapshot
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
        startMotionActivityUpdatesIfPossible()
        if locationAuthorizationStatus == .authorizedAlways {
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
        }
    }

    private func startMotionActivityUpdatesIfPossible() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        guard !isMonitoringMotionActivity else { return }
        isMonitoringMotionActivity = true
        motionActivityManager.startActivityUpdates(to: motionQueue) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor [weak self] in
                await self?.handleMotionActivity(activity)
            }
        }
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
        guard visit.horizontalAccuracy >= 0 else { return }
        guard visit.arrivalDate != .distantPast else { return }
        if let event = parkingCaptureEngine.ingest(visit: visit) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
        }
    }

    private func handleMotionActivity(_ activity: CMMotionActivity) async {
        guard isEnabled else { return }
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        if activity.automotive, activity.confidence != .low {
            locationManager.startUpdatingLocation()
        }
        if let event = parkingCaptureEngine.ingest(activity: activity) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
        }
    }

    private func handleLocationUpdates(_ locations: [CLLocation]) async {
        guard isEnabled else { return }
        if let event = parkingCaptureEngine.ingest(locations: locations) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
        }
    }

    private func processParkingCaptureEvent(_ event: ParkingCaptureEvent) async {
        guard parkingReminderStore.activeReminder == nil else { return }
        let coordinate = event.location.coordinate
        guard !isLikelyDuplicateArm(at: coordinate, comparedTo: lastAutoArmRecord) else { return }

        let areaLabel = await reverseGeocodedAreaLabel(for: coordinate)
        let source = parkingLocationSource(for: event.source)
        let enrichedEvidence = L10n.format(
            "%@ + %@",
            localizedEvidenceSummary(event.evidenceSummary),
            source.summaryLabel
        )

        let assessment = ConfidenceAssessment(
            score: event.confidenceScore,
            level: ConfidenceLevel(score: event.confidenceScore),
            evidenceSummary: enrichedEvidence,
            detectedAt: event.parkedAt,
            usedVehicleSignal: event.evidence.contains("vehicle signal") || event.evidence.contains("vehicle disconnected"),
            parkingTransitionDate: event.parkedAt
        )
        persist(assessment)
        lastInferenceAssessment = assessment

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
                confidenceScore: event.confidenceScore,
                evidenceSummary: enrichedEvidence,
                locationAccuracyMeters: event.location.horizontalAccuracy,
                locationSource: source
            )
            persist(record)
            lastAutoArmRecord = record
            refreshStatus()
        } catch {
            #if DEBUG
            print("SpotRelay parking capture save failed:", error.localizedDescription)
            #endif
        }
    }

    private func parkingLocationSource(for source: ParkingCaptureEvent.Source) -> ParkingLocationSource {
        switch source {
        case .vehicleDisconnect:
            return .vehicleDisconnectFix
        case .motionSettled:
            return .motionSettledFix
        case .locationDwell:
            return .locationDwellFix
        case .visitSettled:
            return .visitSettledFix
        }
    }

    private func localizedEvidenceSummary(_ summary: String) -> String {
        summary
            .components(separatedBy: " + ")
            .map(L10n.tr)
            .joined(separator: " + ")
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
            if let record = currentVehicleSignalRecord() {
                parkingCaptureEngine.vehicleConnected(summary: record.summary)
                parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                locationManager.startUpdatingLocation()
            }
        case .oldDeviceUnavailable:
            let previousOutputs = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs ?? []
            if let disconnectedRecord = vehicleSignalRecord(for: previousOutputs) {
                if let event = parkingCaptureEngine.vehicleDisconnected(summary: disconnectedRecord.summary) {
                    parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                    Task {
                        await processParkingCaptureEvent(event)
                    }
                } else {
                    parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                }
            }
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
        parkingCaptureEngine.vehicleConnected(summary: record.summary)
        parkingCaptureSnapshot = parkingCaptureEngine.snapshot
    }

    private func pruneStaleVehicleConnectionEvidence() {
        guard let recentVehicleSignal else { return }
        guard Date().timeIntervalSince(recentVehicleSignal.detectedAt) > Self.staleVehicleSignalWindow else { return }

        defaults.removeObject(forKey: Keys.recentVehicleSignal)
        self.recentVehicleSignal = nil
    }

    private func currentVehicleSignalRecord() -> VehicleSignalRecord? {
        vehicleSignalRecord(for: AVAudioSession.sharedInstance().currentRoute.outputs)
    }

    private func vehicleSignalRecord(for outputs: [AVAudioSessionPortDescription]) -> VehicleSignalRecord? {
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

    nonisolated private static var isBackgroundLocationModeEnabled: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        return modes.contains("location")
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

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            await self?.handleLocationUpdates(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        #if DEBUG
        print("SpotRelay smart parking location error:", error.localizedDescription)
        #endif
    }
}
