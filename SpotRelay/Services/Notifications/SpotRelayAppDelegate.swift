import Foundation
import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

@MainActor
final class SpotRelayAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        #if canImport(FirebaseMessaging)
        if FirebaseApp.app() != nil {
            Messaging.messaging().delegate = self
            refreshFCMTokenIfPossible()
        }
        #endif

        PushNotificationStore.shared.registerForRemoteNotificationsIfAuthorized()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if canImport(FirebaseMessaging)
        if FirebaseApp.app() != nil {
            #if DEBUG
            Messaging.messaging().setAPNSToken(deviceToken, type: .sandbox)
            #else
            Messaging.messaging().setAPNSToken(deviceToken, type: .prod)
            #endif
            refreshFCMTokenIfPossible()
        }
        #endif

        PushNotificationStore.shared.handleAPNSToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationStore.shared.handleRemoteRegistrationFailure(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if canImport(FirebaseMessaging)
        if FirebaseApp.app() != nil {
            Messaging.messaging().appDidReceiveMessage(userInfo)
        }
        #endif

        PushNotificationStore.shared.handleRemoteMessage(userInfo: userInfo)
        completionHandler(.newData)
    }
}

extension SpotRelayAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        #if canImport(FirebaseMessaging)
        if FirebaseApp.app() != nil {
            Messaging.messaging().appDidReceiveMessage(userInfo)
        }
        #endif

        PushNotificationStore.shared.handleForegroundNotification(userInfo: userInfo)
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        PushNotificationStore.shared.handleNotificationResponse(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
private extension SpotRelayAppDelegate {
    func refreshFCMTokenIfPossible() {
        Messaging.messaging().token { token, error in
            Task { @MainActor in
                if let error {
                    PushNotificationStore.shared.handleRemoteRegistrationFailure(error)
                } else {
                    PushNotificationStore.shared.handleFCMToken(token)
                }
            }
        }
    }
}
#endif

#if canImport(FirebaseMessaging)
extension SpotRelayAppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        PushNotificationStore.shared.handleFCMToken(fcmToken)
    }
}
#endif
