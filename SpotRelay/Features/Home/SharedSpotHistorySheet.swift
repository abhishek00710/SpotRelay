import CoreLocation
import MapKit
import SwiftUI

struct SharedSpotHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let spots: [ParkingSpotSignal]
    let currentUserID: String
    let userCoordinate: CLLocationCoordinate2D?
    let onSelectSpot: (ParkingSpotSignal) -> Void

    @State private var searchText = ""
    @State private var filter: SharedSpotFilter = .all
    @State private var resolvedPlaceLabels: [String: String] = [:]

    private struct HistoryDaySection: Identifiable {
        let id: Date
        let title: String
        let spots: [ParkingSpotSignal]
    }

    private enum SharedSpotFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case claimed = "Claimed"
        case closed = "Closed"

        var id: String { rawValue }
    }

    private var filteredSpots: [ParkingSpotSignal] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return spots.filter { signal in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .active:
                matchesFilter = signal.status == .posted
            case .claimed:
                matchesFilter = signal.status == .claimed || signal.status == .arriving
            case .closed:
                matchesFilter = !signal.isActive
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            return searchableText(for: signal)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [HistoryDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredSpots) { signal in
            calendar.startOfDay(for: signal.createdAt)
        }

        return grouped.keys
            .sorted(by: >)
            .map { day in
                HistoryDaySection(
                    id: day,
                    title: historySectionTitle(for: day, calendar: calendar),
                    spots: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
                )
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    summaryHeader

                    ForEach(sections) { section in
                        Section {
                            VStack(spacing: 12) {
                                ForEach(section.spots) { signal in
                                    sharedSpotRow(signal: signal)
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.bold))
                                .textCase(.uppercase)
                                .tracking(0.9)
                                .foregroundStyle(SpotRelayTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                                .padding(.bottom, 2)
                                .background(SpotRelayTheme.canvasGradient)
                        }
                    }

                    if filteredSpots.isEmpty {
                        sharedSpotHistoryEmptyState(title: "No shared spots found", subtitle: "Try a different search or filter.")
                    }
                }
                .padding(20)
            }
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .navigationTitle("Shared spots")
            .navigationBarTitleDisplayMode(.inline)
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search shared spots")
        .task(id: filteredSpots.prefix(100).map(\.id).description) {
            await resolveVisiblePlaceLabels()
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every spot you shared")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Search your posted handoffs and tap one to jump the map to that spot.")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text(spots.count.formatted())
                    .font(.headline.weight(.black))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(SpotRelayTheme.success.opacity(0.16), in: Capsule())
                    .foregroundStyle(SpotRelayTheme.success)
            }

            Picker("Filter", selection: $filter) {
                ForEach(SharedSpotFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
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

    private func sharedSpotRow(signal: ParkingSpotSignal) -> some View {
        Button {
            onSelectSpot(signal)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(sharedSpotColor(for: signal).opacity(0.15))
                        .frame(width: 46, height: 46)

                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(sharedSpotColor(for: signal))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle(for: signal))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)
                        .lineLimit(2)

                    Text(signal.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)

                    HStack(spacing: 8) {
                        sharedSpotHistoryMiniMetric(signal.statusLabel(for: currentUserID), icon: "bolt.horizontal.circle.fill")
                        if let userCoordinate {
                            sharedSpotHistoryMiniMetric(signal.distanceText(from: userCoordinate), icon: "figure.walk")
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "map.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(sharedSpotColor(for: signal))
                    .padding(.top, 4)
            }
            .padding(16)
            .glassPanel(
                cornerRadius: 24,
                tint: SpotRelayTheme.glassTint,
                stroke: SpotRelayTheme.softStroke,
                shadow: SpotRelayTheme.rowShadow,
                shadowRadius: 10,
                shadowY: 6
            )
        }
        .buttonStyle(.plain)
    }

    private func displayTitle(for signal: ParkingSpotSignal) -> String {
        if let label = resolvedPlaceLabels[signal.id], !label.isEmpty {
            return label
        }
        return "Shared spot near \(signal.coordinate.latitude.formatted(.number.precision(.fractionLength(4)))), \(signal.coordinate.longitude.formatted(.number.precision(.fractionLength(4))))"
    }

    private func searchableText(for signal: ParkingSpotSignal) -> String {
        [
            displayTitle(for: signal),
            signal.statusLabel(for: currentUserID),
            signal.createdAt.formatted(date: .complete, time: .shortened),
            signal.createdAt.formatted(date: .abbreviated, time: .shortened)
        ]
        .joined(separator: " ")
    }

    private func sharedSpotColor(for signal: ParkingSpotSignal) -> Color {
        switch signal.status {
        case .posted:
            return SpotRelayTheme.success
        case .claimed, .arriving:
            return SpotRelayTheme.primary
        case .completed, .cancelled:
            return SpotRelayTheme.textSecondary
        case .expired:
            return SpotRelayTheme.warning
        }
    }

    private func historySectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    @MainActor
    private func resolveVisiblePlaceLabels() async {
        var nextLabels = resolvedPlaceLabels
        for signal in filteredSpots.prefix(100) where nextLabels[signal.id] == nil {
            if let label = await sharedSpotHistoryReverseGeocodedPlaceLabel(for: signal.coordinate) {
                nextLabels[signal.id] = label
            }
        }
        resolvedPlaceLabels = nextLabels
    }
}

private func sharedSpotHistoryMiniMetric(_ text: String, icon: String) -> some View {
    HStack(spacing: 5) {
        Image(systemName: icon)
            .font(.caption2.weight(.bold))
        Text(text)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(SpotRelayTheme.badgeFill, in: Capsule())
    .foregroundStyle(SpotRelayTheme.badgeText)
}

private func sharedSpotHistoryEmptyState(title: String, subtitle: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: "magnifyingglass.circle.fill")
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(SpotRelayTheme.primary)

        Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(SpotRelayTheme.textPrimary)

        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(SpotRelayTheme.textSecondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(28)
    .glassPanel(
        cornerRadius: 28,
        tint: SpotRelayTheme.glassTint,
        stroke: SpotRelayTheme.softStroke,
        shadow: SpotRelayTheme.rowShadow,
        shadowRadius: 12,
        shadowY: 8
    )
}

private func sharedSpotHistoryReverseGeocodedPlaceLabel(for coordinate: CLLocationCoordinate2D) async -> String? {
    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    do {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try await request.mapItems
        let mapItem = items.first
        return sharedSpotHistoryPrecisePlaceLabel(for: mapItem)
            ?? mapItem?.addressRepresentations?.cityWithContext
            ?? mapItem?.addressRepresentations?.cityName
    } catch {
        return nil
    }
}

private func sharedSpotHistoryPrecisePlaceLabel(for mapItem: MKMapItem?) -> String? {
    let name = sharedSpotHistoryNormalizedPlaceComponent(mapItem?.name)
    let address = sharedSpotHistoryNormalizedPlaceComponent(mapItem?.address?.shortAddress)

    if let name, let address {
        if address.localizedCaseInsensitiveContains(name) {
            return address
        }

        if name.localizedCaseInsensitiveContains(address) {
            return name
        }

        return "\(name), \(address)"
    }

    return address ?? name
}

private func sharedSpotHistoryNormalizedPlaceComponent(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value
        .components(separatedBy: ",")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, trimmed != "Nearby" else { return nil }
    return trimmed
}
