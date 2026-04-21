//
//  SpotRelayApp.swift
//  SpotRelay
//
//  Created by Abhishek Gang Deb on 4/19/26.
//

import SwiftUI

@main
struct SpotRelayApp: App {
    @StateObject private var session: SessionStore
    @StateObject private var spotStore: SpotStore

    init() {
        let sessionStore = SessionStore()
        let backendSelection = SpotRelayBackendFactory.makeBackend()
        let userIdentity = SpotRelayBackendFactory.makeUserIdentityStore(for: backendSelection.mode)

        _session = StateObject(wrappedValue: sessionStore)
        _spotStore = StateObject(
            wrappedValue: SpotStore(
                repository: backendSelection.repository,
                userIdentity: userIdentity,
                backendMode: backendSelection.mode
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(spotStore)
        }
    }
}
