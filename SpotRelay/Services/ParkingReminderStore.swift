import Combine
import CoreLocation
import Foundation
import UserNotifications

@MainActor
final class ParkingReminderStore: ObservableObject {
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
    }

    nonisolated static let defaultRadiusMeters: Double = 150

    @Published private(set) var activeReminder: Reminder?

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    private enum Keys {
        static let activeReminder = "parkingReminder.active"
        static let notificationIdentifier = "parkingReminder.returnToCar"
    }

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        self.activeReminder = Self.loadReminder(from: defaults)

        Task {
            await refreshReminderState()
        }
    }

    var hasActiveReminder: Bool {
        activeReminder != nil
    }

    func rememberParkedSpot(
        at coordinate: CLLocationCoordinate2D,
        areaLabel: String?,
        radiusMeters: Double = defaultRadiusMeters
    ) async throws {
        let region = CLCircularRegion(
            center: coordinate,
            radius: radiusMeters,
            identifier: Keys.notificationIdentifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false

        let content = UNMutableNotificationContent()
        content.title = "Back at your car?"
        if let areaLabel, !areaLabel.isEmpty, areaLabel != "Nearby" {
            content.subtitle = "Near \(areaLabel)"
        }
        content.body = "Are you about to leave? Share your spot and help nearby drivers."
        content.sound = .default
        content.userInfo = [
            "type": "parking-reminder",
            "areaLabel": areaLabel ?? ""
        ]

        let trigger = UNLocationNotificationTrigger(region: region, repeats: false)
        let request = UNNotificationRequest(
            identifier: Keys.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        try await center.add(request)

        let reminder = Reminder(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            createdAt: .now,
            areaLabel: normalizedAreaLabel(areaLabel),
            radiusMeters: radiusMeters
        )

        persist(reminder)
        activeReminder = reminder
    }

    func clearReminder() async {
        center.removePendingNotificationRequests(withIdentifiers: [Keys.notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Keys.notificationIdentifier])
        defaults.removeObject(forKey: Keys.activeReminder)
        activeReminder = nil
    }

    func refreshReminderState() async {
        let pendingRequests = await pendingNotificationRequests()
        let isStillScheduled = pendingRequests.contains { $0.identifier == Keys.notificationIdentifier }

        guard isStillScheduled else {
            defaults.removeObject(forKey: Keys.activeReminder)
            activeReminder = nil
            return
        }

        activeReminder = Self.loadReminder(from: defaults)
    }

    private func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func persist(_ reminder: Reminder) {
        guard let data = try? JSONEncoder().encode(reminder) else { return }
        defaults.set(data, forKey: Keys.activeReminder)
    }

    private static func loadReminder(from defaults: UserDefaults) -> Reminder? {
        guard let data = defaults.data(forKey: Keys.activeReminder) else { return nil }
        return try? JSONDecoder().decode(Reminder.self, from: data)
    }

    private func normalizedAreaLabel(_ areaLabel: String?) -> String? {
        guard let areaLabel else { return nil }
        let trimmed = areaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Nearby" else { return nil }
        return trimmed
    }
}
