import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            defaults.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey)
        }
    }

    private let defaults: UserDefaults

    private static let hasCompletedOnboardingKey = "session.hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Self.hasCompletedOnboardingKey)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}
