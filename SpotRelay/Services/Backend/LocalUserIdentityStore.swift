import Combine
import Foundation

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

@MainActor
protocol UserIdentityProviding: AnyObject {
    var currentUser: AppUser { get }
    var currentUserPublisher: AnyPublisher<AppUser, Never> { get }
    func recordCompletedHandoff(success: Bool) -> AppUser
}

@MainActor
final class LocalUserIdentityStore: UserIdentityProviding {
    private let defaults: UserDefaults
    private let subject: CurrentValueSubject<AppUser, Never>
    private(set) var currentUser: AppUser

    private enum Keys {
        static let userID = "identity.userID"
        static let successfulHandoffs = "identity.successfulHandoffs"
        static let noShowCount = "identity.noShowCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let userID = defaults.string(forKey: Keys.userID) ?? UUID().uuidString
        defaults.set(userID, forKey: Keys.userID)

        currentUser = AppUser(
            id: userID,
            displayName: "You",
            successfulHandoffs: defaults.integer(forKey: Keys.successfulHandoffs),
            noShowCount: defaults.integer(forKey: Keys.noShowCount)
        )
        subject = CurrentValueSubject(currentUser)
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    func recordCompletedHandoff(success: Bool) -> AppUser {
        if success {
            currentUser.successfulHandoffs += 1
            defaults.set(currentUser.successfulHandoffs, forKey: Keys.successfulHandoffs)
        } else {
            currentUser.noShowCount += 1
            defaults.set(currentUser.noShowCount, forKey: Keys.noShowCount)
        }

        subject.send(currentUser)
        return currentUser
    }
}

#if canImport(FirebaseAuth)
@MainActor
final class FirebaseUserIdentityStore: UserIdentityProviding {
    private let defaults: UserDefaults
    private let subject: CurrentValueSubject<AppUser, Never>
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private(set) var currentUser: AppUser

    private enum Keys {
        static let successfulHandoffs = "firebaseIdentity.successfulHandoffs"
        static let noShowCount = "firebaseIdentity.noShowCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let initialUser = AppUser(
            id: Auth.auth().currentUser?.uid ?? "firebase-auth-pending",
            displayName: "You",
            successfulHandoffs: defaults.integer(forKey: Keys.successfulHandoffs),
            noShowCount: defaults.integer(forKey: Keys.noShowCount)
        )

        self.currentUser = initialUser
        self.subject = CurrentValueSubject(initialUser)

        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self, let user else { return }
            Task { @MainActor in
                self.applyAuthenticatedUserID(user.uid)
            }
        }

        if let currentUser = Auth.auth().currentUser {
            applyAuthenticatedUserID(currentUser.uid)
        } else {
            Auth.auth().signInAnonymously { _, _ in }
        }
    }

    deinit {
        if let authStateListener {
            Auth.auth().removeStateDidChangeListener(authStateListener)
        }
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    func recordCompletedHandoff(success: Bool) -> AppUser {
        if success {
            currentUser.successfulHandoffs += 1
            defaults.set(currentUser.successfulHandoffs, forKey: Keys.successfulHandoffs)
        } else {
            currentUser.noShowCount += 1
            defaults.set(currentUser.noShowCount, forKey: Keys.noShowCount)
        }

        subject.send(currentUser)
        return currentUser
    }

    private func applyAuthenticatedUserID(_ userID: String) {
        guard currentUser.id != userID else { return }

        currentUser = AppUser(
            id: userID,
            displayName: currentUser.displayName,
            successfulHandoffs: currentUser.successfulHandoffs,
            noShowCount: currentUser.noShowCount
        )
        subject.send(currentUser)
    }
}
#endif
