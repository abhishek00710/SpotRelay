import Foundation
import MapKit

struct AppUser: Identifiable, Codable, Equatable {
    let id: String
    var displayName: String
    var joinedAt: Date
    var successfulHandoffs: Int
    var successfulShares: Int
    var noShowCount: Int
    var avatarJPEGData: Data?
}

extension AppUser {
    var localizedDisplayName: String {
        switch displayName {
        case "You", "Nearby driver":
            return L10n.tr(displayName)
        default:
            return displayName
        }
    }

    var totalResolvedHandoffs: Int {
        successfulHandoffs + noShowCount
    }

    var shareStars: Int {
        successfulShares
    }

    var reliabilityScore: Int {
        guard totalResolvedHandoffs > 0 else { return 100 }
        let score = Double(successfulHandoffs) / Double(totalResolvedHandoffs)
        return Int((score * 100).rounded())
    }

    var trustTierTitle: String {
        if shareStars >= 25 || reliabilityScore >= 98 {
            return L10n.tr("Top trusted sharer")
        }
        if shareStars >= 10 || reliabilityScore >= 94 {
            return L10n.tr("Trusted sharer")
        }
        if shareStars >= 3 || reliabilityScore >= 88 {
            return L10n.tr("Reliable sharer")
        }
        return L10n.tr("New sharer")
    }

    var displayInitials: String {
        let words = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)

        if words.isEmpty {
            return "SR"
        }

        let initials = words
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()

        return initials.isEmpty ? "SR" : initials
    }
}

struct ParkingSpotSignal: Identifiable, Codable, Equatable {
    let id: String
    let createdBy: String
    var claimedBy: String?
    let latitude: Double
    let longitude: Double
    let createdAt: Date
    let leavingAt: Date
    var status: SpotStatus

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum SpotStatus: String, Codable, CaseIterable {
    case posted
    case claimed
    case arriving
    case completed
    case expired
    case cancelled
}

extension ParkingSpotSignal {
    private var effectiveStatus: SpotStatus {
        switch status {
        case .posted, .claimed, .arriving:
            return leavingAt <= .now ? .expired : status
        case .completed, .expired, .cancelled:
            return status
        }
    }

    func distanceMeters(from coordinate: CLLocationCoordinate2D) -> Int {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let destination = CLLocation(latitude: latitude, longitude: longitude)
        return Int(origin.distance(from: destination).rounded())
    }

    func distanceMeters(from coordinate: CLLocationCoordinate2D?) -> Int? {
        guard let coordinate else { return nil }
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let destination = CLLocation(latitude: latitude, longitude: longitude)
        return Int(origin.distance(from: destination).rounded())
    }

    func distanceText(from coordinate: CLLocationCoordinate2D?) -> String {
        guard let meters = distanceMeters(from: coordinate) else { return L10n.tr("Locating you") }
        return L10n.format("%d m away", meters)
    }

    func distanceValue(from coordinate: CLLocationCoordinate2D?) -> String {
        guard let meters = distanceMeters(from: coordinate) else { return "--" }
        return L10n.format("%d m", meters)
    }

    func statusLabel(for currentUserID: String) -> String {
        switch effectiveStatus {
        case .posted:
            return L10n.tr("Available")
        case .claimed:
            return claimedBy == currentUserID ? L10n.tr("Claimed by you") : L10n.tr("Claimed")
        case .arriving:
            return claimedBy == currentUserID ? L10n.tr("You're arriving") : L10n.tr("Driver arriving")
        case .completed:
            return L10n.tr("Completed")
        case .expired:
            return L10n.tr("Expired")
        case .cancelled:
            return L10n.tr("Cancelled")
        }
    }

    var isActive: Bool {
        switch effectiveStatus {
        case .posted, .claimed, .arriving:
            return true
        case .completed, .expired, .cancelled:
            return false
        }
    }
}
