//
//  SpotRelayApp.swift
//  SpotRelay
//
//  Created by Abhishek Gang Deb on 4/19/26.
//

import SwiftUI

@main
struct SpotRelayApp: App {
    @UIApplicationDelegateAdaptor(SpotRelayAppDelegate.self) private var appDelegate
    @StateObject private var session: SessionStore
    @StateObject private var spotStore: SpotStore
    @StateObject private var pushNotificationStore: PushNotificationStore
    @StateObject private var parkingReminderStore: ParkingReminderStore
    @StateObject private var smartParkingStore: SmartParkingStore

    init() {
        let sessionStore = SessionStore()
        let backendSelection = SpotRelayBackendFactory.makeBackend()
        let userIdentity = SpotRelayBackendFactory.makeUserIdentityStore(for: backendSelection.mode)
        let pushStore = PushNotificationStore.shared
        let parkingStore = ParkingReminderStore()
        let smartParkingStore = SmartParkingStore(parkingReminderStore: parkingStore)

        _session = StateObject(wrappedValue: sessionStore)
        _spotStore = StateObject(
            wrappedValue: SpotStore(
                repository: backendSelection.repository,
                userIdentity: userIdentity,
                backendMode: backendSelection.mode
            )
        )
        _pushNotificationStore = StateObject(wrappedValue: pushStore)
        _parkingReminderStore = StateObject(wrappedValue: parkingStore)
        _smartParkingStore = StateObject(wrappedValue: smartParkingStore)

        pushStore.configure(
            backendMode: backendSelection.mode,
            currentUser: userIdentity.currentUser,
            userPublisher: userIdentity.currentUserPublisher
        )
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(spotStore)
                .environmentObject(pushNotificationStore)
                .environmentObject(parkingReminderStore)
                .environmentObject(smartParkingStore)
        }
    }
}
