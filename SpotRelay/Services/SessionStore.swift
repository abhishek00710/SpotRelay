import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published var hasCompletedOnboarding = false

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}
