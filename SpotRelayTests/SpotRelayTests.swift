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
    func testVehicleDisconnectPrefersStoppedLocationOverLaterWalkAwayFix() {
        var engine = ParkingCaptureEngine()
        let start = Date(timeIntervalSince1970: 2_000)

        engine.vehicleConnected(summary: "car Bluetooth", at: start)

        let samples = [
            makeLocation(
                latitude: 37.0000,
                longitude: -122.0000,
                speed: 12,
                accuracy: 10,
                timestamp: start
            ),
            makeLocation(
                latitude: 37.0012,
                longitude: -122.0000,
                speed: 10,
                accuracy: 9,
                timestamp: start.addingTimeInterval(45)
            ),
            makeLocation(
                latitude: 37.0024,
                longitude: -122.0000,
                speed: 8,
                accuracy: 8,
                timestamp: start.addingTimeInterval(90)
            ),
            makeLocation(
                latitude: 37.0028,
                longitude: -122.0000,
                speed: 0.3,
                accuracy: 7,
                timestamp: start.addingTimeInterval(120)
            ),
            makeLocation(
                latitude: 37.0028,
                longitude: -122.0000,
                speed: 0.1,
                accuracy: 6,
                timestamp: start.addingTimeInterval(132)
            ),
            makeLocation(
                latitude: 37.0034,
                longitude: -122.0000,
                speed: 1.2,
                accuracy: 6,
                timestamp: start.addingTimeInterval(155)
            )
        ]

        XCTAssertNil(engine.ingest(locations: samples))

        let event = engine.vehicleDisconnected(
            summary: "car Bluetooth",
            at: start.addingTimeInterval(160)
        )

        XCTAssertNotNil(event)
        XCTAssertEqual(event?.source, .vehicleDisconnect)
        XCTAssertEqual(event?.location.coordinate.latitude, 37.0028, accuracy: 0.00005)
    }

    func testLocationDwellDoesNotSaveWhileVehicleConnectionIsStillActive() {
        var engine = ParkingCaptureEngine()
        let start = Date(timeIntervalSince1970: 1_000)

        engine.vehicleConnected(summary: "car Bluetooth", at: start)

        let drivingSamples = [
            makeLocation(
                latitude: 37.0000,
                longitude: -122.0000,
                speed: 11,
                accuracy: 12,
                timestamp: start
            ),
            makeLocation(
                latitude: 37.0009,
                longitude: -122.0000,
                speed: 10,
                accuracy: 10,
                timestamp: start.addingTimeInterval(35)
            ),
            makeLocation(
                latitude: 37.0018,
                longitude: -122.0000,
                speed: 9,
                accuracy: 9,
                timestamp: start.addingTimeInterval(70)
            )
        ]

        XCTAssertNil(engine.ingest(locations: drivingSamples))

        let gateStopSamples = [
            makeLocation(
                latitude: 37.0022,
                longitude: -122.0000,
                speed: 0.4,
                accuracy: 8,
                timestamp: start.addingTimeInterval(90)
            ),
            makeLocation(
                latitude: 37.0022,
                longitude: -122.0000,
                speed: 0.2,
                accuracy: 7,
                timestamp: start.addingTimeInterval(190)
            )
        ]

        XCTAssertNil(engine.ingest(locations: gateStopSamples))
        XCTAssertEqual(engine.snapshot.phase, .parkedCandidate)

        let disconnectEvent = engine.vehicleDisconnected(
            summary: "car Bluetooth",
            at: start.addingTimeInterval(220)
        )

        XCTAssertNotNil(disconnectEvent)
        XCTAssertEqual(disconnectEvent?.source, .vehicleDisconnect)
    }

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

    @MainActor
    func testSuccessfulShareEarnsStarOnlyForLeavingDriver() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let identityStore = LocalUserIdentityStore(defaults: defaults)

        let arrivingResult = identityStore.recordCompletedHandoff(success: true, as: .arriving)
        XCTAssertEqual(arrivingResult.successfulHandoffs, 1)
        XCTAssertEqual(arrivingResult.successfulShares, 0)
        XCTAssertEqual(arrivingResult.shareStars, 0)

        let leavingResult = identityStore.recordCompletedHandoff(success: true, as: .leaving)
        XCTAssertEqual(leavingResult.successfulHandoffs, 2)
        XCTAssertEqual(leavingResult.successfulShares, 1)
        XCTAssertEqual(leavingResult.shareStars, 1)

        let failedLeavingResult = identityStore.recordCompletedHandoff(success: false, as: .leaving)
        XCTAssertEqual(failedLeavingResult.successfulHandoffs, 2)
        XCTAssertEqual(failedLeavingResult.successfulShares, 1)
        XCTAssertEqual(failedLeavingResult.noShowCount, 1)
    }

    private func makeLocation(
        latitude: Double,
        longitude: Double,
        speed: CLLocationSpeed,
        accuracy: CLLocationAccuracy,
        timestamp: Date
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: speed,
            timestamp: timestamp
        )
    }
}
