import AuthenticationServices
import CryptoKit
import PhotosUI
import SwiftUI
import UIKit

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    @EnvironmentObject private var homeExclusionStore: HomeExclusionStore
    @State private var draftDisplayName = ""
    @State private var draftAvatarJPEGData: Data?
    @State private var draftAvatarPreviewImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var hasLoadedDrafts = false
    @State private var avatarProcessingError: String?
    @State private var isShowingNameEditor = false
    @State private var nameEditorText = ""
    @State private var baselineDisplayName = "You"
    @State private var baselineAvatarSignature = 0
    @State private var draftAvatarSignature = 0
    @State private var currentAppleSignInNonce: String?
    @State private var isLinkingAppleAccount = false
    @State private var appleSignInErrorMessage: String?
    @State private var isShowingHomeAddressSheet = false
    @State private var isShowingDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var accountDeletionErrorMessage: String?
    @State private var accountDeletionSuccessMessage: String?
    @FocusState private var isNameEditorFieldFocused: Bool

    private var user: AppUser {
        spotStore.currentUser
    }

    private var memberSinceText: String {
        user.joinedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var reliabilityTint: Color {
        switch user.reliabilityScore {
        case 97...:
            return SpotRelayTheme.success
        case 90...:
            return SpotRelayTheme.primary
        default:
            return SpotRelayTheme.warning
        }
    }

    private var userIDLabel: String {
        let suffix = user.id.suffix(4).uppercased()
        return L10n.format("Driver ID • %@", String(suffix))
    }

    private var appShareMessage: String {
        L10n.tr("I'm using SpotRelay for real-time parking handoffs. Pass the spot. Skip the stress.")
    }

    private var profileDisplayName: String {
        let trimmedDraftName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmedDraftName.isEmpty ? user.displayName : trimmedDraftName
        return rawName == "You" ? L10n.tr("You") : rawName
    }

    private var draftDisplayInitials: String {
        let words = draftDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)

        if words.isEmpty {
            return user.displayInitials
        }

        let initials = words
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()

        return initials.isEmpty ? user.displayInitials : initials
    }

    private var isProfileDirty: Bool {
        let sanitizedDraftName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDraftName = sanitizedDraftName.isEmpty ? "You" : sanitizedDraftName
        return effectiveDraftName != baselineDisplayName || draftAvatarSignature != baselineAvatarSignature
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    accountRecoveryCard
                    homeProtectionCard
                    accountDeletionCard
                    ProfileInsightsSection(user: user)
                    #if DEBUG
                    debugDemoDataCard
                    #endif
                }
                .padding(20)
            }
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                syncDraftsIfNeeded()
            }
            .onChange(of: user) { _, _ in
                if !isProfileDirty {
                    syncDraftsIfNeeded(force: true)
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await loadAvatar(from: newItem)
                }
            }
            .sheet(isPresented: $isShowingNameEditor) {
                nameEditorSheet
            }
            .sheet(isPresented: $isShowingHomeAddressSheet) {
                HomeAddressSheet(homeExclusionStore: homeExclusionStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .alert("Delete SpotRelay account?", isPresented: $isShowingDeleteAccountConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Account", role: .destructive) {
                    Task {
                        await performAccountDeletion()
                    }
                }
            } message: {
                Text("This permanently removes your SpotRelay profile, saved parked car, owned shared spots, and this device's notification record. This cannot be undone.")
            }
            .alert("Account deleted", isPresented: Binding(
                get: { accountDeletionSuccessMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        accountDeletionSuccessMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountDeletionSuccessMessage ?? "")
            }
            .alert("Couldn't delete account", isPresented: Binding(
                get: { accountDeletionErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        accountDeletionErrorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accountDeletionErrorMessage ?? "")
            }
        }
        .spotRelayErrorBanner(using: spotStore)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("SpotRelay trust")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .foregroundStyle(SpotRelayTheme.badgeText)

                        Spacer(minLength: 0)

                        if isProfileDirty {
                            Text("Unsaved")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(SpotRelayTheme.badgeFill, in: Capsule())
                                .foregroundStyle(SpotRelayTheme.badgeText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 10) {
                            Text(profileDisplayName)
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(SpotRelayTheme.textPrimary)
                                .lineLimit(2)

                            Button {
                                beginEditingName()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(SpotRelayTheme.primary, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        Text(userIDLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(SpotRelayTheme.textSecondary)

                        Text(user.trustTierTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(SpotRelayTheme.textPrimary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 10) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let draftAvatarPreviewImage {
                                    Image(uiImage: draftAvatarPreviewImage)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Circle()
                                        .fill(SpotRelayTheme.heroGradient)

                                    Text(draftDisplayInitials)
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(SpotRelayTheme.softStroke, lineWidth: 1.5)
                            )

                            Image(systemName: "photo.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(SpotRelayTheme.primary, in: Circle())
                                .offset(x: 2, y: 2)

                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.caption2.weight(.bold))
                                Text("\(user.shareStars)")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(SpotRelayTheme.warning, in: Capsule())
                            .offset(x: 8, y: 6)
                        }
                    }
                    .buttonStyle(.plain)

                    if draftAvatarJPEGData != nil {
                        Button("Remove") {
                            draftAvatarJPEGData = nil
                            draftAvatarPreviewImage = nil
                            draftAvatarSignature = 0
                            selectedPhotoItem = nil
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.warning)
                    }
                }
            }

            shareSpotRelayRow

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    saveProfile()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Save Profile")
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!isProfileDirty)
                .opacity(isProfileDirty ? 1 : 0.6)

                Text("Tap your photo to update it, or use the pencil to edit your name.")
                    .font(.caption)
                    .foregroundStyle(SpotRelayTheme.textSecondary)

                if let avatarProcessingError {
                    Text(avatarProcessingError)
                        .font(.caption)
                        .foregroundStyle(SpotRelayTheme.warning)
                }
            }
        }
        .padding(24)
        .glassPanel(
            cornerRadius: 32,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.glassStroke,
            shadow: SpotRelayTheme.shadow,
            shadowRadius: 24,
            shadowY: 12
        )
    }

    private var shareSpotRelayRow: some View {
        ShareLink(item: appShareMessage) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(SpotRelayTheme.heroGradient, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Share SpotRelay")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Invite another driver to pass the spot and skip the stress.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.primary)
                    .frame(width: 32, height: 32)
                    .background(SpotRelayTheme.badgeFill, in: Circle())
            }
            .padding(14)
            .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(SpotRelayTheme.softStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var homeProtectionCard: some View {
        Button {
            isShowingHomeAddressSheet = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(homeExclusionStore.hasHomeAddress ? SpotRelayTheme.success : SpotRelayTheme.textPrimary)

                    if !homeExclusionStore.hasHomeAddress {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SpotRelayTheme.accent)
                            .background(SpotRelayTheme.strongGlassTint, in: Circle())
                            .offset(x: 6, y: 5)
                    }
                }
                .frame(width: 44, height: 44)
                .background(
                    (homeExclusionStore.hasHomeAddress ? SpotRelayTheme.success : SpotRelayTheme.primary).opacity(0.15),
                    in: Circle()
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Home protection")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(homeExclusionStore.home?.address ?? "Add your home so SpotRelay hides parked cars and shared spots within 25m.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Text(homeExclusionStore.hasHomeAddress ? "Manage" : "Add")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
                    .foregroundStyle(homeExclusionStore.hasHomeAddress ? SpotRelayTheme.success : SpotRelayTheme.badgeText)
            }
            .padding(18)
            .glassPanel(
                cornerRadius: 26,
                tint: SpotRelayTheme.glassTint,
                stroke: SpotRelayTheme.softStroke,
                shadow: SpotRelayTheme.rowShadow,
                shadowRadius: 14,
                shadowY: 8
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(homeExclusionStore.hasHomeAddress ? "Manage home address protection" : "Add home address protection")
    }

    private var accountDeletionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(SpotRelayTheme.warning)
                    .frame(width: 44, height: 44)
                    .background(SpotRelayTheme.warning.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Delete SpotRelay account")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Permanently remove your profile, saved parked car, owned shared spots, and this device's notification record.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(role: .destructive) {
                isShowingDeleteAccountConfirmation = true
            } label: {
                HStack {
                    if isDeletingAccount {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }

                    Text(isDeletingAccount ? "Deleting account..." : "Delete Account")
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(SpotRelayTheme.warning, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isDeletingAccount)
            .opacity(isDeletingAccount ? 0.7 : 1)
        }
        .padding(18)
        .glassPanel(
            cornerRadius: 26,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    #if DEBUG
    private var debugDemoDataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "testtube.2")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(SpotRelayTheme.primary)
                    .frame(width: 38, height: 38)
                    .background(SpotRelayTheme.primary.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Debug demo data")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Adds dummy nearby spots plus a parked car and recent parking history. Turn it off to restore your real saved parked data.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { spotStore.isDebugDemoDataEnabled },
                    set: { isEnabled in
                        Task {
                            await spotStore.setDebugDemoDataEnabled(isEnabled)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Text(spotStore.isDebugDemoDataEnabled ? "Demo data is currently visible on the map." : "Demo data is off.")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(SpotRelayTheme.badgeFill, in: Capsule())
                .foregroundStyle(spotStore.isDebugDemoDataEnabled ? SpotRelayTheme.success : SpotRelayTheme.badgeText)
        }
        .padding(18)
        .glassPanel(
            cornerRadius: 26,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }
    #endif

    private var accountRecoveryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(SpotRelayTheme.heroGradient)

                    Image(systemName: spotStore.isAppleAccountLinked ? "checkmark.shield.fill" : "apple.logo")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 6) {
                    Text(spotStore.isAppleAccountLinked ? L10n.tr("Profile saved with Apple") : L10n.tr("Save or restore with Apple"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text(spotStore.isAppleAccountLinked
                         ? L10n.tr("You can reinstall SpotRelay or sign in on another device and keep this profile.")
                         : L10n.tr("Keep your name, photo, stars, and trust history after reinstalling or moving to another device."))
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if spotStore.isAppleAccountLinked {
                Label(L10n.tr("Apple account connected"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.success)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(SpotRelayTheme.badgeFill, in: Capsule())
            } else {
                SignInWithAppleButton(.continue) { request in
                    prepareAppleSignInRequest(request)
                } onCompletion: { result in
                    handleAppleSignInCompletion(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .disabled(isLinkingAppleAccount)
                .opacity(isLinkingAppleAccount ? 0.7 : 1)

                if isLinkingAppleAccount {
                    Label(L10n.tr("Saving Apple sign-in..."), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }
            }

            if let appleSignInErrorMessage {
                Text(appleSignInErrorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private var trustSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trust summary")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            HStack(spacing: 12) {
                trustSummaryPill(
                    title: "\(user.reliabilityScore)%",
                    subtitle: "reliability",
                    tint: reliabilityTint
                )
                trustSummaryPill(
                    title: "\(user.shareStars)",
                    subtitle: "share stars",
                    tint: SpotRelayTheme.warning
                )
                trustSummaryPill(
                    title: memberSinceText,
                    subtitle: "member since",
                    tint: SpotRelayTheme.primary
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private var profileStatsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profile stats")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                statCard(
                    title: "Stars earned",
                    value: "\(user.shareStars)",
                    subtitle: "Successful spot shares"
                )
                statCard(
                    title: "Completed handoffs",
                    value: "\(user.successfulHandoffs)",
                    subtitle: "Successful total exchanges"
                )
                statCard(
                    title: "Missed handoffs",
                    value: "\(user.noShowCount)",
                    subtitle: "No-shows or failed finishes"
                )
                statCard(
                    title: "Resolved",
                    value: "\(user.totalResolvedHandoffs)",
                    subtitle: "Tracked trust outcomes"
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private var starExplanationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How stars are earned")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Stars only increase when you share a spot and the handoff is completed successfully. That keeps the trust signal tied to real, finished exchanges instead of simple posting volume.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            HStack(spacing: 12) {
                explanationRow(
                    icon: "star.fill",
                    title: "Successful share",
                    subtitle: "Earns one star"
                )
                explanationRow(
                    icon: "xmark.circle.fill",
                    title: "Failed finish",
                    subtitle: "Doesn't earn a star"
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private func trustSummaryPill(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.82)

            Text(L10n.tr(subtitle))
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(title))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(SpotRelayTheme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Spacer(minLength: 0)

            Text(L10n.tr(subtitle))
                .font(.caption)
                .foregroundStyle(SpotRelayTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func explanationRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SpotRelayTheme.warning)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(L10n.tr(subtitle))
                    .font(.caption)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func syncDraftsIfNeeded(force: Bool = false) {
        guard force || !hasLoadedDrafts else { return }
        draftDisplayName = user.displayName
        nameEditorText = user.displayName
        draftAvatarJPEGData = user.avatarJPEGData
        draftAvatarPreviewImage = previewImage(from: user.avatarJPEGData)
        baselineDisplayName = user.displayName
        baselineAvatarSignature = avatarSignature(for: user.avatarJPEGData)
        draftAvatarSignature = baselineAvatarSignature
        hasLoadedDrafts = true
    }

    private func saveProfile() {
        let sanitizedName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        spotStore.updateCurrentUserProfile(
            displayName: sanitizedName.isEmpty ? "You" : sanitizedName,
            avatarJPEGData: draftAvatarJPEGData
        )
        syncDraftsIfNeeded(force: true)
    }

    private func beginEditingName() {
        nameEditorText = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? user.displayName
            : draftDisplayName
        isShowingNameEditor = true
    }

    private func loadAvatar(from item: PhotosPickerItem) async {
        do {
            guard let selectedData = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    avatarProcessingError = L10n.tr("We couldn't read that photo.")
                }
                return
            }

            guard let normalizedAvatarData = normalizedAvatarJPEGData(from: selectedData) else {
                await MainActor.run {
                    avatarProcessingError = L10n.tr("That photo couldn't be prepared for your profile.")
                }
                return
            }

            await MainActor.run {
                draftAvatarJPEGData = normalizedAvatarData
                draftAvatarPreviewImage = previewImage(from: normalizedAvatarData)
                draftAvatarSignature = avatarSignature(for: normalizedAvatarData)
                avatarProcessingError = nil
                selectedPhotoItem = nil
            }
        } catch {
            await MainActor.run {
                avatarProcessingError = L10n.tr("That photo couldn't be prepared for your profile.")
                selectedPhotoItem = nil
            }
        }
    }

    @MainActor
    private func performAccountDeletion() async {
        guard !isDeletingAccount else { return }

        isDeletingAccount = true
        accountDeletionErrorMessage = nil
        accountDeletionSuccessMessage = nil

        let didDelete = await spotStore.deleteCurrentAccount()
        isDeletingAccount = false

        if didDelete {
            homeExclusionStore.clearHome()
            syncDraftsIfNeeded(force: true)
            accountDeletionSuccessMessage = L10n.tr("Your SpotRelay account and local saved parking data were deleted.")
        } else {
            accountDeletionErrorMessage = spotStore.errorBanner?.message ?? L10n.tr("Please try again in a moment.")
        }
    }

    private func normalizedAvatarJPEGData(from originalData: Data) -> Data? {
        guard let image = UIImage(data: originalData) else { return nil }
        let maxDimension: CGFloat = 320
        let scale = min(maxDimension / max(image.size.width, 1), maxDimension / max(image.size.height, 1), 1)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resizedImage.jpegData(compressionQuality: 0.78)
    }

    private func previewImage(from data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    private func avatarSignature(for data: Data?) -> Int {
        data?.hashValue ?? 0
    }

    private var nameEditorSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Update your profile name")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text("Choose the name other drivers will see during a handoff.")
                    .font(.subheadline)
                    .foregroundStyle(SpotRelayTheme.textSecondary)

                TextField("Your name", text: $nameEditorText)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .focused($isNameEditorFieldFocused)
                    .submitLabel(.done)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(SpotRelayTheme.badgeFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(SpotRelayTheme.softStroke, lineWidth: 1)
                    )
                    .onSubmit {
                        commitEditedName()
                    }
                Spacer()
                Button {
                    commitEditedName()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Use This Name")
                    }
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .task {
                await MainActor.run {
                    nameEditorText = nameEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? user.displayName : nameEditorText
                }
                await Task.yield()
                isNameEditorFieldFocused = true
            }
        }
        .presentationDetents([.fraction(0.44)])
        .presentationDragIndicator(.visible)
    }

    private func commitEditedName() {
        let sanitizedName = nameEditorText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftDisplayName = sanitizedName.isEmpty ? "You" : sanitizedName
        isNameEditorFieldFocused = false
        isShowingNameEditor = false
    }

    private func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentAppleSignInNonce = nonce
        appleSignInErrorMessage = nil
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    private func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentAppleSignInNonce else {
                appleSignInErrorMessage = L10n.tr("Apple sign-in did not finish. Please try again.")
                return
            }

            guard let identityToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                appleSignInErrorMessage = L10n.tr("Apple did not return a valid identity token. Please try again.")
                return
            }

            isLinkingAppleAccount = true
            Task { @MainActor in
                let result = await spotStore.linkAppleAccount(
                    idToken: idTokenString,
                    rawNonce: nonce,
                    fullName: appleIDCredential.fullName
                )
                currentAppleSignInNonce = nil
                isLinkingAppleAccount = false
                appleSignInErrorMessage = result.isLinked
                    ? nil
                    : result.message ?? L10n.tr("Please try signing in with Apple again.")
            }

        case .failure(let error):
            currentAppleSignInNonce = nil
            guard (error as? ASAuthorizationError)?.code != .canceled else { return }
            appleSignInErrorMessage = L10n.tr("Apple sign-in did not finish. Please try again.")
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in charset.randomElement(using: &generator) })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ProfileInsightsSection: View, Equatable {
    let user: AppUser

    private var memberSinceText: String {
        user.joinedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private var reliabilityTint: Color {
        switch user.reliabilityScore {
        case 97...:
            return SpotRelayTheme.success
        case 90...:
            return SpotRelayTheme.primary
        default:
            return SpotRelayTheme.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            trustSummaryCard
            profileStatsGrid
            starExplanationCard
        }
    }

    private var trustSummaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trust summary")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            HStack(spacing: 12) {
                trustSummaryPill(
                    title: "\(user.reliabilityScore)%",
                    subtitle: "reliability",
                    tint: reliabilityTint
                )
                trustSummaryPill(
                    title: "\(user.shareStars)",
                    subtitle: "share stars",
                    tint: SpotRelayTheme.warning
                )
                trustSummaryPill(
                    title: memberSinceText,
                    subtitle: "member since",
                    tint: SpotRelayTheme.primary
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private var profileStatsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Profile stats")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                statCard(
                    title: "Stars earned",
                    value: "\(user.shareStars)",
                    subtitle: "Successful spot shares"
                )
                statCard(
                    title: "Completed handoffs",
                    value: "\(user.successfulHandoffs)",
                    subtitle: "Successful total exchanges"
                )
                statCard(
                    title: "Missed handoffs",
                    value: "\(user.noShowCount)",
                    subtitle: "No-shows or failed finishes"
                )
                statCard(
                    title: "Resolved",
                    value: "\(user.totalResolvedHandoffs)",
                    subtitle: "Tracked trust outcomes"
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.glassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private var starExplanationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How stars are earned")
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Stars only increase when you share a spot and the handoff is completed successfully. That keeps the trust signal tied to real, finished exchanges instead of simple posting volume.")
                .font(.subheadline)
                .foregroundStyle(SpotRelayTheme.textSecondary)

            HStack(spacing: 12) {
                explanationRow(
                    icon: "star.fill",
                    title: "Successful share",
                    subtitle: "Earns one star"
                )
                explanationRow(
                    icon: "xmark.circle.fill",
                    title: "Failed finish",
                    subtitle: "Doesn't earn a star"
                )
            }
        }
        .padding(20)
        .glassPanel(
            cornerRadius: 28,
            tint: SpotRelayTheme.strongGlassTint,
            stroke: SpotRelayTheme.softStroke,
            shadow: SpotRelayTheme.rowShadow,
            shadowRadius: 14,
            shadowY: 8
        )
    }

    private func trustSummaryPill(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(SpotRelayTheme.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.82)

            Text(L10n.tr(subtitle))
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(3)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr(title))
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(SpotRelayTheme.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Spacer(minLength: 0)

            Text(L10n.tr(subtitle))
                .font(.caption)
                .foregroundStyle(SpotRelayTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func explanationRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SpotRelayTheme.warning)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SpotRelayTheme.textPrimary)

                Text(L10n.tr(subtitle))
                    .font(.caption)
                    .foregroundStyle(SpotRelayTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SpotRelayTheme.badgeFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
