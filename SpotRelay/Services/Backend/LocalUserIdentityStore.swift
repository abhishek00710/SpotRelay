import Combine
import Foundation

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

private func sanitizedProfileDisplayName(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "You" : trimmed
}

@MainActor
protocol UserIdentityProviding: AnyObject {
    var currentUser: AppUser { get }
    var currentUserPublisher: AnyPublisher<AppUser, Never> { get }
    func recordCompletedHandoff(success: Bool, as role: HandoffRole?) -> AppUser
    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser
}

@MainActor
final class LocalUserIdentityStore: UserIdentityProviding {
    private let defaults: UserDefaults
    private let subject: CurrentValueSubject<AppUser, Never>
    private(set) var currentUser: AppUser

    private enum Keys {
        static let userID = "identity.userID"
        static let displayName = "identity.displayName"
        static let joinedAt = "identity.joinedAt"
        static let successfulHandoffs = "identity.successfulHandoffs"
        static let successfulShares = "identity.successfulShares"
        static let noShowCount = "identity.noShowCount"
        static let avatarJPEGData = "identity.avatarJPEGData"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let userID = defaults.string(forKey: Keys.userID) ?? UUID().uuidString
        defaults.set(userID, forKey: Keys.userID)
        let displayName = sanitizedProfileDisplayName(defaults.string(forKey: Keys.displayName) ?? "You")
        defaults.set(displayName, forKey: Keys.displayName)
        let joinedAt = defaults.object(forKey: Keys.joinedAt) as? Date ?? .now
        defaults.set(joinedAt, forKey: Keys.joinedAt)

        currentUser = AppUser(
            id: userID,
            displayName: displayName,
            joinedAt: joinedAt,
            successfulHandoffs: defaults.integer(forKey: Keys.successfulHandoffs),
            successfulShares: defaults.integer(forKey: Keys.successfulShares),
            noShowCount: defaults.integer(forKey: Keys.noShowCount),
            avatarJPEGData: defaults.data(forKey: Keys.avatarJPEGData)
        )
        subject = CurrentValueSubject(currentUser)
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    func recordCompletedHandoff(success: Bool, as role: HandoffRole?) -> AppUser {
        if success {
            currentUser.successfulHandoffs += 1
            defaults.set(currentUser.successfulHandoffs, forKey: Keys.successfulHandoffs)
            if role == .leaving {
                currentUser.successfulShares += 1
                defaults.set(currentUser.successfulShares, forKey: Keys.successfulShares)
            }
        } else {
            currentUser.noShowCount += 1
            defaults.set(currentUser.noShowCount, forKey: Keys.noShowCount)
        }

        subject.send(currentUser)
        return currentUser
    }

    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser {
        currentUser.displayName = sanitizedProfileDisplayName(displayName)
        currentUser.avatarJPEGData = avatarJPEGData
        persistLocally(currentUser)
        subject.send(currentUser)
        return currentUser
    }

    private func persistLocally(_ user: AppUser) {
        defaults.set(user.displayName, forKey: Keys.displayName)
        defaults.set(user.joinedAt, forKey: Keys.joinedAt)
        defaults.set(user.successfulHandoffs, forKey: Keys.successfulHandoffs)
        defaults.set(user.successfulShares, forKey: Keys.successfulShares)
        defaults.set(user.noShowCount, forKey: Keys.noShowCount)
        if let avatarJPEGData = user.avatarJPEGData {
            defaults.set(avatarJPEGData, forKey: Keys.avatarJPEGData)
        } else {
            defaults.removeObject(forKey: Keys.avatarJPEGData)
        }
    }

}

#if canImport(FirebaseAuth) && canImport(FirebaseFirestore)
@MainActor
final class FirebaseUserIdentityStore: UserIdentityProviding {
    private let defaults: UserDefaults
    private let subject: CurrentValueSubject<AppUser, Never>
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var profileListener: ListenerRegistration?
    private(set) var currentUser: AppUser

    private enum Keys {
        static let displayName = "firebaseIdentity.displayName"
        static let joinedAt = "firebaseIdentity.joinedAt"
        static let successfulHandoffs = "firebaseIdentity.successfulHandoffs"
        static let successfulShares = "firebaseIdentity.successfulShares"
        static let noShowCount = "firebaseIdentity.noShowCount"
        static let avatarJPEGData = "firebaseIdentity.avatarJPEGData"
    }

    private let database = Firestore.firestore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let displayName = sanitizedProfileDisplayName(defaults.string(forKey: Keys.displayName) ?? "You")
        defaults.set(displayName, forKey: Keys.displayName)
        let joinedAt = defaults.object(forKey: Keys.joinedAt) as? Date ?? .now
        defaults.set(joinedAt, forKey: Keys.joinedAt)

        let initialUser = AppUser(
            id: Auth.auth().currentUser?.uid ?? "firebase-auth-pending",
            displayName: displayName,
            joinedAt: joinedAt,
            successfulHandoffs: defaults.integer(forKey: Keys.successfulHandoffs),
            successfulShares: defaults.integer(forKey: Keys.successfulShares),
            noShowCount: defaults.integer(forKey: Keys.noShowCount),
            avatarJPEGData: defaults.data(forKey: Keys.avatarJPEGData)
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
        profileListener?.remove()
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    func recordCompletedHandoff(success: Bool, as role: HandoffRole?) -> AppUser {
        if success {
            currentUser.successfulHandoffs += 1
            defaults.set(currentUser.successfulHandoffs, forKey: Keys.successfulHandoffs)
            if role == .leaving {
                currentUser.successfulShares += 1
                defaults.set(currentUser.successfulShares, forKey: Keys.successfulShares)
            }
        } else {
            currentUser.noShowCount += 1
            defaults.set(currentUser.noShowCount, forKey: Keys.noShowCount)
        }

        subject.send(currentUser)
        persistCurrentUserProfile()
        return currentUser
    }

    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser {
        currentUser.displayName = sanitizedProfileDisplayName(displayName)
        currentUser.avatarJPEGData = avatarJPEGData
        subject.send(currentUser)
        persistCurrentUserProfile()
        return currentUser
    }

    private func applyAuthenticatedUserID(_ userID: String) {
        if currentUser.id != userID {
            currentUser = AppUser(
                id: userID,
                displayName: currentUser.displayName,
                joinedAt: currentUser.joinedAt,
                successfulHandoffs: currentUser.successfulHandoffs,
                successfulShares: currentUser.successfulShares,
                noShowCount: currentUser.noShowCount,
                avatarJPEGData: currentUser.avatarJPEGData
            )
            subject.send(currentUser)
        }

        startProfileListener(for: userID)
        persistCurrentUserProfile()
    }

    private func startProfileListener(for userID: String) {
        profileListener?.remove()
        profileListener = userDocument(userID: userID).addSnapshotListener { [weak self] snapshot, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let data = snapshot?.data() else { return }
                self.applyRemoteProfileData(data)
            }
        }
    }

    private func applyRemoteProfileData(_ data: [String: Any]) {
        let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() ?? currentUser.joinedAt
        let successfulHandoffs = data["successfulHandoffs"] as? Int ?? currentUser.successfulHandoffs
        let successfulShares = data["successfulShares"] as? Int ?? currentUser.successfulShares
        let noShowCount = data["noShowCount"] as? Int ?? currentUser.noShowCount
        let avatarJPEGData = (data["avatarBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sanitizedProfileDisplayName(data["displayName"] as? String ?? currentUser.displayName)
            : currentUser.displayName

        let updatedUser = AppUser(
            id: currentUser.id,
            displayName: displayName,
            joinedAt: joinedAt,
            successfulHandoffs: successfulHandoffs,
            successfulShares: successfulShares,
            noShowCount: noShowCount,
            avatarJPEGData: avatarJPEGData
        )

        guard updatedUser != currentUser else { return }
        currentUser = updatedUser
        persistLocally(updatedUser)
        subject.send(updatedUser)
    }

    private func persistCurrentUserProfile() {
        persistLocally(currentUser)
        var payload: [String: Any] = [
            "displayName": currentUser.displayName,
            "joinedAt": Timestamp(date: currentUser.joinedAt),
            "successfulHandoffs": currentUser.successfulHandoffs,
            "successfulShares": currentUser.successfulShares,
            "noShowCount": currentUser.noShowCount,
            "updatedAt": Timestamp(date: .now)
        ]

        if let avatarJPEGData = currentUser.avatarJPEGData {
            payload["avatarBase64"] = avatarJPEGData.base64EncodedString()
        }

        userDocument(userID: currentUser.id).setData(payload)
    }

    private func userDocument(userID: String) -> DocumentReference {
        database.collection("users").document(userID)
    }

    private func persistLocally(_ user: AppUser) {
        defaults.set(user.displayName, forKey: Keys.displayName)
        defaults.set(user.joinedAt, forKey: Keys.joinedAt)
        defaults.set(user.successfulHandoffs, forKey: Keys.successfulHandoffs)
        defaults.set(user.successfulShares, forKey: Keys.successfulShares)
        defaults.set(user.noShowCount, forKey: Keys.noShowCount)
        if let avatarJPEGData = user.avatarJPEGData {
            defaults.set(avatarJPEGData, forKey: Keys.avatarJPEGData)
        } else {
            defaults.removeObject(forKey: Keys.avatarJPEGData)
        }
    }
}
#endif
