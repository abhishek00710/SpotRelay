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
    var isAppleAccountLinked: Bool { get }
    var currentUserPublisher: AnyPublisher<AppUser, Never> { get }
    var userProfilesPublisher: AnyPublisher<[String: AppUser], Never> { get }
    func profile(for userID: String) -> AppUser?
    func observeProfile(for userID: String?)
    func recordCompletedHandoff(success: Bool, as role: HandoffRole?) -> AppUser
    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser
    func linkAppleAccount(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws -> AppUser
}

enum UserIdentityError: LocalizedError {
    case firebaseRequired

    var errorDescription: String? {
        switch self {
        case .firebaseRequired:
            return L10n.tr("Apple account saving needs the Firebase build. Please try again from the live app.")
        }
    }
}

@MainActor
final class LocalUserIdentityStore: UserIdentityProviding {
    private let defaults: UserDefaults
    private let subject: CurrentValueSubject<AppUser, Never>
    private let profilesSubject: CurrentValueSubject<[String: AppUser], Never>
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
        profilesSubject = CurrentValueSubject([currentUser.id: currentUser])
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    var userProfilesPublisher: AnyPublisher<[String: AppUser], Never> {
        profilesSubject.eraseToAnyPublisher()
    }

    var isAppleAccountLinked: Bool {
        false
    }

    func profile(for userID: String) -> AppUser? {
        userID == currentUser.id ? currentUser : nil
    }

    func observeProfile(for userID: String?) {
        guard userID == currentUser.id else { return }
        profilesSubject.send([currentUser.id: currentUser])
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
        profilesSubject.send([currentUser.id: currentUser])
        return currentUser
    }

    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser {
        currentUser.displayName = sanitizedProfileDisplayName(displayName)
        currentUser.avatarJPEGData = avatarJPEGData
        persistLocally(currentUser)
        subject.send(currentUser)
        profilesSubject.send([currentUser.id: currentUser])
        return currentUser
    }

    func linkAppleAccount(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws -> AppUser {
        throw UserIdentityError.firebaseRequired
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
    private let profilesSubject: CurrentValueSubject<[String: AppUser], Never>
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var profileListener: ListenerRegistration?
    private var profileListeners: [String: ListenerRegistration] = [:]
    private var knownProfiles: [String: AppUser] = [:]
    private var shouldSkipNextAuthProfilePersistence = false
    private var shouldSeedRemoteProfileFromLocalCache: Bool
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
        let hasCachedProfile = Self.hasCachedProfile(in: defaults)
        self.shouldSeedRemoteProfileFromLocalCache = hasCachedProfile

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
        self.knownProfiles = [initialUser.id: initialUser]
        self.profilesSubject = CurrentValueSubject(knownProfiles)

        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self, let user else { return }
            Task { @MainActor in
                let shouldPersistProfile = self.shouldSeedRemoteProfileFromLocalCache && !self.shouldSkipNextAuthProfilePersistence
                self.shouldSeedRemoteProfileFromLocalCache = true
                self.shouldSkipNextAuthProfilePersistence = false
                self.applyAuthenticatedUserID(user.uid, shouldPersistProfile: shouldPersistProfile)
            }
        }

        if Auth.auth().currentUser == nil {
            Auth.auth().signInAnonymously { _, _ in }
        }
    }

    deinit {
        if let authStateListener {
            Auth.auth().removeStateDidChangeListener(authStateListener)
        }
        profileListener?.remove()
        profileListeners.values.forEach { $0.remove() }
    }

    var currentUserPublisher: AnyPublisher<AppUser, Never> {
        subject.eraseToAnyPublisher()
    }

    var userProfilesPublisher: AnyPublisher<[String: AppUser], Never> {
        profilesSubject.eraseToAnyPublisher()
    }

    var isAppleAccountLinked: Bool {
        Auth.auth().currentUser?.providerData.contains { provider in
            provider.providerID == AuthProviderID.apple.rawValue
        } == true
    }

    func profile(for userID: String) -> AppUser? {
        knownProfiles[userID]
    }

    func observeProfile(for userID: String?) {
        guard let userID, !userID.isEmpty else { return }
        if userID == currentUser.id {
            updateKnownProfile(currentUser)
            return
        }
        guard profileListeners[userID] == nil else { return }

        let listener = userDocument(userID: userID).addSnapshotListener { [weak self] snapshot, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let data = snapshot?.data() else { return }
                self.applyRemoteProfileData(data, userID: userID)
            }
        }

        profileListeners[userID] = listener
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
        updateKnownProfile(currentUser)
        persistCurrentUserProfile()
        return currentUser
    }

    func updateProfile(displayName: String, avatarJPEGData: Data?) -> AppUser {
        currentUser.displayName = sanitizedProfileDisplayName(displayName)
        currentUser.avatarJPEGData = avatarJPEGData
        subject.send(currentUser)
        updateKnownProfile(currentUser)
        persistCurrentUserProfile()
        return currentUser
    }

    func linkAppleAccount(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws -> AppUser {
        let credential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: fullName
        )

        if isAppleAccountLinked {
            return currentUser
        }

        guard let firebaseUser = Auth.auth().currentUser else {
            return try await signInWithExistingAppleCredential(credential)
        }

        do {
            _ = try await link(firebaseUser, with: credential)
            applyAppleProfileNameIfNeeded(fullName)
            applyAuthenticatedUserID(firebaseUser.uid, shouldPersistProfile: true)
            return currentUser
        } catch {
            let authErrorCode = (error as NSError).code
            if authErrorCode == AuthErrorCode.providerAlreadyLinked.rawValue {
                return currentUser
            }

            if authErrorCode == AuthErrorCode.credentialAlreadyInUse.rawValue {
                return try await signInWithExistingAppleCredential(credential)
            }

            throw error
        }
    }

    private func applyAuthenticatedUserID(_ userID: String, shouldPersistProfile: Bool = true) {
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
            updateKnownProfile(currentUser)
        }

        startProfileListener(for: userID)
        if shouldPersistProfile {
            persistCurrentUserProfile()
        }
    }

    private func startProfileListener(for userID: String) {
        profileListener?.remove()
        profileListener = userDocument(userID: userID).addSnapshotListener { [weak self] snapshot, _ in
            guard let self else { return }
            Task { @MainActor in
                guard let data = snapshot?.data() else { return }
                self.applyCurrentUserRemoteProfileData(data)
            }
        }
    }

    private func applyCurrentUserRemoteProfileData(_ data: [String: Any]) {
        let updatedUser = userProfile(from: data, userID: currentUser.id, fallback: currentUser)

        guard updatedUser != currentUser else { return }
        currentUser = updatedUser
        persistLocally(updatedUser)
        subject.send(updatedUser)
        updateKnownProfile(updatedUser)
    }

    private func signInWithExistingAppleCredential(_ credential: OAuthCredential) async throws -> AppUser {
        shouldSkipNextAuthProfilePersistence = true
        let result = try await signIn(with: credential)
        applyAuthenticatedUserID(result.user.uid, shouldPersistProfile: false)

        if let remoteProfileData = try await fetchProfileData(userID: result.user.uid) {
            applyCurrentUserRemoteProfileData(remoteProfileData)
        } else {
            persistCurrentUserProfile()
        }

        return currentUser
    }

    private func applyAppleProfileNameIfNeeded(_ fullName: PersonNameComponents?) {
        guard currentUser.displayName == "You", let fullName else {
            return
        }

        let formattedName = PersonNameComponentsFormatter
            .localizedString(from: fullName, style: .medium, options: [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formattedName.isEmpty else { return }

        currentUser.displayName = sanitizedProfileDisplayName(formattedName)
        subject.send(currentUser)
        updateKnownProfile(currentUser)
    }

    private func applyRemoteProfileData(_ data: [String: Any], userID: String) {
        let fallback = knownProfiles[userID]
        let updatedUser = userProfile(from: data, userID: userID, fallback: fallback)
        updateKnownProfile(updatedUser)
    }

    private func userProfile(from data: [String: Any], userID: String, fallback: AppUser?) -> AppUser {
        let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() ?? fallback?.joinedAt ?? .now
        let successfulHandoffs = data["successfulHandoffs"] as? Int ?? fallback?.successfulHandoffs ?? 0
        let successfulShares = data["successfulShares"] as? Int ?? fallback?.successfulShares ?? 0
        let noShowCount = data["noShowCount"] as? Int ?? fallback?.noShowCount ?? 0
        let avatarJPEGData = (data["avatarBase64"] as? String).flatMap { Data(base64Encoded: $0) }
        let remoteDisplayName = data["displayName"] as? String
        let displayName = remoteDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sanitizedProfileDisplayName(remoteDisplayName ?? fallback?.displayName ?? "Nearby driver")
            : fallback?.displayName ?? "Nearby driver"

        return AppUser(
            id: userID,
            displayName: displayName,
            joinedAt: joinedAt,
            successfulHandoffs: successfulHandoffs,
            successfulShares: successfulShares,
            noShowCount: noShowCount,
            avatarJPEGData: avatarJPEGData
        )
    }

    private func updateKnownProfile(_ user: AppUser) {
        knownProfiles[user.id] = user
        profilesSubject.send(knownProfiles)
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
        } else {
            payload["avatarBase64"] = FieldValue.delete()
        }

        userDocument(userID: currentUser.id).setData(payload, merge: true)
    }

    private func link(_ user: FirebaseAuth.User, with credential: AuthCredential) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            user.link(with: credential) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: UserIdentityError.firebaseRequired)
                    return
                }

                continuation.resume(returning: authResult)
            }
        }
    }

    private func signIn(with credential: AuthCredential) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: UserIdentityError.firebaseRequired)
                    return
                }

                continuation.resume(returning: authResult)
            }
        }
    }

    private func fetchProfileData(userID: String) async throws -> [String: Any]? {
        let snapshot = try await userDocument(userID: userID).getDocument()
        return snapshot.data()
    }

    private func userDocument(userID: String) -> DocumentReference {
        database.collection("users").document(userID)
    }

    private static func hasCachedProfile(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.displayName) != nil ||
            defaults.object(forKey: Keys.joinedAt) != nil ||
            defaults.object(forKey: Keys.successfulHandoffs) != nil ||
            defaults.object(forKey: Keys.successfulShares) != nil ||
            defaults.object(forKey: Keys.noShowCount) != nil ||
            defaults.object(forKey: Keys.avatarJPEGData) != nil
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
