import SwiftUI
import UIKit

struct AppView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var pushNotificationStore: PushNotificationStore
    @EnvironmentObject private var parkingReminderStore: ParkingReminderStore
    @EnvironmentObject private var smartParkingStore: SmartParkingStore
    @State private var showingPostSpotFlow = false
    @State private var selectedSpot: ParkingSpotSignal?
    @State private var showingActiveHandoff = false
    @State private var handoffPresentationTask: Task<Void, Never>?

    var body: some View {
        Group {
            if session.hasCompletedOnboarding {
                NavigationStack {
                    HomeView(
                        onLeaveSoon: { showingPostSpotFlow = true },
                        onSelectSpot: { selectedSpot = $0 }
                    )
                }
                .sheet(isPresented: $showingPostSpotFlow) {
                    PostSpotFlowView()
                        .presentationDetents([.fraction(0.42)])
                        //.presentationDragIndicator(.visible)
                        //.presentationCornerRadius(32)
                        //.presentationBackground(SpotRelayTheme.elevatedBackground)
                }
                .sheet(item: $selectedSpot) { spot in
                    SpotDetailSheet(
                        spot: spot,
                        onClaim: {
                            Task {
                                if await spotStore.claimSpot(id: spot.id) {
                                    selectedSpot = nil
                                }
                            }
                        }
                    )
                    .presentationDetents([.fraction(0.42)])
                    //.presentationDragIndicator(.visible)
                    //.presentationCornerRadius(32)
                    //.presentationBackground(SpotRelayTheme.elevatedBackground)
                }
                .sheet(isPresented: $showingActiveHandoff) {
                    dismissActiveHandoff(clearSelection: true)
                } content: {
                    if let handoff = spotStore.activeHandoff {
                        ActiveHandoffView(
                            signal: handoff,
                            onClose: { dismissActiveHandoff(clearSelection: true) }
                        )
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                    } else {
                        Color.clear
                            .ignoresSafeArea()
                            .onAppear {
                                showingActiveHandoff = false
                            }
                    }
                }
            } else {
                OnboardingFlowView {
                    session.completeOnboarding()
                }
            }
        }
        .tint(SpotRelayTheme.primary)
        .onChange(of: spotStore.activeHandoffID) { _, newValue in
            handoffPresentationTask?.cancel()

            guard newValue != nil else {
                if showingActiveHandoff {
                    handoffPresentationTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        showingActiveHandoff = false
                    }
                } else {
                    showingActiveHandoff = false
                }
                return
            }

            scheduleActiveHandoffPresentationIfPossible()
        }
        .onChange(of: showingPostSpotFlow) { _, isShowing in
            guard !isShowing else {
                handoffPresentationTask?.cancel()
                return
            }
            scheduleActiveHandoffPresentationIfPossible()
        }
        .onChange(of: selectedSpot?.id) { _, selectedSpotID in
            guard selectedSpotID == nil else {
                handoffPresentationTask?.cancel()
                return
            }
            scheduleActiveHandoffPresentationIfPossible()
        }
        .task {
            await parkingReminderStore.refreshReminderState()
            smartParkingStore.refreshPermissions()
            await pushNotificationStore.refreshAuthorizationStatus()
            pushNotificationStore.registerForRemoteNotificationsIfAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await parkingReminderStore.refreshReminderState()
                smartParkingStore.refreshPermissions()
                await pushNotificationStore.refreshAuthorizationStatus()
                pushNotificationStore.registerForRemoteNotificationsIfAuthorized()
            }
        }
    }

    private var canPresentActiveHandoff: Bool {
        !showingPostSpotFlow && selectedSpot == nil
    }

    private func scheduleActiveHandoffPresentationIfPossible() {
        handoffPresentationTask?.cancel()

        guard spotStore.activeHandoff != nil, canPresentActiveHandoff else { return }

        handoffPresentationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            guard spotStore.activeHandoff != nil, canPresentActiveHandoff else { return }
            showingActiveHandoff = true
        }
    }

    private func dismissActiveHandoff(clearSelection: Bool) {
        handoffPresentationTask?.cancel()
        showingActiveHandoff = false
        if clearSelection {
            spotStore.activeHandoffID = nil
        }
    }
}
