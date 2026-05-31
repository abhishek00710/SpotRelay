import CoreLocation
import MapKit
import SwiftUI

struct ParkedLocationHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let reminders: [ParkingReminderStore.Reminder]
    let currentReminder: ParkingReminderStore.Reminder?
    let userCoordinate: CLLocationCoordinate2D?
    let onSelectReminder: (ParkingReminderStore.Reminder) -> Void

    @State private var searchText = ""
    @State private var filter: ParkingHistoryFilter = .all
    @State private var resolvedPlaceLabels: [Date: String] = [:]

    private struct HistoryDaySection: Identifiable {
        let id: Date
        let title: String
        let reminders: [ParkingReminderStore.Reminder]
    }

    private enum ParkingHistoryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case today = "Today"
        case week = "7 days"

        var id: String { rawValue }
    }

    private var filteredReminders: [ParkingReminderStore.Reminder] {
        let calendar = Calendar.current
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return reminders.filter { reminder in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .today:
                matchesFilter = calendar.isDateInToday(reminder.createdAt)
            case .week:
                matchesFilter = reminder.createdAt >= calendar.date(byAdding: .day, value: -7, to: .now) ?? .now
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            return searchableText(for: reminder)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [HistoryDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredReminders) { reminder in
            calendar.startOfDay(for: reminder.createdAt)
        }

        return grouped.keys
            .sorted(by: >)
            .map { day in
                HistoryDaySection(
                    id: day,
                    title: historySectionTitle(for: day, calendar: calendar),
                    reminders: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
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
                                ForEach(section.reminders, id: \.createdAt) { reminder in
                                    parkedHistoryRow(reminder: reminder)
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

                    if filteredReminders.isEmpty {
                        parkingHistoryEmptyState(title: "No parking records found", subtitle: "Try a different search or filter.")
                    }
                }
                .padding(20)
            }
            .background(SpotRelayTheme.canvasGradient.ignoresSafeArea())
            .navigationTitle("Parking records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.bold))
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search parking records")
        .task(id: filteredReminders.prefix(80).map(\.createdAt).description) {
            await resolveVisiblePlaceLabels()
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every saved stop")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SpotRelayTheme.textPrimary)

                    Text("Search by place, city, date, or nearby distance. Tap any row to put it back on the map.")
                        .font(.subheadline)
                        .foregroundStyle(SpotRelayTheme.textSecondary)
                }

                Spacer()

                Text(reminders.count.formatted())
                    .font(.headline.weight(.black))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(SpotRelayTheme.primary.opacity(0.16), in: Capsule())
                    .foregroundStyle(SpotRelayTheme.primary)
            }

            Picker("Filter", selection: $filter) {
                ForEach(ParkingHistoryFilter.allCases) { filter in
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

    private func parkedHistoryRow(reminder: ParkingReminderStore.Reminder) -> some View {
        let isCurrent = reminder == currentReminder

        return Button {
            onSelectReminder(reminder)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill((isCurrent ? SpotRelayTheme.success : SpotRelayTheme.primary).opacity(0.15))
                        .frame(width: 46, height: 46)

                    Image(systemName: isCurrent ? "car.circle.fill" : "mappin.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isCurrent ? SpotRelayTheme.success : SpotRelayTheme.primary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(displayTitle(for: reminder))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(SpotRelayTheme.textPrimary)
                            .lineLimit(2)

                        if isCurrent {
                            Text("Current")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(SpotRelayTheme.success.opacity(0.16), in: Capsule())
                                .foregroundStyle(SpotRelayTheme.success)
                        }
                    }

                    Text(reminder.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SpotRelayTheme.textSecondary)

                    HStack(spacing: 8) {
                        if let userCoordinate {
                            parkingHistoryMiniMetric(reminder.coordinateDistanceText(from: userCoordinate), icon: "figure.walk")
                        }
                        parkingHistoryMiniMetric("Radius \(Int(reminder.radiusMeters.rounded()))m", icon: "scope")
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "location.viewfinder")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SpotRelayTheme.primary)
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

    private func displayTitle(for reminder: ParkingReminderStore.Reminder) -> String {
        if let label = resolvedPlaceLabels[reminder.createdAt], !label.isEmpty {
            return label
        }
        if let areaLabel = reminder.areaLabel, !areaLabel.isEmpty {
            return areaLabel
        }
        return "Saved parking spot"
    }

    private func searchableText(for reminder: ParkingReminderStore.Reminder) -> String {
        [
            displayTitle(for: reminder),
            reminder.areaLabel,
            reminder.createdAt.formatted(date: .complete, time: .shortened),
            reminder.createdAt.formatted(date: .abbreviated, time: .shortened)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func historySectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    @MainActor
    private func resolveVisiblePlaceLabels() async {
        var nextLabels = resolvedPlaceLabels
        for reminder in filteredReminders.prefix(80) where nextLabels[reminder.createdAt] == nil {
            if let label = await parkingHistoryReverseGeocodedPlaceLabel(for: reminder.coordinate) {
                nextLabels[reminder.createdAt] = label
            }
        }
        resolvedPlaceLabels = nextLabels
    }
}

private func parkingHistoryMiniMetric(_ text: String, icon: String) -> some View {
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

private func parkingHistoryEmptyState(title: String, subtitle: String) -> some View {
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

private func parkingHistoryReverseGeocodedPlaceLabel(for coordinate: CLLocationCoordinate2D) async -> String? {
    let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    do {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try await request.mapItems
        let mapItem = items.first
        return parkingHistoryPrecisePlaceLabel(for: mapItem)
            ?? mapItem?.addressRepresentations?.cityWithContext
            ?? mapItem?.addressRepresentations?.cityName
    } catch {
        return nil
    }
}

private func parkingHistoryPrecisePlaceLabel(for mapItem: MKMapItem?) -> String? {
    let name = parkingHistoryNormalizedPlaceComponent(mapItem?.name)
    let address = parkingHistoryNormalizedPlaceComponent(mapItem?.address?.shortAddress)

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

private func parkingHistoryNormalizedPlaceComponent(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value
        .components(separatedBy: ",")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, trimmed != "Nearby" else { return nil }
    return trimmed
}
