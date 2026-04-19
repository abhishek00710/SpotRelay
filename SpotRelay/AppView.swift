import SwiftUI

struct AppView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var spotStore: SpotStore
    @State private var showingPostSpotFlow = false
    @State private var selectedSpot: ParkingSpotSignal?

    private var isShowingActiveHandoff: Binding<Bool> {
        Binding(
            get: { spotStore.activeHandoff != nil },
            set: { shouldShow in
                if !shouldShow {
                    spotStore.activeHandoffID = nil
                }
            }
        )
    }

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
                        .presentationDetents([.fraction(0.52)])
                        .presentationDragIndicator(.visible)
                }
                .sheet(item: $selectedSpot) { spot in
                    SpotDetailSheet(
                        spot: spot,
                        onClaim: {
                            spotStore.claimSpot(id: spot.id)
                            selectedSpot = nil
                        }
                    )
                    .presentationDetents([.fraction(0.42)])
                    .presentationDragIndicator(.visible)
                }
                .fullScreenCover(isPresented: isShowingActiveHandoff) {
                    if let handoff = spotStore.activeHandoff {
                        ActiveHandoffView(signal: handoff)
                    }
                }
            } else {
                OnboardingFlowView {
                    session.completeOnboarding()
                }
            }
        }
        .tint(SpotRelayTheme.primary)
    }
}

