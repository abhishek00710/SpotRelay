//
//  SpotRelayApp.swift
//  SpotRelay
//
//  Created by Abhishek Gang Deb on 4/19/26.
//

import SwiftUI

@main
struct SpotRelayApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var spotStore = SpotStore()

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(spotStore)
        }
    }
}
