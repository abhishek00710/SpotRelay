import StoreKit
import SwiftUI
import UIKit

struct AppView: View {
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var pushNotificationStore: PushNotificationStore
    @EnvironmentObject private var parkingReminderStore: ParkingReminderStore
    @EnvironmentObject private var smartParkingStore: SmartParkingStore
    @AppStorage("reviewPrompt.lastPromptedAppVersion") private var lastPromptedAppVersion = ""
    @AppStorage("reviewPrompt.successfulHandoffCountAtLastPrompt") private var successfulHandoffCountAtLastPrompt = 0
    @State private var showingPostSpotFlow = false
    @State private var selectedSpot: ParkingSpotSignal?
    @State private var showingActiveHandoff = false
    @State private var handoffPresentationTask: Task<Void, Never>?
    @State private var reviewPromptTask: Task<Void, Never>?

    private let minimumSuccessfulHandoffsBeforeReview = 2

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
                        .presentationDetents([.fraction(postSpotSheetFraction)])
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
        .onChange(of: spotStore.reviewPromptRequest?.id) { _, _ in
            scheduleReviewPromptIfAppropriate()
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

    private var postSpotSheetFraction: CGFloat {
        parkingReminderStore.savedParkedLocation == nil ? 0.42 : 0.55
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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

    private func scheduleReviewPromptIfAppropriate() {
        guard let reviewPromptRequest = spotStore.reviewPromptRequest else { return }
        guard reviewPromptRequest.successfulHandoffCount >= minimumSuccessfulHandoffsBeforeReview else { return }
        guard reviewPromptRequest.successfulHandoffCount > successfulHandoffCountAtLastPrompt else { return }
        guard lastPromptedAppVersion != currentAppVersion else { return }

        successfulHandoffCountAtLastPrompt = reviewPromptRequest.successfulHandoffCount
        lastPromptedAppVersion = currentAppVersion

        reviewPromptTask?.cancel()
        reviewPromptTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            requestReview()
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
