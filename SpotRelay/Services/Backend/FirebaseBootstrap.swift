import Foundation

enum FirebaseBootstrapStatus {
    case configured(projectID: String?)
    case missingConfigFile
    case invalidConfigFile
    case unavailable
}

#if canImport(FirebaseCore)
import FirebaseCore

enum FirebaseBootstrap {
    static func configureIfPossible() -> FirebaseBootstrapStatus {
        if let app = FirebaseApp.app() {
            return .configured(projectID: app.options.projectID)
        }

        guard let configPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
            return .missingConfigFile
        }
        guard let options = FirebaseOptions(contentsOfFile: configPath) else {
            return .invalidConfigFile
        }

        FirebaseApp.configure(options: options)
        return .configured(projectID: options.projectID)
    }
}
#else
enum FirebaseBootstrap {
    static func configureIfPossible() -> FirebaseBootstrapStatus {
        .unavailable
    }
}
#endif
