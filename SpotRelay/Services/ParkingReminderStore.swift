import Combine
import CoreLocation
import Foundation
import UserNotifications
import UIKit

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
                return L10n.tr("We'll nudge you when you're back near this parked spot.")
            }
            return L10n.format("We'll nudge you when you're back near %@.", areaLabel)
        }

        func coordinateDistanceText(from coordinate: CLLocationCoordinate2D) -> String {
            let meters = Int(distanceMeters(from: coordinate).rounded())
            return L10n.format("%d m", meters)
        }

        func distanceMeters(from coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
            let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let destination = CLLocation(latitude: self.coordinate.latitude, longitude: self.coordinate.longitude)
            return origin.distance(from: destination)
        }
    }

    enum Error: LocalizedError {
        case locationAuthorizationRequired
        case regionMonitoringUnavailable

        var errorDescription: String? {
            switch self {
            case .locationAuthorizationRequired:
                return L10n.tr("Always location access is required for parked-car return reminders.")
            case .regionMonitoringUnavailable:
                return L10n.tr("This device can't monitor parked-car reminder regions.")
            }
        }
    }

    enum DebugState: String, Codable, Equatable {
        case noReminder
        case armed
        case exitedWaitingForReturn
        case nearCarWaitingForVehicleConnection
        case notificationScheduled
        case pausedNeedsAlwaysLocation
        case monitoringUnavailable
        case notificationsDisabled

        var title: String {
            switch self {
            case .noReminder:
                return L10n.tr("No parked reminder armed")
            case .armed:
                return L10n.tr("Parked reminder armed")
            case .exitedWaitingForReturn:
                return L10n.tr("Left parked zone")
            case .nearCarWaitingForVehicleConnection:
                return L10n.tr("Near parked car")
            case .notificationScheduled:
                return L10n.tr("Return notification scheduled")
            case .pausedNeedsAlwaysLocation:
                return L10n.tr("Reminder paused")
            case .monitoringUnavailable:
                return L10n.tr("Region monitoring unavailable")
            case .notificationsDisabled:
                return L10n.tr("Notifications off")
            }
        }

        var detail: String {
            switch self {
            case .noReminder:
                return L10n.tr("SpotRelay hasn't armed a parked-car return reminder yet.")
            case .armed:
                return L10n.tr("Monitoring your parked spot now.")
            case .exitedWaitingForReturn:
                return L10n.tr("Waiting for you to come back to the parked spot.")
            case .nearCarWaitingForVehicleConnection:
                return L10n.tr("Waiting for CarPlay or car Bluetooth before nudging.")
            case .notificationScheduled:
                return L10n.tr("SpotRelay detected your return and queued the local notification.")
            case .pausedNeedsAlwaysLocation:
                return L10n.tr("Always location is required for the parked-car reminder to keep working.")
            case .monitoringUnavailable:
                return L10n.tr("This device can't monitor the parked-car region.")
            case .notificationsDisabled:
                return L10n.tr("Turn notifications on so SpotRelay can show the parked-car return nudge.")
            }
        }

        var shouldDisplay: Bool {
            self != .noReminder
        }
    }

    enum VehicleConnectionReminderOutcome: Equatable {
        case noActiveReminder
        case waitingForExitOrAge
        case waitingForUsableLocation
        case outsideReturnDistance(distanceMeters: CLLocationDistance, allowedMeters: CLLocationDistance)
        case alreadyNudged
        case notificationsDisabled
        case scheduled
        case failed
    }

    nonisolated static let defaultRadiusMeters: Double = 75
    nonisolated private static let fallbackExitDistanceMeters: Double = 90
    nonisolated private static let fallbackReturnDistanceMeters: Double = 45
    nonisolated private static let fallbackReturnWithoutExitMinimumAge: TimeInterval = 20 * 60
    nonisolated private static let vehicleConnectionReturnWithoutExitMinimumAge: TimeInterval = 2 * 60
    nonisolated private static let vehicleConnectionReturnDistanceMeters: CLLocationDistance = 200
    nonisolated private static let vehicleConnectionLocationMaximumAge: TimeInterval = 5 * 60
    nonisolated private static let vehicleConnectionLocationMaximumAccuracyMeters: CLLocationAccuracy = 150
    nonisolated fileprivate static let radiusToleranceMeters: Double = 1
    nonisolated static let parkedLocationRetentionInterval: TimeInterval = 48 * 60 * 60
    nonisolated private static let parkedLocationHistoryLimit = 10
    nonisolated private static let parkedLocationHistoryDuplicateDistanceMeters: CLLocationDistance = 18
    nonisolated private static let parkedLocationHistoryDuplicateTimeWindow: TimeInterval = 6 * 60 * 60
    nonisolated private static let nudgedSessionDuplicateDistanceMeters: CLLocationDistance = 35
    nonisolated private static let nudgedSessionDuplicateTimeWindow: TimeInterval = 12 * 60 * 60
    nonisolated private static let vehicleConnectionNotificationLeadTime: TimeInterval = 3

    @Published private(set) var activeReminder: Reminder?
    @Published private(set) var savedParkedLocation: Reminder?
    @Published private(set) var parkedLocationHistory: [Reminder]
    @Published private(set) var debugState: DebugState

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let locationManager: CLLocationManager
    private var lastNudgedReminder: Reminder?

    private enum Keys {
        static let activeReminder = "parkingReminder.active"
        static let savedParkedLocation = "parkingReminder.savedLocation"
        static let parkedLocationHistory = "parkingReminder.history"
        static let lastNudgedReminder = "parkingReminder.lastNudgedReminder"
        static let hasExitedRegion = "parkingReminder.hasExitedRegion"
        static let debugState = "parkingReminder.debugState"
        nonisolated static let regionIdentifier = "parkingReminder.returnToCar.region"
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
        self.parkedLocationHistory = Self.loadReminderHistory(from: defaults)
        self.lastNudgedReminder = Self.loadReminder(from: defaults, key: Keys.lastNudgedReminder)
        self.debugState = Self.loadDebugState(from: defaults)
            ?? Self.derivedDebugState(
                activeReminder: Self.loadReminder(from: defaults, key: Keys.activeReminder),
                hasExitedRegion: defaults.bool(forKey: Keys.hasExitedRegion)
            )
        super.init()

        self.locationManager.delegate = self

        normalizeReminderRadiiIfNeeded()
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

    var latestRememberedParkedLocation: Reminder? {
        savedParkedLocation ?? parkedLocationHistory.first
    }

    var hasRememberedParkedLocations: Bool {
        latestRememberedParkedLocation != nil
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
        persistUpdatedHistory(adding: reminder)
        setHasExitedRegion(false)
        activeReminder = reminder
        savedParkedLocation = reminder
        updateDebugState(.armed)
        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])

        let region = monitoredRegion(for: reminder)
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
        updateSignificantLocationMonitoringIfNeeded()
    }

    func clearReminder() async {
        clearActiveReminderOnly()
        defaults.removeObject(forKey: Keys.savedParkedLocation)
        savedParkedLocation = nil
        updateDebugState(.noReminder)
    }

    @discardableResult
    func retireCurrentParkedSpotForDriving() -> Bool {
        guard activeReminder != nil || savedParkedLocation != nil else { return false }
        clearActiveReminderOnly()
        defaults.removeObject(forKey: Keys.savedParkedLocation)
        savedParkedLocation = nil
        updateDebugState(.noReminder)
        return true
    }

    @discardableResult
    func noteMovedAwayFromParkedSpot() -> Bool {
        guard activeReminder != nil else { return false }
        guard !hasExitedRegion else { return false }

        setHasExitedRegion(true)
        updateDebugState(.exitedWaitingForReturn)
        return true
    }

    func seedTemporaryTestingParkedSpot(
        at coordinate: CLLocationCoordinate2D,
        areaLabel: String?,
        radiusMeters: Double = defaultRadiusMeters
    ) {
        let reminder = Reminder(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: .now,
            areaLabel: normalizedAreaLabel(areaLabel),
            radiusMeters: radiusMeters
        )

        persist(reminder, key: Keys.savedParkedLocation)
        persistUpdatedHistory(adding: reminder)
        savedParkedLocation = reminder

        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
           locationManager.authorizationStatus == .authorizedAlways {
            stopMonitoringReminderRegion()
            persist(reminder, key: Keys.activeReminder)
            setHasExitedRegion(false)
            activeReminder = reminder
            let region = monitoredRegion(for: reminder)
            locationManager.startMonitoring(for: region)
            locationManager.requestState(for: region)
            updateSignificantLocationMonitoringIfNeeded()
            updateDebugState(.armed)
        } else {
            activeReminder = nil
            defaults.removeObject(forKey: Keys.activeReminder)
            defaults.removeObject(forKey: Keys.hasExitedRegion)
            updateDebugState(.noReminder)
        }
    }

    func refreshReminderState() async {
        activeReminder = Self.loadReminder(from: defaults, key: Keys.activeReminder)
        savedParkedLocation = Self.loadReminder(from: defaults, key: Keys.savedParkedLocation)
        parkedLocationHistory = Self.loadReminderHistory(from: defaults)
        lastNudgedReminder = Self.loadReminder(from: defaults, key: Keys.lastNudgedReminder)
        normalizeReminderRadiiIfNeeded()
        removeExpiredSavedLocationIfNeeded()
        await restoreMonitoringIfNeeded()
    }

    func verifyReturnProximityFallback(at coordinate: CLLocationCoordinate2D) async {
        guard let reminder = activeReminder else { return }

        let distance = reminder.distanceMeters(from: coordinate)
        if distance >= Self.fallbackExitDistanceMeters {
            handleRegionExit()
            return
        }

        if hasExitedRegion, distance <= Self.fallbackReturnDistanceMeters {
            handleRegionEntry()
            return
        }

        let reminderAge = Date().timeIntervalSince(reminder.createdAt)
        if !hasExitedRegion,
           reminderAge >= Self.fallbackReturnWithoutExitMinimumAge,
           distance <= Self.fallbackReturnDistanceMeters {
            handleRegionEntry(allowWithoutRecordedExit: true)
        }
    }

    func handleVehicleConnectionNearParkedCar(
        sourceSummary: String,
        location: CLLocation?
    ) async -> VehicleConnectionReminderOutcome {
        guard let reminder = activeReminder else { return .noActiveReminder }

        let reminderAge = Date().timeIntervalSince(reminder.createdAt)
        guard hasExitedRegion || reminderAge >= Self.vehicleConnectionReturnWithoutExitMinimumAge else {
            updateDebugState(.armed)
            return .waitingForExitOrAge
        }

        guard let latestLocation = location ?? locationManager.location,
              latestLocation.horizontalAccuracy >= 0,
              latestLocation.horizontalAccuracy <= Self.vehicleConnectionLocationMaximumAccuracyMeters,
              abs(latestLocation.timestamp.timeIntervalSinceNow) <= Self.vehicleConnectionLocationMaximumAge else {
            updateDebugState(.nearCarWaitingForVehicleConnection)
            return .waitingForUsableLocation
        }

        let returnDistance = reminder.distanceMeters(from: latestLocation.coordinate)
        let allowedDistance = max(Self.vehicleConnectionReturnDistanceMeters, reminder.radiusMeters + 20)
        guard returnDistance <= allowedDistance else {
            updateDebugState(.exitedWaitingForReturn)
            return .outsideReturnDistance(distanceMeters: returnDistance, allowedMeters: allowedDistance)
        }

        return await scheduleReturnNotification(
            for: reminder,
            triggerSummary: sourceSummary
        )
    }

    private func restoreMonitoringIfNeeded() async {
        guard let reminder = activeReminder else {
            stopMonitoringReminderRegion()
            locationManager.stopMonitoringSignificantLocationChanges()
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

        let monitoredReminderRegion = locationManager.monitoredRegions.first { region in
            region.identifier == Keys.regionIdentifier
        }

        if let monitoredReminderRegion, !monitoredReminderRegion.matches(reminder) {
            locationManager.stopMonitoring(for: monitoredReminderRegion)
        }

        if monitoredReminderRegion == nil || monitoredReminderRegion?.matches(reminder) == false {
            let region = monitoredRegion(for: reminder)
            locationManager.startMonitoring(for: region)
        }

        if let monitoredRegion = locationManager.monitoredRegions.first(where: { $0.identifier == Keys.regionIdentifier }) {
            locationManager.requestState(for: monitoredRegion)
        }

        updateSignificantLocationMonitoringIfNeeded()

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

    private func updateSignificantLocationMonitoringIfNeeded() {
        guard activeReminder != nil,
              locationManager.authorizationStatus == .authorizedAlways else {
            locationManager.stopMonitoringSignificantLocationChanges()
            return
        }

        locationManager.startMonitoringSignificantLocationChanges()
    }

    private func handleRegionExit() {
        guard activeReminder != nil else { return }
        setHasExitedRegion(true)
        updateDebugState(.exitedWaitingForReturn)
    }

    private func handleRegionEntry(allowWithoutRecordedExit: Bool = false) {
        guard let reminder = activeReminder else { return }
        guard hasExitedRegion || allowWithoutRecordedExit else { return }
        guard !hasAlreadyNudgedForSameSession(reminder) else {
            updateDebugState(.notificationScheduled)
            clearActiveReminderOnly(preservingNotification: true)
            return
        }

        updateDebugState(.nearCarWaitingForVehicleConnection)
    }

    private func scheduleReturnNotification(
        for reminder: Reminder,
        triggerSummary: String
    ) async -> VehicleConnectionReminderOutcome {
        guard !hasAlreadyNudgedForSameSession(reminder) else {
            updateDebugState(.notificationScheduled)
            clearActiveReminderOnly(preservingNotification: true)
            return .alreadyNudged
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional ||
              settings.authorizationStatus == .ephemeral else {
            ParkingSequenceLogger.shared.append(
                "Return notification not scheduled: authorizationStatus=\(settings.authorizationStatus.rawValue)"
            )
            updateDebugState(.notificationsDisabled)
            return .notificationsDisabled
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("Back at your car?")
        if let areaLabel = reminder.areaLabel, !areaLabel.isEmpty, areaLabel != "Nearby" {
            content.subtitle = L10n.format("Near %@", areaLabel)
        }
        content.body = L10n.tr("Are you about to leave? Share your spot and help nearby drivers.")
        content.sound = .default
        content.userInfo = [
            "type": "parking-reminder",
            "areaLabel": reminder.areaLabel ?? "",
            "trigger": triggerSummary
        ]

        let request = UNNotificationRequest(
            identifier: Keys.notificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: Self.vehicleConnectionNotificationLeadTime,
                repeats: false
            )
        )

        let appState = Self.applicationStateSummary
        ParkingSequenceLogger.shared.append(
            "Return notification preparing: id=\(Keys.notificationIdentifier), trigger=\(triggerSummary), appState=\(appState), reminderAge=\(Int(Date().timeIntervalSince(reminder.createdAt).rounded()))s"
        )
        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        do {
            try await center.add(request)
            let pendingDescription = await pendingNotificationDescription(for: Keys.notificationIdentifier)
            ParkingSequenceLogger.shared.append(
                "Return notification add succeeded: id=\(Keys.notificationIdentifier), title=\(content.title), trigger=\(triggerSummary), area=\(reminder.areaLabel ?? "unknown area"), appState=\(appState), fireIn=\(Int(Self.vehicleConnectionNotificationLeadTime))s, pending=\(pendingDescription)"
            )
            persist(reminder, key: Keys.lastNudgedReminder)
            lastNudgedReminder = reminder
            updateDebugState(.notificationScheduled)
            clearActiveReminderOnly(preservingNotification: true)
            return .scheduled
        } catch {
            ParkingSequenceLogger.shared.append(
                "Return notification add failed: id=\(Keys.notificationIdentifier), error=\(error.localizedDescription)"
            )
            #if DEBUG
            print("SpotRelay parked reminder notification failed:", error.localizedDescription)
            #endif
            return .failed
        }
    }

    private var hasExitedRegion: Bool {
        defaults.bool(forKey: Keys.hasExitedRegion)
    }

    private func setHasExitedRegion(_ value: Bool) {
        defaults.set(value, forKey: Keys.hasExitedRegion)
    }

    private func clearActiveReminderOnly(preservingNotification: Bool = false) {
        stopMonitoringReminderRegion()
        locationManager.stopMonitoringSignificantLocationChanges()
        if !preservingNotification {
            Task { @MainActor in
                let pendingDescription = await pendingNotificationDescription(for: Keys.notificationIdentifier)
                let deliveredCount = await deliveredNotificationCount(for: Keys.notificationIdentifier)
                ParkingSequenceLogger.shared.append(
                    "Return notification clearing: id=\(Keys.notificationIdentifier), pending=\(pendingDescription), deliveredCount=\(deliveredCount)"
                )
            }
            center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        }
        defaults.removeObject(forKey: Keys.activeReminder)
        defaults.removeObject(forKey: Keys.hasExitedRegion)
        activeReminder = nil
    }

    private func pendingNotificationDescription(for identifier: String) async -> String {
        let requests = await pendingNotificationRequests()
        guard let request = requests.first(where: { $0.identifier == identifier }) else {
            return "none"
        }

        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
            return "timeInterval:\(Int(trigger.timeInterval.rounded()))s repeats=\(trigger.repeats)"
        }
        if request.trigger is UNLocationNotificationTrigger {
            return "location"
        }
        if request.trigger is UNCalendarNotificationTrigger {
            return "calendar"
        }
        return request.trigger == nil ? "immediate" : "other"
    }

    private func deliveredNotificationCount(for identifier: String) async -> Int {
        let notifications = await deliveredNotifications()
        return notifications.filter { $0.request.identifier == identifier }.count
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func deliveredNotifications() async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
    }

    private static var applicationStateSummary: String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func persist(_ reminder: Reminder, key: String) {
        guard let data = try? JSONEncoder().encode(reminder) else { return }
        defaults.set(data, forKey: key)
    }

    private func persist(_ reminders: [Reminder], key: String) {
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        defaults.set(data, forKey: key)
    }

    private func persistUpdatedHistory(adding reminder: Reminder) {
        var history = parkedLocationHistory
        history.removeAll { existing in
            existing.representsSameParkingSession(
                as: reminder,
                distanceThreshold: Self.parkedLocationHistoryDuplicateDistanceMeters,
                timeThreshold: Self.parkedLocationHistoryDuplicateTimeWindow
            )
        }
        history.insert(reminder, at: 0)
        history = Self.limitedHistory(history)
        parkedLocationHistory = history
        persist(history, key: Keys.parkedLocationHistory)
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

    private static func loadReminderHistory(from defaults: UserDefaults) -> [Reminder] {
        guard let data = defaults.data(forKey: Keys.parkedLocationHistory),
              let reminders = try? JSONDecoder().decode([Reminder].self, from: data) else {
            return []
        }
        return limitedHistory(reminders)
    }

    private static func derivedDebugState(activeReminder: Reminder?, hasExitedRegion: Bool) -> DebugState {
        guard activeReminder != nil else { return .noReminder }
        return hasExitedRegion ? .exitedWaitingForReturn : .armed
    }

    private func normalizeReminderRadiiIfNeeded() {
        if let activeReminder {
            let normalized = activeReminder.normalizedRadius()
            if normalized != activeReminder {
                self.activeReminder = normalized
                persist(normalized, key: Keys.activeReminder)
            }
        }

        if let savedParkedLocation {
            let normalized = savedParkedLocation.normalizedRadius()
            if normalized != savedParkedLocation {
                self.savedParkedLocation = normalized
                persist(normalized, key: Keys.savedParkedLocation)
            }
        }

        let normalizedHistory = Self.limitedHistory(parkedLocationHistory.map { $0.normalizedRadius() })
        if normalizedHistory != parkedLocationHistory {
            parkedLocationHistory = normalizedHistory
            persist(normalizedHistory, key: Keys.parkedLocationHistory)
        }
    }

    private static func limitedHistory(_ history: [Reminder]) -> [Reminder] {
        Array(history.prefix(parkedLocationHistoryLimit))
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

    private func hasAlreadyNudgedForSameSession(_ reminder: Reminder) -> Bool {
        guard let lastNudgedReminder else { return false }
        return lastNudgedReminder.representsSameParkingSession(
            as: reminder,
            distanceThreshold: Self.nudgedSessionDuplicateDistanceMeters,
            timeThreshold: Self.nudgedSessionDuplicateTimeWindow
        )
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
            self?.handleRegionEntry()
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
            case .inside:
                self?.handleRegionEntry(allowWithoutRecordedExit: false)
            case .unknown:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor [weak self] in
            await self?.verifyReturnProximityFallback(at: coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Swift.Error) {
    }
}

private extension ParkingReminderStore.Reminder {
    func normalizedRadius() -> Self {
        guard abs(radiusMeters - ParkingReminderStore.defaultRadiusMeters) > ParkingReminderStore.radiusToleranceMeters else {
            return self
        }

        return .init(
            latitude: latitude,
            longitude: longitude,
            createdAt: createdAt,
            areaLabel: areaLabel,
            radiusMeters: ParkingReminderStore.defaultRadiusMeters
        )
    }

    func representsSameParkingSession(
        as other: Self,
        distanceThreshold: CLLocationDistance,
        timeThreshold: TimeInterval
    ) -> Bool {
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let destination = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return origin.distance(from: destination) <= distanceThreshold &&
            abs(createdAt.timeIntervalSince(other.createdAt)) <= timeThreshold
    }
}

private extension CLRegion {
    func matches(_ reminder: ParkingReminderStore.Reminder) -> Bool {
        guard let region = self as? CLCircularRegion else { return false }
        let centerDistance = CLLocation(
            latitude: region.center.latitude,
            longitude: region.center.longitude
        ).distance(from: CLLocation(
            latitude: reminder.latitude,
            longitude: reminder.longitude
        ))

        return centerDistance <= ParkingReminderStore.radiusToleranceMeters &&
            abs(region.radius - reminder.radiusMeters) <= ParkingReminderStore.radiusToleranceMeters
    }
}
