import Combine
import CoreLocation
import Foundation
import UserNotifications

@MainActor
final class ParkingReminderStore: NSObject, ObservableObject {
    struct Reminder: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let createdAt: Date
        let areaLabel: String?
        let radiusMeters: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var areaSummary: String {
            guard let areaLabel, !areaLabel.isEmpty, areaLabel != "Nearby" else {
                return "We'll nudge you when you're back near this parked spot."
            }
            return "We'll nudge you when you're back near \(areaLabel)."
        }

        func coordinateDistanceText(from coordinate: CLLocationCoordinate2D) -> String {
            let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let destination = CLLocation(latitude: self.coordinate.latitude, longitude: self.coordinate.longitude)
            let meters = Int(origin.distance(from: destination).rounded())
            return "\(meters)m"
        }
    }

    enum Error: LocalizedError {
        case locationAuthorizationRequired
        case regionMonitoringUnavailable

        var errorDescription: String? {
            switch self {
            case .locationAuthorizationRequired:
                return "Always location access is required for parked-car return reminders."
            case .regionMonitoringUnavailable:
                return "This device can't monitor parked-car reminder regions."
            }
        }
    }

    enum DebugState: String, Codable, Equatable {
        case noReminder
        case armed
        case exitedWaitingForReturn
        case notificationScheduled
        case pausedNeedsAlwaysLocation
        case monitoringUnavailable

        var title: String {
            switch self {
            case .noReminder:
                return "No parked reminder armed"
            case .armed:
                return "Parked reminder armed"
            case .exitedWaitingForReturn:
                return "Left parked zone"
            case .notificationScheduled:
                return "Return notification scheduled"
            case .pausedNeedsAlwaysLocation:
                return "Reminder paused"
            case .monitoringUnavailable:
                return "Region monitoring unavailable"
            }
        }

        var detail: String {
            switch self {
            case .noReminder:
                return "SpotRelay hasn't armed a parked-car return reminder yet."
            case .armed:
                return "Monitoring your parked spot now."
            case .exitedWaitingForReturn:
                return "Waiting for you to come back to the parked spot."
            case .notificationScheduled:
                return "SpotRelay detected your return and queued the local notification."
            case .pausedNeedsAlwaysLocation:
                return "Always location is required for the parked-car reminder to keep working."
            case .monitoringUnavailable:
                return "This device can't monitor the parked-car region."
            }
        }

        var shouldDisplay: Bool {
            self != .noReminder
        }
    }

    nonisolated static let defaultRadiusMeters: Double = 150
    nonisolated static let parkedLocationRetentionInterval: TimeInterval = 48 * 60 * 60

    @Published private(set) var activeReminder: Reminder?
    @Published private(set) var savedParkedLocation: Reminder?
    @Published private(set) var debugState: DebugState

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let locationManager: CLLocationManager

    private enum Keys {
        static let activeReminder = "parkingReminder.active"
        static let savedParkedLocation = "parkingReminder.savedLocation"
        static let hasExitedRegion = "parkingReminder.hasExitedRegion"
        static let debugState = "parkingReminder.debugState"
        static let regionIdentifier = "parkingReminder.returnToCar.region"
        static let notificationIdentifier = "parkingReminder.returnToCar.notification"
    }

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.center = center
        self.defaults = defaults
        self.locationManager = locationManager
        self.activeReminder = Self.loadReminder(from: defaults, key: Keys.activeReminder)
        self.savedParkedLocation = Self.loadReminder(from: defaults, key: Keys.savedParkedLocation)
        self.debugState = Self.loadDebugState(from: defaults)
            ?? Self.derivedDebugState(
                activeReminder: Self.loadReminder(from: defaults, key: Keys.activeReminder),
                hasExitedRegion: defaults.bool(forKey: Keys.hasExitedRegion)
            )
        super.init()

        self.locationManager.delegate = self

        removeExpiredSavedLocationIfNeeded()

        Task {
            await restoreMonitoringIfNeeded()
        }
    }

    var hasActiveReminder: Bool {
        activeReminder != nil
    }

    var hasSavedParkedLocation: Bool {
        savedParkedLocation != nil
    }

    func rememberParkedSpot(
        at coordinate: CLLocationCoordinate2D,
        areaLabel: String?,
        radiusMeters: Double = defaultRadiusMeters
    ) async throws {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            throw Error.regionMonitoringUnavailable
        }
        guard locationManager.authorizationStatus == .authorizedAlways else {
            throw Error.locationAuthorizationRequired
        }

        let reminder = Reminder(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: .now,
            areaLabel: normalizedAreaLabel(areaLabel),
            radiusMeters: radiusMeters
        )

        stopMonitoringReminderRegion()
        persist(reminder, key: Keys.activeReminder)
        persist(reminder, key: Keys.savedParkedLocation)
        setHasExitedRegion(false)
        activeReminder = reminder
        savedParkedLocation = reminder
        updateDebugState(.armed)
        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])

        let region = monitoredRegion(for: reminder)
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
    }

    func clearReminder() async {
        clearActiveReminderOnly()
        defaults.removeObject(forKey: Keys.savedParkedLocation)
        savedParkedLocation = nil
        updateDebugState(.noReminder)
    }

    func refreshReminderState() async {
        activeReminder = Self.loadReminder(from: defaults, key: Keys.activeReminder)
        savedParkedLocation = Self.loadReminder(from: defaults, key: Keys.savedParkedLocation)
        removeExpiredSavedLocationIfNeeded()
        await restoreMonitoringIfNeeded()
    }

    private func restoreMonitoringIfNeeded() async {
        guard let reminder = activeReminder else {
            stopMonitoringReminderRegion()
            if debugState != .notificationScheduled {
                updateDebugState(.noReminder)
            }
            return
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            updateDebugState(.monitoringUnavailable)
            return
        }
        guard locationManager.authorizationStatus == .authorizedAlways else {
            updateDebugState(.pausedNeedsAlwaysLocation)
            return
        }

        let alreadyMonitoring = locationManager.monitoredRegions.contains { region in
            region.identifier == Keys.regionIdentifier
        }

        if !alreadyMonitoring {
            let region = monitoredRegion(for: reminder)
            locationManager.startMonitoring(for: region)
        }

        if let monitoredRegion = locationManager.monitoredRegions.first(where: { $0.identifier == Keys.regionIdentifier }) {
            locationManager.requestState(for: monitoredRegion)
        }

        if hasExitedRegion {
            updateDebugState(.exitedWaitingForReturn)
        } else {
            updateDebugState(.armed)
        }
    }

    private func monitoredRegion(for reminder: Reminder) -> CLCircularRegion {
        let region = CLCircularRegion(
            center: reminder.coordinate,
            radius: reminder.radiusMeters,
            identifier: Keys.regionIdentifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }

    private func stopMonitoringReminderRegion() {
        let monitoredReminderRegions = locationManager.monitoredRegions.filter { $0.identifier == Keys.regionIdentifier }
        monitoredReminderRegions.forEach(locationManager.stopMonitoring)
    }

    private func handleRegionExit() {
        guard activeReminder != nil else { return }
        setHasExitedRegion(true)
        updateDebugState(.exitedWaitingForReturn)
    }

    private func handleRegionEntry() async {
        guard let reminder = activeReminder else { return }
        guard hasExitedRegion else { return }

        let content = UNMutableNotificationContent()
        content.title = "Back at your car?"
        if let areaLabel = reminder.areaLabel, !areaLabel.isEmpty, areaLabel != "Nearby" {
            content.subtitle = "Near \(areaLabel)"
        }
        content.body = "Are you about to leave? Share your spot and help nearby drivers."
        content.sound = .default
        content.userInfo = [
            "type": "parking-reminder",
            "areaLabel": reminder.areaLabel ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: Keys.notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        try? await center.add(request)
        updateDebugState(.notificationScheduled)

        clearActiveReminderOnly()
    }

    private var hasExitedRegion: Bool {
        defaults.bool(forKey: Keys.hasExitedRegion)
    }

    private func setHasExitedRegion(_ value: Bool) {
        defaults.set(value, forKey: Keys.hasExitedRegion)
    }

    private func clearActiveReminderOnly() {
        stopMonitoringReminderRegion()
        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        defaults.removeObject(forKey: Keys.activeReminder)
        defaults.removeObject(forKey: Keys.hasExitedRegion)
        activeReminder = nil
    }

    private func persist(_ reminder: Reminder, key: String) {
        guard let data = try? JSONEncoder().encode(reminder) else { return }
        defaults.set(data, forKey: key)
    }

    private func updateDebugState(_ state: DebugState) {
        debugState = state
        defaults.set(state.rawValue, forKey: Keys.debugState)
    }

    private static func loadReminder(from defaults: UserDefaults, key: String) -> Reminder? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Reminder.self, from: data)
    }

    private static func loadDebugState(from defaults: UserDefaults) -> DebugState? {
        guard let rawValue = defaults.string(forKey: Keys.debugState) else { return nil }
        return DebugState(rawValue: rawValue)
    }

    private static func derivedDebugState(activeReminder: Reminder?, hasExitedRegion: Bool) -> DebugState {
        guard activeReminder != nil else { return .noReminder }
        return hasExitedRegion ? .exitedWaitingForReturn : .armed
    }

    private func removeExpiredSavedLocationIfNeeded(now: Date = .now) {
        guard let savedParkedLocation else { return }
        guard now.timeIntervalSince(savedParkedLocation.createdAt) > Self.parkedLocationRetentionInterval else { return }
        defaults.removeObject(forKey: Keys.savedParkedLocation)
        self.savedParkedLocation = nil
    }

    private func normalizedAreaLabel(_ areaLabel: String?) -> String? {
        guard let areaLabel else { return nil }
        let trimmed = areaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Nearby" else { return nil }
        return trimmed
    }
}

extension ParkingReminderStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            await self?.restoreMonitoringIfNeeded()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Keys.regionIdentifier else { return }
        Task { @MainActor [weak self] in
            await self?.handleRegionEntry()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Keys.regionIdentifier else { return }
        Task { @MainActor [weak self] in
            self?.handleRegionExit()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Keys.regionIdentifier else { return }
        Task { @MainActor [weak self] in
            switch state {
            case .outside:
                self?.handleRegionExit()
            case .inside, .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Swift.Error) {
    }
}
