# SpotRelay

SpotRelay is an iOS prototype for real-time parking spot handoffs in dense urban areas. A driver who is about to leave can publish a short countdown, and a nearby driver can claim that spot before circling the block again.

## What It Does

- Shows nearby active parking handoff signals on a map
- Lets a leaving driver post a spot with a 2, 5, or 10 minute timer
- Lets an arriving driver claim a spot and move into a live handoff state
- Tracks simple completion and cancellation states to shape future trust features

## Current Status

This repository is an early product prototype built with SwiftUI and MapKit. It currently uses local in-memory demo data so the core UX can be refined before backend and notification infrastructure are added.

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

## Roadmap

- Replace demo data with Firebase or Supabase
- Add real location permissions and nearby filtering
- Add push notifications and claim expiry
- Introduce reliability scoring and handoff history
- Polish onboarding and empty/error states

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

This project is available under the [MIT License](LICENSE).
