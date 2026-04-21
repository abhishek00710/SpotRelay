import Foundation

enum SpotRelayBackendMode {
    case firebase(projectID: String?)
    case localFallback(reason: String)

    var shortLabel: String {
        switch self {
        case .firebase:
            return "Firebase Live"
        case .localFallback:
            return "Local Demo"
        }
    }

    var detail: String {
        switch self {
        case .firebase(let projectID):
            if let projectID, !projectID.isEmpty {
                return "Connected to \(projectID)"
            }
            return "Connected to Firebase"
        case .localFallback(let reason):
            return reason
        }
    }

    var isFirebase: Bool {
        if case .firebase = self {
            return true
        }
        return false
    }
}

struct SpotRelayBackendSelection {
    let repository: SpotRepository
    let mode: SpotRelayBackendMode
}

@MainActor
enum SpotRelayBackendFactory {
    static func makeUserIdentityStore(for mode: SpotRelayBackendMode) -> UserIdentityProviding {
        switch mode {
        case .firebase:
            #if canImport(FirebaseAuth)
            return FirebaseUserIdentityStore()
            #else
            return LocalUserIdentityStore()
            #endif
        case .localFallback:
            return LocalUserIdentityStore()
        }
    }

    static func makeBackend() -> SpotRelayBackendSelection {
        switch FirebaseBootstrap.configureIfPossible() {
        case .configured(let projectID):
            return SpotRelayBackendSelection(
                repository: FirebaseSpotRepository(),
                mode: .firebase(projectID: projectID)
            )
        case .missingConfigFile:
            return SpotRelayBackendSelection(
                repository: LocalSpotRepository(),
                mode: .localFallback(reason: "GoogleService-Info.plist is not inside the app bundle")
            )
        case .invalidConfigFile:
            return SpotRelayBackendSelection(
                repository: LocalSpotRepository(),
                mode: .localFallback(reason: "Firebase config file could not be loaded")
            )
        case .unavailable:
            return SpotRelayBackendSelection(
                repository: LocalSpotRepository(),
                mode: .localFallback(reason: "Firebase SDK is unavailable in this build")
            )
        }
    }
}
