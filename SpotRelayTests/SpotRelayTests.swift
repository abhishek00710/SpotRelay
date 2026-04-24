//
//  SpotRelayTests.swift
//  SpotRelayTests
//
//  Created by Abhishek Gang Deb on 4/19/26.
//

import XCTest
import CoreLocation
@testable import SpotRelay

final class SpotRelayTests: XCTestCase {
    @MainActor
    func testClaimantCancellationReopensSpotWhileTimerRuns() async throws {
        let repository = LocalSpotRepository()
        let coordinate = CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.0090)
        let posted = try await repository.postSpot(
            createdBy: "owner",
            coordinate: coordinate,
            durationMinutes: 5,
            now: .now
        )

        _ = try await repository.claimSpot(
            id: posted.id,
            userID: "claimer",
            userCoordinate: coordinate,
            nearbySearchRadiusMeters: 500,
            now: .now
        )

        let reopened = try await repository.cancelHandoff(id: posted.id, userID: "claimer")

        XCTAssertEqual(reopened.status, .posted)
        XCTAssertNil(reopened.claimedBy)
        XCTAssertTrue(reopened.isActive)
    }

    @MainActor
    func testOwnerCancellationStillCancelsHandoff() async throws {
        let repository = LocalSpotRepository()
        let coordinate = CLLocationCoordinate2D(latitude: 37.3346, longitude: -122.0090)
        let posted = try await repository.postSpot(
            createdBy: "owner",
            coordinate: coordinate,
            durationMinutes: 5,
            now: .now
        )

        let cancelled = try await repository.cancelHandoff(id: posted.id, userID: "owner")

        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertTrue(cancelled.createdBy == "owner")
    }
}
