import CoreLocation
import SwiftUI
import UIKit
import UserNotifications

struct OnboardingFlowView: View {
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var pushNotificationStore: PushNotificationStore
    @EnvironmentObject private var smartParkingStore: SmartParkingStore

    let onFinish: () -> Void

    @State private var page = 0
    @State private var isPerformingPrimaryAction = false

    private let pages: [OnboardingPage] = [
        .init(
            kind: .intro,
            eyebrow: "LIVE CITY PARKING",
            title: "Pass the spot before the circling starts",
            subtitle: "SpotRelay helps two nearby drivers coordinate a parking handoff in seconds, without awkward guessing or last-minute chaos.",
            buttonTitle: "Get Started",
            symbol: "parkingsign.circle.fill",
            tint: SpotRelayTheme.primary,
            accent: SpotRelayTheme.accent,
            highlights: [
                .init(title: "Fast handoffs", detail: "Share a spot the moment you know you're leaving.", symbol: "bolt.fill"),
                .init(title: "Live status", detail: "See claims, countdowns, and arrival state in one place.", symbol: "dot.radiowaves.left.and.right")
            ],
            footnote: "Swipe through the setup any time. Each step only asks for what makes the handoff faster."
        ),
        .init(
            kind: .location,
            eyebrow: "LOCAL FIRST",
            title: "Only show the spots that are actually near you",
            subtitle: "Location keeps the map honest, the distance labels useful, and the claiming flow quick enough to trust while you're moving.",
            buttonTitle: "Enable Location",
            symbol: "location.circle.fill",
            tint: SpotRelayTheme.accent,
            accent: SpotRelayTheme.primary,
            highlights: [
                .init(title: "Nearby by default", detail: "We keep the experience inside a tight city radius instead of showing noise from far away.", symbol: "scope"),
                .init(title: "Current-location map", detail: "Blue-dot map, recentering, and handoff distances feel instant once location is on.", symbol: "location.north.line.fill")
            ],
            footnote: "Location is used to show nearby handoffs and place your own signal accurately."
        ),
        .init(
            kind: .notifications,
            eyebrow: "DON'T MISS THE MOMENT",
            title: "Get nudged when a handoff actually needs you",
            subtitle: "Claims, arrivals, and expiry moments move fast. Notifications keep the flow visible even when the app isn't open.",
            buttonTitle: "Enable Notifications",
            symbol: "bell.badge.circle.fill",
            tint: SpotRelayTheme.warning,
            accent: SpotRelayTheme.primary,
            highlights: [
                .init(title: "Spot claimed", detail: "Know right away when another driver is heading for your space.", symbol: "checkmark.seal.fill"),
                .init(title: "Approach updates", detail: "Stay calm with reminders when the other driver is nearly there or a handoff changes.", symbol: "bell.and.waves.left.and.right.fill")
            ],
            footnote: "You can tune notification preferences later, but this is what makes the handoff feel real-time."
        ),
        .init(
            kind: .smartParking,
            eyebrow: "SMART PARKING",
            title: "Let SpotRelay remember your parked car automatically",
            subtitle: "We combine motion, visits, and car-connection hints so the app can notice likely parking moments and remind you when you're back at the car.",
            buttonTitle: "Enable Smart Parking",
            symbol: "sparkles",
            tint: SpotRelayTheme.success,
            accent: SpotRelayTheme.accent,
            highlights: [
                .init(title: "Parking memory", detail: "No extra tap every time you park. The reminder can arm itself when confidence is high.", symbol: "car.fill"),
                .init(title: "Return prompt", detail: "When you come back near the car, SpotRelay can ask if you're about to leave and want to share the spot.", symbol: "arrow.uturn.backward.circle.fill")
            ],
            footnote: "This uses motion and location signals only to improve the parking reminder experience."
        )
    ]

    private var currentPage: OnboardingPage {
        pages[page]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpotRelayTheme.canvasGradient.ignoresSafeArea()
                onboardingBackdrop.ignoresSafeArea()

                VStack(spacing: 14) {
                    topChrome

                    TabView(selection: $page) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, onboardingPage in
                            OnboardingPageCard(
                                page: onboardingPage,
                                stepStatus: stepStatus(for: onboardingPage.kind)
                            )
                            .tag(index)
                            .padding(.horizontal, 2)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    bottomActionBar
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)
            }
        }
    }

    private var onboardingBackdrop: some View {
        ZStack {
            SpotRelayTheme.mapGlow
                .scaleEffect(1.45)
                .offset(x: -120, y: -200)

            SpotRelayTheme.heroGradient
                .opacity(0.14)
                .blur(radius: 80)
                .mask {
                    Circle()
                        .frame(width: 320, height: 320)
                        .offset(x: 120, y: -220)
                }

            SpotRelayTheme.orbGradient
                .opacity(0.12)
                .blur(radius: 90)
                .mask {
                    RoundedRectangle(cornerRadius: 140, style: .continuous)
                        .frame(width: 260, height: 260)
                        .offset(x: -120, y: 260)
                }
        }
    }

    private var topChrome: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SpotRelay")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Label("Swipe between steps", systemImage: "arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()
                HStack(spacing: 10) {
                    ForEach(pages.indices, id: \.self) { index in
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                page = index
                            }
                        } label: {
                            Capsule()
                                .fill(index == page ? currentPage.tint : SpotRelayTheme.primary.opacity(0.12))
                                .frame(width: index == page ? 36 : 10, height: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Text("\(page + 1) of \(pages.count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(SpotRelayTheme.badgeText)
            }
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                if page != 0 {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            page -= 1
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.bold))
                            .frame(width: 54, height: 54)
                            .background(SpotRelayTheme.badgeFill, in: Circle())
                            .foregroundStyle(SpotRelayTheme.badgeText)
                    }
                    .buttonStyle(.plain)
                    .opacity(page > 0 ? 1 : 0)
                    .allowsHitTesting(page > 0)
                }
                Button {
                    Task {
                        await handlePrimaryAction()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: currentPage.primaryButtonSymbol)
                            .font(.headline.weight(.bold))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(primaryButtonTitle)
                                .font(.headline.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Text(currentPage.buttonCaption)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: page == pages.count - 1 ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                            .font(.title3.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .padding(.horizontal, 20)
                    .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isPerformingPrimaryAction)
                .opacity(isPerformingPrimaryAction ? 0.82 : 1)
            }
            .frame(height: 76)

            Text(currentPage.footnote)
                .font(.caption.weight(.medium))
                .foregroundStyle(SpotRelayTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 148, maxHeight: 160, alignment: .top)
        .glassPanel(
            cornerRadius: 30,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 20,
            shadowY: 12
        )
    }

    private var primaryButtonTitle: String {
        switch currentPage.kind {
        case .intro:
            return currentPage.buttonTitle
        case .location:
            switch spotStore.locationAuthorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return "Continue"
            case .denied, .restricted:
                return "Open Settings"
            case .notDetermined:
                return currentPage.buttonTitle
            @unknown default:
                return currentPage.buttonTitle
            }
        case .notifications:
            switch pushNotificationStore.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return "Continue"
            case .denied:
                return "Open Settings"
            case .notDetermined:
                return currentPage.buttonTitle
            @unknown default:
                return currentPage.buttonTitle
            }
        case .smartParking:
            switch smartParkingStore.status {
            case .monitoring:
                return "Finish Setup"
            case .needsAlwaysLocation, .needsMotionAccess:
                return "Open Settings"
            case .disabled:
                return currentPage.buttonTitle
            case .unsupported:
                return "Finish for Now"
            }
        }
    }

    private func stepStatus(for kind: OnboardingPage.Kind) -> OnboardingStepStatus? {
        switch kind {
        case .intro:
            return .init(title: "Real-time", tone: .neutral)
        case .location:
            switch spotStore.locationAuthorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return .init(title: "Location Ready", tone: .ready)
            case .denied, .restricted:
                return .init(title: "Needs Settings", tone: .warning)
            case .notDetermined:
                return .init(title: "Recommended", tone: .accent)
            @unknown default:
                return .init(title: "Recommended", tone: .accent)
            }
        case .notifications:
            switch pushNotificationStore.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return .init(title: "Notifications On", tone: .ready)
            case .denied:
                return .init(title: "Needs Settings", tone: .warning)
            case .notDetermined:
                return .init(title: "Helpful", tone: .accent)
            @unknown default:
                return .init(title: "Helpful", tone: .accent)
            }
        case .smartParking:
            switch smartParkingStore.status {
            case .monitoring:
                return .init(title: "Smart Parking On", tone: .ready)
            case .needsAlwaysLocation, .needsMotionAccess:
                return .init(title: "Finish Permissions", tone: .warning)
            case .disabled:
                return .init(title: "Optional", tone: .accent)
            case .unsupported:
                return .init(title: "Unavailable", tone: .neutral)
            }
        }
    }

    private func handlePrimaryAction() async {
        guard !isPerformingPrimaryAction else { return }
        isPerformingPrimaryAction = true
        defer { isPerformingPrimaryAction = false }

        let shouldAdvance = await performStepAction(for: currentPage.kind)
        guard shouldAdvance else { return }

        if page == pages.count - 1 {
            onFinish()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                page += 1
            }
        }
    }

    private func performStepAction(for kind: OnboardingPage.Kind) async -> Bool {
        switch kind {
        case .intro:
            return true

        case .location:
            switch spotStore.locationAuthorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                return true
            case .notDetermined:
                spotStore.prepareLocationTracking(requestIfNeeded: true)
                return true
            case .denied, .restricted:
                openSystemSettings()
                return false
            @unknown default:
                return true
            }

        case .notifications:
            switch pushNotificationStore.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .notDetermined:
                _ = await pushNotificationStore.requestAuthorization()
                return true
            case .denied:
                pushNotificationStore.openSystemSettings()
                return false
            @unknown default:
                return true
            }

        case .smartParking:
            switch smartParkingStore.status {
            case .monitoring, .unsupported:
                return true
            case .disabled:
                await smartParkingStore.enable()
                smartParkingStore.refreshPermissions()
                return true
            case .needsAlwaysLocation, .needsMotionAccess:
                openSystemSettings()
                return false
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct OnboardingPageCard: View {
    let page: OnboardingPage
    let stepStatus: OnboardingStepStatus?

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 10) {
                        Label(page.eyebrow, systemImage: page.symbol)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(page.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(page.tint)
                            .lineLimit(1)

                        Spacer(minLength: 10)

                        if let stepStatus {
                            OnboardingStatusBadge(status: stepStatus)
                        }
                    }

                    //OnboardingHeroArtwork(page: page)

                    VStack(alignment: .leading, spacing: 10) {
//                        Text(page.title)
//                            .font(.system(size: 28, weight: .bold, design: .rounded))
//                            .foregroundStyle(SpotRelayTheme.textPrimary)
//                            .fixedSize(horizontal: false, vertical: true)

                        Text(page.subtitle)
                            .font(.body.weight(.medium))
                            .foregroundStyle(SpotRelayTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 10) {
                        ForEach(page.highlights) { highlight in
                            OnboardingHighlightRow(highlight: highlight, tint: page.tint)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .glassPanel(
                cornerRadius: 34,
                tint: SpotRelayTheme.strongGlassTint,
                stroke: SpotRelayTheme.glassStroke,
                shadow: SpotRelayTheme.shadow,
                shadowRadius: 24,
                shadowY: 14
            )
        }
    }
}

private struct OnboardingHeroArtwork: View {
    let page: OnboardingPage

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                page.tint.opacity(0.24),
                                page.accent.opacity(0.16),
                                SpotRelayTheme.chrome.opacity(0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(SpotRelayTheme.softStroke, lineWidth: 1)
                    }

                switch page.kind {
                case .intro:
                    introHero(in: proxy.size)
                case .location:
                    locationHero(in: proxy.size)
                case .notifications:
                    notificationHero(in: proxy.size)
                case .smartParking:
                    smartParkingHero(in: proxy.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .frame(height: 176)
    }

    private func introHero(in size: CGSize) -> some View {
        let cardWidth = min(size.width * 0.66, 226)
        let cardHeight = min(size.height * 0.58, 116)

        return ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SpotRelayTheme.chrome.opacity(0.9))
                .frame(width: cardWidth, height: cardHeight)
                .offset(x: -size.width * 0.08, y: size.height * 0.12)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [page.tint.opacity(0.95), page.accent.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: cardWidth, height: cardHeight)
                .offset(x: size.width * 0.12, y: -size.height * 0.10)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "car.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leaving in 2 min")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                        Text("A driver nearby can claim it live")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }

                HStack(spacing: 12) {
                    smallHeroChip(title: "Claimed", tint: Color.white.opacity(0.18))
                    smallHeroChip(title: "120m away", tint: Color.white.opacity(0.12))
                }
            }
            .padding(18)
            .frame(width: cardWidth, height: cardHeight, alignment: .leading)
            .offset(x: size.width * 0.12, y: -size.height * 0.10)

            VStack(alignment: .leading, spacing: 12) {
                Text("ndoffs")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                HStack(spacing: 12) {
                    Circle()
                        .fill(page.accent.opacity(0.24))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Circle()
                                .fill(page.accent)
                                .frame(width: 12, height: 12)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("4 min away")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(SpotRelayTheme.textPrimary)
                        Text("Available now")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SpotRelayTheme.textSecondary)
                    }

                    Spacer()
                }
            }
            .padding(16)
            .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
            .offset(x: -size.width * 0.08, y: size.height * 0.12)
        }
    }

    private func locationHero(in size: CGSize) -> some View {
        let panelWidth = min(size.width * 0.8, 248)
        let panelHeight = min(size.height * 0.74, 146)

        return ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(SpotRelayTheme.chrome.opacity(0.88))
                .frame(width: panelWidth, height: panelHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(SpotRelayTheme.softStroke, lineWidth: 1)
                }

            mapGrid
                .frame(width: panelWidth - 24, height: panelHeight - 26)

            Circle()
                .stroke(page.tint.opacity(0.32), lineWidth: 16)
                .frame(width: 82, height: 82)

            Circle()
                .stroke(page.tint.opacity(0.24), lineWidth: 10)
                .frame(width: 128, height: 128)

            Circle()
                .fill(page.tint)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 5)
                }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SpotRelayTheme.badgeFill)
                .frame(width: 158, height: 42)
                .overlay {
                    HStack(spacing: 8) {
                        Image(systemName: "scope")
                            .foregroundStyle(page.tint)
                        Text("Nearby only")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(SpotRelayTheme.textPrimary)
                    }
                }
                .offset(y: panelHeight * 0.42)
        }
    }

    private func notificationHero(in size: CGSize) -> some View {
        let shellWidth = min(size.width * 0.84, 252)
        let shellHeight = min(size.height * 0.82, 156)
        let cardWidth = min(size.width * 0.74, 220)

        return ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(SpotRelayTheme.chrome.opacity(0.9))
                .frame(width: shellWidth, height: shellHeight)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.06))
                .frame(width: shellWidth * 0.64, height: 16)
                .offset(y: -shellHeight * 0.38)

            VStack(spacing: 12) {
                notificationCard(
                    title: "Spot claimed",
                    subtitle: "A nearby driver is heading to your space.",
                    accent: page.tint,
                    width: cardWidth
                )

                notificationCard(
                    title: "Driver arriving",
                    subtitle: "They are almost there. Stay ready.",
                    accent: page.accent,
                    width: cardWidth
                )
                .offset(x: min(size.width * 0.06, 16))
            }
        }
    }

    private func smartParkingHero(in size: CGSize) -> some View {
        let shellWidth = min(size.width * 0.86, 256)
        let shellHeight = min(size.height * 0.8, 152)

        return ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(SpotRelayTheme.chrome.opacity(0.9))
                .frame(width: shellWidth, height: shellHeight)

            Path { path in
                path.move(to: CGPoint(x: shellWidth * 0.20, y: shellHeight * 0.78))
                path.addCurve(
                    to: CGPoint(x: shellWidth * 0.80, y: shellHeight * 0.32),
                    control1: CGPoint(x: shellWidth * 0.34, y: shellHeight * 0.10),
                    control2: CGPoint(x: shellWidth * 0.58, y: shellHeight * 0.92)
                )
            }
            .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [8, 10]))
            .foregroundStyle(page.tint.opacity(0.45))

            Circle()
                .fill(page.accent)
                .frame(width: 22, height: 22)
                .offset(x: -shellWidth * 0.30, y: shellHeight * 0.20)

            ZStack {
                Circle()
                    .fill(SpotRelayTheme.heroGradient)
                    .frame(width: 68, height: 68)

                Image(systemName: "car.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .offset(x: -shellWidth * 0.06, y: shellHeight * 0.02)

            VStack(alignment: .leading, spacing: 8) {
                Text("Back at your car?")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)
                Text("Share your spot and help nearby drivers.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }
            .padding(12)
            .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .offset(x: shellWidth * 0.18, y: -shellHeight * 0.26)

            smallHeroChip(title: "High confidence", tint: page.tint.opacity(0.16))
                .offset(x: shellWidth * 0.20, y: shellHeight * 0.32)
        }
    }

    private var mapGrid: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { row in
                Rectangle()
                    .fill(SpotRelayTheme.softStroke.opacity(0.55))
                    .frame(height: 1)
                    .offset(y: CGFloat(row - 1) * 30)
            }

            ForEach(0..<5, id: \.self) { column in
                Rectangle()
                    .fill(SpotRelayTheme.softStroke.opacity(0.55))
                    .frame(width: 1)
                    .offset(x: CGFloat(column - 2) * 42)
            }
        }
    }

    private func notificationCard(title: String, subtitle: String, accent: Color, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent.opacity(0.18))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "bell.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(accent)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func smallHeroChip(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct OnboardingHighlightRow: View {
    let highlight: OnboardingHighlight
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: highlight.symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(highlight.detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SpotRelayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct OnboardingStatusBadge: View {
    let status: OnboardingStepStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(status.fill, in: Capsule())
            .foregroundStyle(status.foreground)
    }
}

private struct OnboardingStepStatus {
    enum Tone {
        case accent
        case ready
        case warning
        case neutral
    }

    let title: String
    let tone: Tone

    var fill: Color {
        switch tone {
        case .accent:
            return SpotRelayTheme.primary.opacity(0.14)
        case .ready:
            return SpotRelayTheme.success.opacity(0.14)
        case .warning:
            return SpotRelayTheme.warning.opacity(0.16)
        case .neutral:
            return SpotRelayTheme.badgeFill
        }
    }

    var foreground: Color {
        switch tone {
        case .accent:
            return SpotRelayTheme.primary
        case .ready:
            return SpotRelayTheme.success
        case .warning:
            return SpotRelayTheme.warning
        case .neutral:
            return SpotRelayTheme.badgeText
        }
    }
}

private struct OnboardingPage {
    enum Kind {
        case intro
        case location
        case notifications
        case smartParking
    }

    let kind: Kind
    let eyebrow: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let symbol: String
    let tint: Color
    let accent: Color
    let highlights: [OnboardingHighlight]
    let footnote: String

    var primaryButtonSymbol: String {
        switch kind {
        case .intro:
            return "arrow.right.circle.fill"
        case .location:
            return "location.fill"
        case .notifications:
            return "bell.badge.fill"
        case .smartParking:
            return "sparkles"
        }
    }

    var buttonCaption: String {
        switch kind {
        case .intro:
            return "Take a quick tour of the core setup."
        case .location:
            return "Maps, distances, and nearby handoffs depend on this."
        case .notifications:
            return "Keep claims, arrivals, and timing changes visible."
        case .smartParking:
            return "Optional, but it makes sharing much easier later."
        }
    }
}

private struct OnboardingHighlight: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
}


#Preview {
    OnboardingFlowView {
         
    }
}
