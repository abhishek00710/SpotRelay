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
   - `FirebaseFirestoreSwift`
7. Publish the repo's Firestore rules before testing multi-user handoffs:
   - paste [firestore.rules](firestore.rules) into the Firestore Rules tab in Firebase Console, or
   - deploy it with the Firebase CLI using `firebase deploy --only firestore:rules`

When `GoogleService-Info.plist` is present and Firebase packages are resolved, the app will automatically prefer the Firebase-backed repository over the local demo repository.

The current rules intentionally allow any authenticated SpotRelay user to read active handoffs, while write access is restricted to the driver participating in that handoff. Geographic filtering still happens in the app for now; if you later add geohash queries, you can tighten the read rules around those indexed fields too.

## Roadmap

- Finish Firestore transactions and security rules
- Add push notifications and claim expiry
- Introduce reliability scoring and handoff history
- Polish onboarding and empty/error states

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

This project is available under the [MIT License](LICENSE).
