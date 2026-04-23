# SpotRelay

SpotRelay is an iOS prototype for real-time parking spot handoffs in dense urban areas. A driver who is about to leave can publish a short countdown, and a nearby driver can claim that spot before circling the block again.

## What It Does

- Shows nearby active parking handoff signals on a map
- Lets a leaving driver post a spot with a 2, 5, or 10 minute timer
- Lets an arriving driver claim a spot and move into a live handoff state
- Tracks simple completion and cancellation states to shape future trust features

## Current Status

This repository is an early product prototype built with SwiftUI and MapKit. It now has a backend-ready architecture:

- `LocalSpotRepository` keeps the app fully runnable with demo realtime data
- `FirebaseSpotRepository` is scaffolded for Auth + Firestore
- the UI still works without Firebase until you add your project configuration

## Tech Stack

- SwiftUI
- MapKit
- Xcode 16+
- iOS 18+

## Project Structure

```text
SpotRelay/
  Core/
  Domain/
  Features/
  Services/
```

## Running Locally

1. Open `SpotRelay.xcodeproj` in Xcode.
2. Select the `SpotRelay` scheme.
3. Run on an iPhone simulator or device with iOS 18 or later.

## Firebase Setup

SpotRelay is ready to switch from the local repository to Firebase once the app is connected to a real Firebase project.

1. In Firebase, create an Apple app that matches this bundle identifier:
   `com.SAAAin.SpotRelay`
2. Download `GoogleService-Info.plist`.
3. Add the file to the `SpotRelay/SpotRelay` app target in Xcode.
4. In Firebase Authentication, enable `Anonymous` sign-in.
5. In Firestore, create a `spots` collection.
6. Open the project in Xcode and let Swift Package Manager resolve:
   - `FirebaseCore`
   - `FirebaseAuth`
   - `FirebaseFirestore`
   - `FirebaseMessaging`
7. In Apple Developer, create an APNs authentication key for the app's team if you do not already have one.
8. In Firebase Console, open `Project settings > Cloud Messaging` and upload that APNs key.
9. In Xcode, make sure the app uses the included `SpotRelay.entitlements` file and that your signing setup supports Push Notifications on the device you are testing with.
10. Publish the repo's Firestore rules before testing multi-user handoffs:
   - paste [firestore.rules](firestore.rules) into the Firestore Rules tab in Firebase Console, or
   - deploy it with the Firebase CLI using `firebase deploy --only firestore:rules`
11. In Firestore TTL, configure the `spots` collection group to use `cleanupAt` as its TTL field.

When `GoogleService-Info.plist` is present and Firebase packages are resolved, the app will automatically prefer the Firebase-backed repository over the local demo repository.

The current rules intentionally allow any authenticated SpotRelay user to read active handoffs, while write access is restricted to the driver participating in that handoff. Geographic filtering still happens in the app for now; if you later add geohash queries, you can tighten the read rules around those indexed fields too.

Each new Firestore spot document now includes a `cleanupAt` timestamp set to 24 hours after the document is created. Once you enable Firestore TTL on that field, Firestore will automatically delete expired spot documents. Firestore TTL deletion is asynchronous, so the actual delete can happen after the `cleanupAt` time rather than exactly on it.

## Push Notifications

SpotRelay now requests notification permission during onboarding, registers with APNs, maps the APNs token into Firebase Cloud Messaging, and writes the current device token state into Firestore under:

`users/{uid}/devices/{installationID}`

Each device document includes the current FCM token, APNs token, notification authorization status, bundle ID, and timestamps so a future notification sender can target the user's active iOS devices.

For local device testing:

1. Install the app on a real iPhone.
2. Accept notification permission.
3. Open Firestore and confirm a device record appears under the current user.
4. Open Firebase Console `Messaging` and send a test notification to that device's FCM token.

The app entitlement currently uses the `development` APNs environment so debug builds on a development-signed device are the expected first test path.

## Firebase Functions

The repository now includes a TypeScript Firebase Functions scaffold in [functions](functions) for server-side SpotRelay notifications.

Current scaffolded behavior:

- watches Firestore updates at `spots/{spotId}`
- sends FCM notifications when a handoff is:
  - claimed
  - marked arriving
  - cancelled
  - completed
- reads active device tokens from `users/{uid}/devices/{installationID}`
- removes invalid FCM tokens when Firebase reports them as expired or unregistered

To use it:

1. Install the Functions dependencies:
   - `cd functions`
   - `npm install`
2. Build the functions:
   - `npm run build`
3. Deploy the functions:
   - `firebase deploy --only functions`

The scaffold uses Cloud Functions for Firebase 2nd gen and Node.js 20. It is intentionally focused on notification delivery first; you can extend it later with:

- deep-link routing payloads
- scheduled reminder notifications
- analytics around delivery/open rates
- retry policies for non-terminal messaging failures

## Roadmap

- Finish Firestore transactions and security rules
- Add push notifications and claim expiry
- Introduce reliability scoring and handoff history
- Polish onboarding and empty/error states

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

This project is available under the [MIT License](LICENSE).
