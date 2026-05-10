import AVFAudio
import Combine
import CoreBluetooth
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
        let winningSource: WinningSource?

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
        let winningSource: WinningSource?
    }

    enum ParkingLocationSource: String, Codable, Equatable {
        case rollingDriveFix
        case livePrecisionFix
        case vehicleDisconnectFix
        case motionSettledFix
        case locationDwellFix
        case visitSettledFix
        case currentBlueDotFix

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
            case .currentBlueDotFix:
                return L10n.tr("current blue dot fix")
            }
        }
    }

    enum WinningSource: String, Codable, Equatable {
        case carPlay
        case bluetooth
        case dwell
        case disconnect
        case visit

        var badgeTitle: String {
            switch self {
            case .carPlay:
                return L10n.tr("CarPlay won")
            case .bluetooth:
                return L10n.tr("Bluetooth won")
            case .dwell:
                return L10n.tr("Dwell won")
            case .disconnect:
                return L10n.tr("Disconnect won")
            case .visit:
                return L10n.tr("Visit won")
            }
        }

        var summaryLabel: String {
            switch self {
            case .carPlay:
                return L10n.tr("CarPlay was the strongest vehicle-session signal.")
            case .bluetooth:
                return L10n.tr("Bluetooth evidence was the strongest vehicle-session signal.")
            case .dwell:
                return L10n.tr("The final low-speed dwell cluster won.")
            case .disconnect:
                return L10n.tr("The disconnect moment decided the save.")
            case .visit:
                return L10n.tr("The arrival visit settle decided the save.")
            }
        }
    }

    enum VehicleSignalSource: String, Codable, Equatable {
        case carPlay
        case carAudio
        case bluetoothAudio
        case coreBluetoothVehicle

        var summaryLabel: String {
            switch self {
            case .carPlay:
                return L10n.tr("CarPlay session")
            case .carAudio:
                return L10n.tr("CarPlay or car audio")
            case .bluetoothAudio:
                return L10n.tr("car Bluetooth")
            case .coreBluetoothVehicle:
                return L10n.tr("known car Bluetooth peripheral")
            }
        }

        var captureToken: String {
            switch self {
            case .carPlay:
                return "vehicle-signal:carplay"
            case .carAudio:
                return "vehicle-signal:car-audio"
            case .bluetoothAudio:
                return "vehicle-signal:bluetooth-audio"
            case .coreBluetoothVehicle:
                return "vehicle-signal:corebluetooth"
            }
        }

        var priority: Int {
            switch self {
            case .carPlay:
                return 4
            case .coreBluetoothVehicle:
                return 3
            case .carAudio:
                return 2
            case .bluetoothAudio:
                return 1
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
    @Published private(set) var isCarPlaySignalActive = false

    private let defaults: UserDefaults
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private let motionQueue = OperationQueue()
    private let parkingReminderStore: ParkingReminderStore
    private var bluetoothManager: CBCentralManager?
    private var parkingCaptureEngine = ParkingCaptureEngine()
    private var activeReminderCancellable: AnyCancellable?
    private var notificationCancellables = Set<AnyCancellable>()
    private var isMonitoringMotionActivity = false
    private var recentAutomotiveActivityAt: Date?
    private var activeVehicleSignals = Set<VehicleSignalSource>()
    private var recentBluetoothVehicleSignal: VehicleSignalRecord?
    private var knownVehiclePeripheralNames = Set<String>()
    private var bluetoothScanStopTask: Task<Void, Never>?
    private var isPhoneChargingDriveSignalActive = false
    private let parkingSequenceLogger = ParkingSequenceLogger.shared

    private enum Keys {
        static let isEnabled = "smartParking.enabled"
        static let lastAutoArmRecord = "smartParking.lastAutoArmRecord"
        static let recentVehicleSignal = "smartParking.recentVehicleSignal"
        static let lastInferenceAssessment = "smartParking.lastInferenceAssessment"
        static let knownVehiclePeripheralNames = "smartParking.knownVehiclePeripheralNames"
    }

    nonisolated private static let duplicateArmSuppressionWindow: TimeInterval = 12 * 60 * 60
    nonisolated private static let duplicateArmDistanceMeters: CLLocationDistance = 18
    nonisolated private static let staleVehicleSignalWindow: TimeInterval = 24 * 60 * 60
    nonisolated private static let currentLocationCorrectionMaximumAge: TimeInterval = 90
    nonisolated private static let currentLocationCorrectionMaximumEventOffset: TimeInterval = 5 * 60
    nonisolated private static let currentLocationCorrectionMaximumAccuracyMeters: CLLocationAccuracy = 30
    nonisolated private static let currentLocationCorrectionDistanceMeters: CLLocationDistance = 45
    nonisolated private static let resumedDrivingSpeedMetersPerSecond: CLLocationSpeed = 6
    nonisolated private static let resumedDrivingMinimumDistanceFromSavedSpot: CLLocationDistance = 110
    nonisolated private static let resumedDrivingRetireDistanceFromSavedSpot: CLLocationDistance = 250
    nonisolated private static let phoneChargingDriveDistanceMeters: CLLocationDistance = 250
    nonisolated private static let bluetoothVehicleSignalFreshnessWindow: TimeInterval = 120
    nonisolated private static let automotiveSignalFreshnessWindow: TimeInterval = 6 * 60
    nonisolated private static let bluetoothScanDuration: TimeInterval = 10
    nonisolated private static let carPlaySceneRoleRawValue = "CPTemplateApplicationSceneSessionRoleApplication"
    nonisolated private static let likelyVehiclePeripheralKeywords = [
        "car", "auto", "bmw", "audi", "tesla", "ford", "toyota", "honda",
        "hyundai", "kia", "chevrolet", "chevy", "mercedes", "benz", "lexus",
        "nissan", "mazda", "volkswagen", "vw", "subaru", "gmc", "ram", "jeep"
    ]

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
        knownVehiclePeripheralNames = Set(defaults.stringArray(forKey: Keys.knownVehiclePeripheralNames) ?? [])
        bluetoothManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
        UIDevice.current.isBatteryMonitoringEnabled = true
        parkingSequenceLogger.append("SmartParkingStore init: enabled=\(isEnabled), status=\(locationAuthorizationStatus.rawValue)")

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

        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVehicleConnectionEvidence()
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVehicleConnectionEvidence()
            }
            .store(in: &notificationCancellables)

        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleBatteryStateChange()
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

    var winningSourceBadgeTitle: String? {
        lastAutoArmRecord?.winningSource?.badgeTitle
    }

    var winningSourceSummary: String? {
        lastAutoArmRecord?.winningSource?.summaryLabel
    }

    var parkingLogFilePath: String {
        parkingSequenceLogger.fileURL.path
    }

    var parkingLogFileURL: URL {
        parkingSequenceLogger.fileURL
    }

    func clearParkingLog() {
        parkingSequenceLogger.clear()
        parkingSequenceLogger.append("Parking debug log cleared from app")
    }

    func enable() async {
        defaults.set(true, forKey: Keys.isEnabled)
        isEnabled = true
        parkingSequenceLogger.append("Enable requested")

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
        parkingSequenceLogger.append("Disable requested")
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
        parkingSequenceLogger.append("Visit received: lat=\(visit.coordinate.latitude), lon=\(visit.coordinate.longitude), accuracy=\(Int(visit.horizontalAccuracy.rounded()))m")
        if let event = parkingCaptureEngine.ingest(visit: visit) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Visit produced capture event: source=\(event.source.rawValue), confidence=\(event.confidenceScore), evidence=\(event.evidenceSummary)")
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Visit ingested without save: \(parkingCaptureSnapshot.lastReason)")
        }
    }

    private func handleMotionActivity(_ activity: CMMotionActivity) async {
        guard isEnabled else { return }
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        if activity.automotive, activity.confidence != .low {
            recentAutomotiveActivityAt = activity.startDate
            locationManager.startUpdatingLocation()
            startBluetoothVehicleScanIfHelpful()
            parkingSequenceLogger.append("Motion activity automotive: confidence=\(activity.confidence.rawValue), startedAt=\(activity.startDate.timeIntervalSince1970)")
            observeSavedParkedSpotWhileUserMoves(
                hasAutomotiveSignal: true,
                latestLocation: locationManager.location
            )
            observePhoneChargingDriveSignalIfQualified()
        }
        if let event = parkingCaptureEngine.ingest(activity: activity) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Motion produced capture event: source=\(event.source.rawValue), confidence=\(event.confidenceScore), evidence=\(event.evidenceSummary)")
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Motion ingested without save: \(parkingCaptureSnapshot.lastReason)")
        }
    }

    private func handleLocationUpdates(_ locations: [CLLocation]) async {
        guard isEnabled else { return }
        if let latestLocation = locations.last {
            parkingSequenceLogger.append("Location update: count=\(locations.count), lat=\(latestLocation.coordinate.latitude), lon=\(latestLocation.coordinate.longitude), accuracy=\(Int(latestLocation.horizontalAccuracy.rounded()))m, speed=\(String(format: "%.2f", max(latestLocation.speed, 0)))")
            observeSavedParkedSpotWhileUserMoves(
                hasAutomotiveSignal: false,
                latestLocation: latestLocation
            )
            await notifyParkedReminderIfVehicleConnectedNearCar(using: latestLocation)
        }
        if let event = parkingCaptureEngine.ingest(locations: locations) {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Location dwell produced capture event: source=\(event.source.rawValue), confidence=\(event.confidenceScore), evidence=\(event.evidenceSummary)")
            await processParkingCaptureEvent(event)
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            parkingSequenceLogger.append("Location ingested without save: \(parkingCaptureSnapshot.lastReason)")
        }
        if locations.last != nil {
            observePhoneChargingDriveSignalIfQualified()
        }
    }

    private func observePhoneChargingDriveSignalIfQualified() {
        guard Self.isPhoneConnectedToPower(UIDevice.current.batteryState) else { return }
        guard !isPhoneChargingDriveSignalActive else { return }
        guard hasQualifiedDriveForPhoneCharging else { return }

        isPhoneChargingDriveSignalActive = true
        parkingSequenceLogger.append(phoneChargingLocationLogLine(isConnected: true))
        parkingCaptureEngine.vehicleConnected(summary: "vehicle-signal:phone-charging")
        parkingCaptureSnapshot = parkingCaptureEngine.snapshot
    }

    private var hasQualifiedDriveForPhoneCharging: Bool {
        if !activeVehicleSignals.isEmpty {
            return true
        }

        if let recentAutomotiveActivityAt,
           Date().timeIntervalSince(recentAutomotiveActivityAt) <= Self.automotiveSignalFreshnessWindow {
            return true
        }

        return parkingCaptureSnapshot.driveDistanceMeters >= Self.phoneChargingDriveDistanceMeters
    }

    private func handleBatteryStateChange() {
        guard isEnabled else { return }
        let batteryState = UIDevice.current.batteryState

        if Self.isPhoneConnectedToPower(batteryState) {
            locationManager.startUpdatingLocation()
            return
        }

        guard batteryState == .unplugged else { return }
        guard isPhoneChargingDriveSignalActive else {
            parkingSequenceLogger.append("Phone charging disconnect ignored: no qualified drive charging signal")
            return
        }

        isPhoneChargingDriveSignalActive = false
        parkingSequenceLogger.append(phoneChargingLocationLogLine(isConnected: false))
        locationManager.startUpdatingLocation()
        if let event = parkingCaptureEngine.vehicleDisconnected(summary: "vehicle-signal:phone-charging") {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            Task {
                await processParkingCaptureEvent(event)
            }
        } else {
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
        }
    }

    private func observeSavedParkedSpotWhileUserMoves(
        hasAutomotiveSignal: Bool,
        latestLocation: CLLocation?
    ) {
        guard parkingReminderStore.hasRememberedParkedLocations,
              let reminder = parkingReminderStore.savedParkedLocation else {
            return
        }

        let parkedLocation = CLLocation(
            latitude: reminder.coordinate.latitude,
            longitude: reminder.coordinate.longitude
        )

        if hasAutomotiveSignal, let latestLocation {
            let distanceFromSavedSpot = latestLocation.distance(from: parkedLocation)
            if latestLocation.speed >= Self.resumedDrivingSpeedMetersPerSecond,
               distanceFromSavedSpot >= Self.resumedDrivingRetireDistanceFromSavedSpot {
                if parkingReminderStore.retireCurrentParkedSpotForDriving() {
                    parkingSequenceLogger.append("Retiring saved parked spot after pickup: speed=\(String(format: "%.2f", latestLocation.speed))m/s, distance=\(Int(distanceFromSavedSpot.rounded()))m")
                }
                return
            }

            if distanceFromSavedSpot >= Self.resumedDrivingMinimumDistanceFromSavedSpot {
                if parkingReminderStore.noteMovedAwayFromParkedSpot() {
                    parkingSequenceLogger.append("Parked reminder kept armed after leaving: automotive signal resumed, distance=\(Int(distanceFromSavedSpot.rounded()))m")
                }
                return
            }
        }

        guard let latestLocation else { return }
        guard latestLocation.speed >= Self.resumedDrivingSpeedMetersPerSecond else { return }

        let distanceThreshold = max(
            Self.resumedDrivingMinimumDistanceFromSavedSpot,
            reminder.radiusMeters + 35
        )
        let distanceFromSavedSpot = latestLocation.distance(from: parkedLocation)
        guard distanceFromSavedSpot >= distanceThreshold else { return }

        if distanceFromSavedSpot >= Self.resumedDrivingRetireDistanceFromSavedSpot {
            if parkingReminderStore.retireCurrentParkedSpotForDriving() {
                parkingSequenceLogger.append("Retiring saved parked spot after pickup: speed=\(String(format: "%.2f", latestLocation.speed))m/s, distance=\(Int(distanceFromSavedSpot.rounded()))m")
            }
            return
        }

        if parkingReminderStore.noteMovedAwayFromParkedSpot() {
            parkingSequenceLogger.append("Parked reminder kept armed after leaving: speed resumed at \(String(format: "%.2f", latestLocation.speed))m/s, distance=\(Int(distanceFromSavedSpot.rounded()))m")
        }
    }

    private static func isPhoneConnectedToPower(_ batteryState: UIDevice.BatteryState) -> Bool {
        batteryState == .charging || batteryState == .full
    }

    private func phoneChargingLocationLogLine(isConnected: Bool) -> String {
        let transition = isConnected ? "connect" : "disconnect"
        guard let location = locationManager.location else {
            return "Phone charging \(transition) at lat - unavailable and long - unavailable"
        }

        return "Phone charging \(transition) at lat - \(location.coordinate.latitude) and long - \(location.coordinate.longitude), accuracy=\(Int(location.horizontalAccuracy.rounded()))m"
    }

    private func processParkingCaptureEvent(_ event: ParkingCaptureEvent) async {
        let locationDecision = trustedParkedLocation(for: event)
        let winningSource = winningSource(for: event)
        let coordinate = locationDecision.location.coordinate
        if let activeReminder = parkingReminderStore.activeReminder {
            let distanceFromActiveReminder = activeReminder.distanceMeters(from: coordinate)
            let replacementDistance = Self.duplicateArmDistanceMeters
            guard distanceFromActiveReminder >= replacementDistance else {
                parkingSequenceLogger.append("Skipped save: active parked reminder already armed within \(Int(distanceFromActiveReminder.rounded()))m")
                return
            }

            parkingSequenceLogger.append("Replacing active parked reminder: new parked capture is \(Int(distanceFromActiveReminder.rounded()))m from previous spot")
        }
        guard !isLikelyDuplicateArm(at: coordinate, comparedTo: lastAutoArmRecord) else {
            parkingSequenceLogger.append("Skipped save: duplicate parked capture within \(Int(Self.duplicateArmDistanceMeters.rounded()))m suppression window")
            return
        }

        let areaLabel = await reverseGeocodedAreaLabel(for: coordinate)
        let source = locationDecision.source
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
            parkingTransitionDate: event.parkedAt,
            winningSource: winningSource
        )
        persist(assessment)
        lastInferenceAssessment = assessment
        parkingSequenceLogger.append(
            "Capture event accepted: source=\(event.source.rawValue), winner=\(winningSource.rawValue), saveLat=\(coordinate.latitude), saveLon=\(coordinate.longitude), accuracy=\(Int(locationDecision.location.horizontalAccuracy.rounded()))m, confidence=\(event.confidenceScore), evidence=\(event.evidenceSummary), locationSource=\(locationDecision.source.rawValue)"
        )

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
                locationAccuracyMeters: locationDecision.location.horizontalAccuracy,
                locationSource: source,
                winningSource: winningSource
            )
            persist(record)
            lastAutoArmRecord = record
            refreshStatus()
            parkingSequenceLogger.append("Parked spot saved successfully near \(areaLabel ?? "unknown area")")
        } catch {
            parkingSequenceLogger.append("Parked spot save failed: \(error.localizedDescription)")
            #if DEBUG
            print("SpotRelay parking capture save failed:", error.localizedDescription)
            #endif
        }
    }

    private func trustedParkedLocation(
        for event: ParkingCaptureEvent
    ) -> (location: CLLocation, source: ParkingLocationSource) {
        let eventSource = parkingLocationSource(for: event.source)

        guard !event.evidence.contains("walking after parking") else {
            return (event.location, eventSource)
        }

        guard let latestLocation = locationManager.location else {
            return (event.location, eventSource)
        }

        guard latestLocation.horizontalAccuracy >= 0,
              latestLocation.horizontalAccuracy <= Self.currentLocationCorrectionMaximumAccuracyMeters else {
            return (event.location, eventSource)
        }

        guard abs(latestLocation.timestamp.timeIntervalSinceNow) <= Self.currentLocationCorrectionMaximumAge else {
            return (event.location, eventSource)
        }

        guard abs(latestLocation.timestamp.timeIntervalSince(event.parkedAt)) <= Self.currentLocationCorrectionMaximumEventOffset else {
            return (event.location, eventSource)
        }

        if latestLocation.speed >= 0, latestLocation.speed > 2.5 {
            return (event.location, eventSource)
        }

        let distance = latestLocation.distance(from: event.location)
        let correctionThreshold = max(
            Self.currentLocationCorrectionDistanceMeters,
            latestLocation.horizontalAccuracy + event.location.horizontalAccuracy + 20
        )

        guard distance >= correctionThreshold else {
            return (event.location, eventSource)
        }

        #if DEBUG
        print("SpotRelay parking capture corrected to blue dot by \(Int(distance.rounded()))m")
        #endif
        parkingSequenceLogger.append("Corrected parked coordinate to current blue dot by \(Int(distance.rounded()))m")
        return (latestLocation, .currentBlueDotFix)
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

    private func winningSource(for event: ParkingCaptureEvent) -> WinningSource {
        if event.evidence.contains("vehicle-signal:carplay") {
            return .carPlay
        }

        if event.evidence.contains("vehicle-signal:corebluetooth")
            || event.evidence.contains("vehicle-signal:bluetooth-audio") {
            return .bluetooth
        }

        switch event.source {
        case .vehicleDisconnect:
            return .disconnect
        case .visitSettled:
            return .visit
        case .motionSettled, .locationDwell:
            return .dwell
        }
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

        let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
        parkingSequenceLogger.append("Audio route changed: reason=\(reason), current=\(audioRouteSummary(for: currentOutputs))")

        switch reason {
        case .newDeviceAvailable, .routeConfigurationChange, .override, .wakeFromSleep:
            refreshVehicleConnectionEvidence()
            if let record = currentVehicleSignalRecord() {
                parkingSequenceLogger.append("Audio route connected: \(record.source.rawValue) \(record.routeName ?? "")")
                parkingCaptureEngine.vehicleConnected(summary: record.source.captureToken)
                parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                locationManager.startUpdatingLocation()
                startBluetoothVehicleScanIfHelpful()
            }
        case .oldDeviceUnavailable:
            let previousOutputs = (userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs ?? []
            parkingSequenceLogger.append("Audio previous route: \(audioRouteSummary(for: previousOutputs))")
            if let disconnectedRecord = vehicleSignalRecord(for: previousOutputs) {
                parkingSequenceLogger.append("Audio route disconnected: \(disconnectedRecord.source.rawValue) \(disconnectedRecord.routeName ?? "")")
                if !activeVehicleSignals.contains(disconnectedRecord.source) {
                    if let event = parkingCaptureEngine.vehicleDisconnected(summary: disconnectedRecord.source.captureToken) {
                        parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                        Task {
                            await processParkingCaptureEvent(event)
                        }
                    } else {
                        parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                    }
                }
            }
            refreshVehicleConnectionEvidence()
        default:
            refreshVehicleConnectionEvidence()
        }
    }

    private func refreshVehicleConnectionEvidence() {
        pruneStaleVehicleConnectionEvidence()
        let nextSignals = currentActiveVehicleSignals()
        isCarPlaySignalActive = nextSignals.contains(.carPlay)
        applyVehicleSignalTransitions(nextSignals)
        parkingSequenceLogger.append("Vehicle evidence refresh: active=\(nextSignals.map(\.rawValue).sorted().joined(separator: ","))")

        if let strongestRecord = strongestVehicleSignalRecord(from: nextSignals) {
            recentVehicleSignal = strongestRecord
            persist(strongestRecord)
        } else {
            recentVehicleSignal = nil
            defaults.removeObject(forKey: Keys.recentVehicleSignal)
        }
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

    private func currentActiveVehicleSignals() -> Set<VehicleSignalSource> {
        var signals = Set<VehicleSignalSource>()

        if isCarPlaySceneActive() {
            signals.insert(.carPlay)
        }

        if let routeRecord = currentVehicleSignalRecord() {
            signals.insert(routeRecord.source)
        }

        if let bluetoothSignal = recentBluetoothVehicleSignal,
           Date().timeIntervalSince(bluetoothSignal.detectedAt) <= Self.bluetoothVehicleSignalFreshnessWindow {
            signals.insert(bluetoothSignal.source)
        }

        return signals
    }

    private func strongestVehicleSignalRecord(from signals: Set<VehicleSignalSource>) -> VehicleSignalRecord? {
        guard let strongest = signals.max(by: { $0.priority < $1.priority }) else { return nil }

        switch strongest {
        case .carPlay:
            return VehicleSignalRecord(source: .carPlay, detectedAt: .now, routeName: nil)
        case .carAudio, .bluetoothAudio:
            return currentVehicleSignalRecord()
        case .coreBluetoothVehicle:
            return recentBluetoothVehicleSignal
        }
    }

    private func applyVehicleSignalTransitions(_ nextSignals: Set<VehicleSignalSource>) {
        let removed = activeVehicleSignals.subtracting(nextSignals)
        let added = nextSignals.subtracting(activeVehicleSignals)

        for source in removed.sorted(by: { $0.priority > $1.priority }) {
            parkingSequenceLogger.append(vehicleSignalLocationLogLine(source: source, isConnected: false))
            parkingSequenceLogger.append("Vehicle signal removed: \(source.rawValue)")
            if let event = parkingCaptureEngine.vehicleDisconnected(summary: source.captureToken) {
                parkingCaptureSnapshot = parkingCaptureEngine.snapshot
                Task {
                    await processParkingCaptureEvent(event)
                }
            } else {
                parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            }
        }

        for source in added.sorted(by: { $0.priority > $1.priority }) {
            parkingSequenceLogger.append(vehicleSignalLocationLogLine(source: source, isConnected: true))
            parkingSequenceLogger.append("Vehicle signal added: \(source.rawValue)")
            parkingCaptureEngine.vehicleConnected(summary: source.captureToken)
            parkingCaptureSnapshot = parkingCaptureEngine.snapshot
            locationManager.startUpdatingLocation()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.parkingReminderStore.handleVehicleConnectionNearParkedCar(
                    sourceSummary: source.summaryLabel,
                    location: self.locationManager.location
                )
                self.parkingSequenceLogger.append("Vehicle connection reminder check: source=\(source.rawValue), outcome=\(self.vehicleConnectionReminderOutcomeSummary(outcome))")
            }
        }

        activeVehicleSignals = nextSignals
    }

    private func vehicleSignalLocationLogLine(source: VehicleSignalSource, isConnected: Bool) -> String {
        let vehicleName: String
        switch source {
        case .carPlay, .carAudio:
            vehicleName = "Carplay"
        case .bluetoothAudio, .coreBluetoothVehicle:
            vehicleName = "Bluetooth"
        }

        let transition = isConnected ? "connect" : "disconnect"
        guard let location = locationManager.location else {
            return "\(vehicleName) \(transition) at lat - unavailable and long - unavailable"
        }

        return "\(vehicleName) \(transition) at lat - \(location.coordinate.latitude) and long - \(location.coordinate.longitude), accuracy=\(Int(location.horizontalAccuracy.rounded()))m"
    }

    private func notifyParkedReminderIfVehicleConnectedNearCar(using latestLocation: CLLocation) async {
        guard let strongestVehicleSignal = activeVehicleSignals.max(by: { $0.priority < $1.priority }) else {
            return
        }

        let outcome = await parkingReminderStore.handleVehicleConnectionNearParkedCar(
            sourceSummary: strongestVehicleSignal.summaryLabel,
            location: latestLocation
        )
        if shouldLogVehicleConnectionReminderOutcomeFromLocation(outcome) {
            parkingSequenceLogger.append("Vehicle connection reminder check: source=\(strongestVehicleSignal.rawValue), outcome=\(vehicleConnectionReminderOutcomeSummary(outcome))")
        }
    }

    private func shouldLogVehicleConnectionReminderOutcomeFromLocation(_ outcome: ParkingReminderStore.VehicleConnectionReminderOutcome) -> Bool {
        switch outcome {
        case .alreadyNudged, .failed, .notificationsDisabled, .scheduled, .waitingForUsableLocation:
            return true
        case .noActiveReminder, .outsideReturnDistance, .waitingForExitOrAge:
            return false
        }
    }

    private func vehicleConnectionReminderOutcomeSummary(_ outcome: ParkingReminderStore.VehicleConnectionReminderOutcome) -> String {
        switch outcome {
        case .noActiveReminder:
            return "no active parked reminder"
        case .waitingForExitOrAge:
            return "waiting for exit or reminder age"
        case .waitingForUsableLocation:
            return "waiting for usable location"
        case let .outsideReturnDistance(distanceMeters, allowedMeters):
            return "outside return distance: \(Int(distanceMeters.rounded()))m > \(Int(allowedMeters.rounded()))m"
        case .alreadyNudged:
            return "already nudged for this parked session"
        case .notificationsDisabled:
            return "notifications disabled"
        case .scheduled:
            return "notification scheduled"
        case .failed:
            return "notification failed"
        }
    }

    private func audioRouteSummary(for outputs: [AVAudioSessionPortDescription]) -> String {
        guard !outputs.isEmpty else { return "none" }

        return outputs
            .map { output in
                let routeName = normalizedRouteName(output.portName) ?? "unnamed"
                return "\(output.portType.rawValue):\(routeName)"
            }
            .joined(separator: ",")
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

    private func isCarPlaySceneActive() -> Bool {
        UIApplication.shared.connectedScenes.contains(where: { scene in
            if scene.session.role.rawValue == Self.carPlaySceneRoleRawValue {
                return true
            }

            if let windowScene = scene as? UIWindowScene {
                return windowScene.traitCollection.userInterfaceIdiom == .carPlay
            }

            return false
        })
    }

    private func startBluetoothVehicleScanIfHelpful() {
        guard isEnabled else { return }
        guard let bluetoothManager, bluetoothManager.state == .poweredOn else { return }
        guard shouldAttemptBluetoothVehicleScan else { return }

        bluetoothScanStopTask?.cancel()
        bluetoothManager.stopScan()
        bluetoothManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        bluetoothScanStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.bluetoothScanDuration))
            self?.bluetoothManager?.stopScan()
        }
    }

    private var shouldAttemptBluetoothVehicleScan: Bool {
        if !activeVehicleSignals.isEmpty {
            return true
        }
        guard let recentAutomotiveActivityAt else { return false }
        return Date().timeIntervalSince(recentAutomotiveActivityAt) <= Self.automotiveSignalFreshnessWindow
    }

    private func handleDiscoveredBluetoothPeripheral(_ peripheral: CBPeripheral) {
        guard let name = normalizedRouteName(peripheral.name) else { return }
        guard isLikelyVehiclePeripheralName(name) else { return }

        knownVehiclePeripheralNames.insert(name)
        defaults.set(Array(knownVehiclePeripheralNames).sorted(), forKey: Keys.knownVehiclePeripheralNames)

        recentBluetoothVehicleSignal = VehicleSignalRecord(
            source: .coreBluetoothVehicle,
            detectedAt: .now,
            routeName: name
        )
        parkingSequenceLogger.append("Bluetooth vehicle candidate discovered: \(name)")
        refreshVehicleConnectionEvidence()
    }

    private func isLikelyVehiclePeripheralName(_ name: String) -> Bool {
        let normalized = name.lowercased()

        if knownVehiclePeripheralNames.contains(name) {
            return true
        }

        if let routeRecord = currentVehicleSignalRecord(),
           let routeName = routeRecord.routeName?.lowercased(),
           !routeName.isEmpty,
           normalized.contains(routeName) || routeName.contains(normalized) {
            return true
        }

        return Self.likelyVehiclePeripheralKeywords.contains(where: { normalized.contains($0) })
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

extension SmartParkingStore: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if central.state != .poweredOn {
                self.bluetoothScanStopTask?.cancel()
                self.bluetoothManager?.stopScan()
                self.recentBluetoothVehicleSignal = nil
            } else {
                self.startBluetoothVehicleScanIfHelpful()
            }
            self.refreshVehicleConnectionEvidence()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor [weak self] in
            self?.handleDiscoveredBluetoothPeripheral(peripheral)
        }
    }
}

final class ParkingSequenceLogger {
    static let shared = ParkingSequenceLogger()

    let fileURL: URL
    private let formatter: ISO8601DateFormatter

    init(fileName: String = "SpotRelayParkingDebug.log") {
        self.fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ensureLogFileExists()
    }

    func append(_ message: String) {
        let line = "[\(formatter.string(from: .now))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func clear() {
        try? Data().write(to: fileURL, options: .atomic)
    }

    private func ensureLogFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? Data().write(to: fileURL, options: .atomic)
    }
}
