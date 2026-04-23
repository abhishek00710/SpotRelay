import Combine
import Foundation
import UserNotifications
import UIKit

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
import FirebaseAuth
import FirebaseFirestore
#endif

@MainActor
final class PushNotificationStore: ObservableObject {
    static let shared = PushNotificationStore()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var fcmToken: String?
    @Published private(set) var apnsToken: String?
    @Published private(set) var lastRegistrationError: String?

    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private var backendMode: SpotRelayBackendMode = .localFallback(reason: "Not configured")
    private var currentUserID: String?
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let installationID = "notifications.installationID"
        static let installationCreatedAt = "notifications.installationCreatedAt"
    }

    private init(
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current()
    ) {
        self.defaults = defaults
        self.center = center

        Task {
            await refreshAuthorizationStatus()
        }
    }

    var installationID: String {
        if let value = defaults.string(forKey: Keys.installationID), !value.isEmpty {
            return value
        }

        let generated = UUID().uuidString
        defaults.set(generated, forKey: Keys.installationID)
        return generated
    }

    private var installationCreatedAt: Date {
        if let value = defaults.object(forKey: Keys.installationCreatedAt) as? Date {
            return value
        }

        let createdAt = Date()
        defaults.set(createdAt, forKey: Keys.installationCreatedAt)
        return createdAt
    }

    var isAuthorizedForNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func configure(
        backendMode: SpotRelayBackendMode,
        currentUser: AppUser,
        userPublisher: AnyPublisher<AppUser, Never>
    ) {
        self.backendMode = backendMode
        self.currentUserID = currentUser.id
        cancellables.removeAll()

        userPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] user in
                guard let self else { return }
                self.currentUserID = user.id
                Task { @MainActor in
                    await self.persistDeviceStateIfPossible()
                }
            }
            .store(in: &cancellables)

        Task {
            await refreshAuthorizationStatus()
            await persistDeviceStateIfPossible()
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            await persistDeviceStateIfPossible()
            return granted
        } catch {
            lastRegistrationError = error.localizedDescription
            await refreshAuthorizationStatus()
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func registerForRemoteNotificationsIfAuthorized() {
        guard isAuthorizedForNotifications else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func handleAPNSToken(_ tokenData: Data) {
        apnsToken = tokenData.map { String(format: "%02.2hhx", $0) }.joined()
        lastRegistrationError = nil
        Task {
            await persistDeviceStateIfPossible()
        }
    }

    func handleFCMToken(_ token: String?) {
        fcmToken = token
        lastRegistrationError = nil
        Task {
            await persistDeviceStateIfPossible()
        }
    }

    func handleRemoteRegistrationFailure(_ error: Error) {
        lastRegistrationError = error.localizedDescription
    }

    func handleForegroundNotification(userInfo: [AnyHashable: Any]) {
        #if DEBUG
        print("SpotRelay foreground push:", userInfo)
        #endif
    }

    func handleNotificationResponse(userInfo: [AnyHashable: Any]) {
        #if DEBUG
        print("SpotRelay notification response:", userInfo)
        #endif
    }

    func handleRemoteMessage(userInfo: [AnyHashable: Any]) {
        #if DEBUG
        print("SpotRelay remote message:", userInfo)
        #endif
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func persistDeviceStateIfPossible() async {
        guard backendMode.isFirebase else { return }
        guard let currentUserID, currentUserID != "firebase-auth-pending" else { return }

        #if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
        guard Auth.auth().currentUser?.uid == currentUserID else { return }

        let document: [String: Any] = [
            "installationID": installationID,
            "platform": "ios",
            "bundleID": Bundle.main.bundleIdentifier ?? "com.SAAAin.SpotRelay",
            "fcmToken": fcmToken ?? "",
            "apnsToken": apnsToken ?? "",
            "authorizationStatus": authorizationStatus.firestoreValue,
            "notificationsAuthorized": isAuthorizedForNotifications,
            "createdAt": installationCreatedAt,
            "updatedAt": Date()
        ]

        let reference = Firestore.firestore()
            .collection("users")
            .document(currentUserID)
            .collection("devices")
            .document(installationID)

        do {
            try await setDocument(document, at: reference)
        } catch {
            lastRegistrationError = error.localizedDescription
        }
        #endif
    }

    #if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
    private func setDocument(_ data: [String: Any], at reference: DocumentReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setData(data, merge: true) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    #endif
}

private extension UNAuthorizationStatus {
    var firestoreValue: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }
}
